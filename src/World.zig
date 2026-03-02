const std = @import("std");
const Allocator = std.mem.Allocator;
const Map = std.AutoArrayHashMapUnmanaged;
const Array = std.ArrayList;
const assert = std.debug.assert;
const Archetype = @import("Archetype.zig");
const Chunk = @import("Chunk.zig");
const ChunkPool = @import("ChunkPool.zig");
const typeId = @import("typeid.zig").typeId;
const rtti = @import("rtti.zig");
const Mask = rtti.Mask;

pub const Error = error {
    EntityDead,
};

pub const EntityID = packed struct {
    gen: u32, // Generation number when entity was created. Check against EntityEntry to detect liveness
    row: u32, // Index of entry
};

pub const EntityEntry = struct {
    chunk: *Chunk,
    gen: u32, // Generation number. For tracking liveness
    index: union {
        free: u32, // Next freelist entry. If last entry, this points to itself
        used: struct {
            row: u16, // Row in chunk
            arch: u16, // Archetype index
        },
    },
};

archetypes: Map(Mask, Archetype),
entries: Array(EntityEntry),
alloc: Allocator,
pool: ChunkPool,
/// Index of the head of free entries, if there is one
free_entry: ?u32,

const Self = @This();
pub const Options = struct {
    page_alloc: Allocator = std.heap.page_allocator,
};

pub fn init(alloc: Allocator, opts: Options) Self {
    return .{
        .archetypes = .empty,
        .entries = .empty,
        .alloc = alloc,
        .pool = .init(opts.page_alloc),
        .free_entry = null,
    };
}

pub fn deinit(self: *Self) void {
    for (self.archetypes.values()) |*arch|
        arch.deinit(&self.pool, self.alloc);
    self.archetypes.deinit(self.alloc);
    self.pool.reclaimUnused();
    self.entries.deinit(self.alloc);
}

pub fn create(self: *Self, row: anytype) !EntityID {
    const res = try self.getArch(rtti.maskFromType(@TypeOf(row)));
    const arch = res.value_ptr;
    const arch_i: u16 = @intCast(res.index);
    const chunk, const row_i = try arch.create(&self.pool, row, arch_i, undefined);
    errdefer _ = arch.delete(&self.pool, chunk, row_i);

    // Reuse deleted entry if possible
    if (self.free_entry) |entry_i| {
        chunk.ids()[row_i] = entry_i;
        const entry = &self.entries.items[entry_i];

        // Set to next free entry
        self.free_entry = if (entry.index.free != entry_i) entry.index.free else null;

        // No need to update gen, this is handled during deletion
        entry.chunk = chunk;
        entry.index = .{ .used = .{
            .row = row_i,
            .arch = arch_i,
        } };

        return .{ .gen = entry.gen, .row = entry_i };
    } else {
        // No free entries, allocate a new one
        const entry_i: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.alloc, .{
            .chunk = chunk,
            .gen = 0,
            .index = .{ .used = .{
                .row = row_i,
                .arch = arch_i,
            } },
        });
        chunk.ids()[row_i] = entry_i;

        return .{ .gen = 0, .row = entry_i };
    }
}

/// Gets archetype and index in map, adding if not already present. Note
/// that since this can resize the archetypes map, it invalidates all
/// pointers to archetypes on use
inline fn getArch(self: *Self, mask: Mask) !Map(Mask, Archetype).GetOrPutResult {
    const res = try self.archetypes.getOrPut(self.alloc, mask);
    if (!res.found_existing) try res.value_ptr.init(mask, self.alloc);
    return res;
}

inline fn archFromEntry(self: *const Self, entry: EntityEntry) *Archetype {
    const i = entry.index.used.arch;
    return &self.archetypes.values()[i];
}

pub fn delete(self: *Self, id: EntityID) void {
    const entry = &self.entries.items[id.row];
    if (entry.gen != id.gen) return;
    const arch = self.archFromEntry(entry.*);
    const row = entry.index.used.row;
    // Delete from archetype and update moved entry
    if (arch.delete(&self.pool, entry.chunk, row)) |i|
        self.entries.items[i].index.used.row = row;

    // Prepend free entry
    entry.index = .{ .free = self.free_entry orelse id.row };
    entry.gen +%= 1; // Increment immediately that way subsequent checks detect that the entity has been deleted
    self.free_entry = id.row;
}

pub fn isAlive(self: *const Self, id: EntityID) bool {
    return id.gen == self.entries.items[id.row].gen;
}

pub fn get(self: *const Self, id: EntityID, Row: type) Error!rtti.PtrsTo(Row) {
    const entry = self.entries.items[id.row];
    // TODO: Should this be an assert?
    if (entry.gen != id.gen) return error.EntityDead;
    const arch = self.archFromEntry(entry);
    return arch.get(entry.chunk, entry.index.used.row, Row);
}

pub fn getComp(self: *const Self, id: EntityID, T: type) ?*T {
    const entry = self.entries.items[id.row];
    if (entry.gen != id.gen) return null;
    const arch = self.archFromEntry(entry);
    if (!arch.has(T)) return null;
    return arch.getComp(entry.chunk, entry.index.used.row, T);
}

pub fn getOrAdd(self: *Self, id: EntityID, T: type) !*T {
    return self.getOrAddValue(id, T, undefined);
}

pub fn getOrAddValue(self: *Self, id: EntityID, T: type, default: *const T) !*T {
    return self.getComp(id, T) orelse self.addValue(id, default);
}

pub fn has(self: *const Self, id: EntityID, T: type) bool {
    const entry = self.entries.items[id.row];
    if (entry.gen != id.gen) return false;
    const arch = self.archFromEntry(entry);
    return arch.has(T);
}

pub fn addValue(self: *Self, id: EntityID, comp: anytype) !void {
    const ptr = try self.add(id, @TypeOf(comp));
    ptr.* = comp;
}

pub fn add(self: *Self, id: EntityID, T: type) !*T {
    const entry = &self.entries.items[id.row];
    // TODO: Should this be an assert?
    if (entry.gen != id.gen) return error.EntityDead;

    rtti.registerType(T);
    var new_mask = self.archFromEntry(entry.*).mask;
    if (new_mask.isSet(typeId(T))) return error.CompAlreadyPresent;
    new_mask.set(typeId(T));

    const res = try self.getArch(new_mask);
    const new_arch = res.value_ptr;
    const new_arch_i: u16 = @intCast(res.index);
    const old_arch = self.archFromEntry(entry.*); // Get again in case archetype map is resized
    const old_chunk = entry.chunk;
    const old_row = entry.index.used.row;
    const new_chunk, const new_row = try new_arch.copyFrom(old_arch, &self.pool, new_arch_i, old_chunk, old_row);
    entry.chunk = new_chunk;
    entry.index.used = .{
        .row = new_row,
        .arch = new_arch_i,
    };

    if (old_arch.delete(&self.pool, old_chunk, old_row)) |i|
        self.entries.items[i].index.used.row = old_row;

    return new_arch.getComp(new_chunk, new_row, T);
}

pub fn remove(self: *Self, id: EntityID, T: type) !void {
    const entry = &self.entries.items[id.row];
    // TODO: Should this be an assert?
    if (entry.gen != id.gen) return error.EntityDead;

    var new_mask = self.archFromEntry(entry.*).mask;
    if (!new_mask.isSet(typeId(T))) return error.CompNotPresent;
    new_mask.unset(typeId(T));

    const res = try self.getArch(new_mask);
    const new_arch = res.value_ptr;
    const new_arch_i: u16 = @intCast(res.index);
    const old_arch = self.archFromEntry(entry.*); // Get again in case archetype map is resized
    const old_chunk = entry.chunk;
    const old_row = entry.index.used.row;
    const new_chunk, const new_row = try new_arch.copyFrom(old_arch, &self.pool, new_arch_i, old_chunk, old_row);
    entry.chunk = new_chunk;
    entry.index.used = .{
        .row = new_row,
        .arch = new_arch_i,
    };

    if (old_arch.delete(&self.pool, old_chunk, old_row)) |i|
        self.entries.items[i].index.used.row = old_row;
}

pub fn iter(self: *Self, Row: type) Iterator(Row) {
    return .init(self);
}

pub fn Iterator(Row: type) type {
    return struct {
        ecs: *Self,
        arch_iter: ?Archetype.Iterator(Row),
        arch_i: usize,

        pub fn init(ecs: *Self) @This() {
            var self: @This() = .{
                .ecs = ecs,
                .arch_iter = null,
                .arch_i = 0,
            };
            self.arch_iter = self.nextArch();
            return self;
        }

        pub fn next(self: *@This()) ?rtti.PtrsTo(Row) {
            // Must not copy, so can't use orelse here
            if (self.arch_iter == null) return null;
            return self.arch_iter.?.next() orelse blk: {
                self.arch_iter = self.nextArch() orelse return null;
                break :blk self.arch_iter.?.next().?;
            };
        }

        fn nextArch(self: *@This()) ?Archetype.Iterator(Row) {
            return while (self.arch_i < self.ecs.archetypes.count()) {
                defer self.arch_i += 1; // Must not increment after last iteration, so can't use : () syntax
                const arch = &self.ecs.archetypes.values()[self.arch_i];
                if (arch.hasAll(Row) and !arch.isEmpty()) break arch.iter(Row);
            } else null;
        }
    };
}

pub inline fn each(self: *Self, T: type, f: fn (*T) void) void {
    for (self.archetypes.values()) |*arch| {
        if (arch.hasExact(T)) {
            for (arch.values(T)) |*row| {
                f(row);
            }
        }
    }
}
