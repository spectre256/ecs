const std = @import("std");
const Allocator = std.mem.Allocator;
const Map = std.AutoArrayHashMapUnmanaged;
const List = std.ArrayList;
const assert = std.debug.assert;
const Archetype = @import("Archetype.zig");
const typeId = @import("typeid.zig").typeId;
const rtti = @import("rtti.zig");
const Mask = rtti.Mask;

pub const Error = error {
    EntityDead,
};

pub const EntityID = packed struct {
    gen: u32,
    row: u32,
};

pub const EntityEntry = struct {
    archetype: u32,
    gen: u32,
    // TODO: Make this a union for better type safety
    // Maybe like `index: union { row: u32, free: u32 }`
    row: u32,
};

archetypes: Map(Mask, Archetype),
entries: List(EntityEntry),
alloc: Allocator,
/// Index of the head of free entries, if there is one. The last entry will
/// have a `row` is the same as its index in the entry list
free_entry: ?u32,

const Self = @This();

pub fn init(alloc: Allocator) Self {
    return .{
        .archetypes = .empty,
        .entries = .empty,
        .alloc = alloc,
        .free_entry = null,
    };
}

pub fn deinit(self: *Self) void {
    for (self.archetypes.values()) |*arch|
        arch.deinit(self.alloc);
    self.archetypes.deinit(self.alloc);
    self.entries.deinit(self.alloc);
}

pub fn create(self: *Self, row: anytype) !EntityID {
    const res = try self.getArch(rtti.maskFromType(@TypeOf(row)));
    const arch = res.value_ptr;
    const arch_i: u32 = @intCast(res.index);
    const row_i = try arch.create(self.alloc, row, undefined);
    errdefer _ = arch.delete(row_i);

    // Reuse deleted entry if possible
    if (self.free_entry) |entry_i| {
        arch.ids.items[row_i] = entry_i;
        const entry = &self.entries.items[entry_i];

        // Set to next free entry
        self.free_entry = if (entry.row != entry_i) entry.row else null;

        // No need to update gen, this is handled during deletion
        entry.archetype = arch_i;
        entry.row = row_i;

        return .{ .gen = entry.gen, .row = entry_i };
    } else {
        // No free entries, allocate a new one
        const entry_i: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.alloc, .{
            .archetype = arch_i,
            .gen = 0,
            .row = row_i,
        });
        arch.ids.items[row_i] = entry_i;

        return .{ .gen = 0, .row = entry_i };
    }
}

inline fn getArch(self: *Self, mask: Mask) !Map(Mask, Archetype).GetOrPutResult {
    const res = try self.archetypes.getOrPut(self.alloc, mask);
    if (!res.found_existing) res.value_ptr.init(mask);
    return res;
}

// inline fn getArchAt(self: *Self, i: u32) *Archetype {}

pub fn delete(self: *Self, id: EntityID) void {
    const entry = &self.entries.items[id.row];
    // TODO: Should this be an assert?
    if (entry.gen != id.gen) return;
    const arch = &self.archetypes.values()[entry.archetype];
    const i = arch.delete(entry.row);

    // Update moved entry
    self.entries.items[i].row = id.row;

    // Prepend free entry
    entry.row = self.free_entry orelse id.row;
    entry.gen +%= 1; // Increment immediately that way subsequent checks detect that the entity was deleted
    self.free_entry = entry.row;
}

pub fn alive(self: *const Self, id: EntityID) bool {
    return id.gen == self.entries.items[id.row].gen;
}

fn GetResult(T: type) type {
    return switch (T) {
        []const type => rtti.PtrsTo(std.meta.Tuple(T)),
        type => if (@typeInfo(T) == .@"struct") rtti.PtrsTo(T) else *T,
        else => @compileError("Expected struct, slice of types, or single type; found " ++ @typeName(T)),
    };
}

// TODO: This doesn't really work. Is there a way to do something different for
// anonymous types vs defined container types? Would that be too cursed?
pub fn get(self: *const Self, id: EntityID, T: anytype) Error!GetResult(@TypeOf(T)) {
    return switch (@TypeOf(T)) {
        []const type => self.getMany(id, std.meta.Tuple(T)),
        type => if (@typeInfo(T) == .@"struct") self.getMany(id, T) else self.getComp(id, T),
        else => unreachable,
    };
}

pub fn getRow(self: *const Self, Row: type, id: EntityID) Error!*Row {
    const entry = self.entries.items[id.row];
    if (entry.gen != id.gen) return error.EntityDead;
    const arch = &self.archetypes.values()[entry.archetype];
    return arch.getRow(Row, entry.row);
}

pub fn getMany(self: *const Self, id: EntityID, Row: type) Error!rtti.PtrsTo(Row) {
    const entry = self.entries.items[id.row];
    if (entry.gen != id.gen) return error.EntityDead;
    const arch = &self.archetypes.values()[entry.archetype];
    return arch.getMany(entry.row, Row);
}

pub fn getComp(self: *const Self, id: EntityID, T: type) ?*T {
    const entry = self.entries.items[id.row];
    if (entry.gen != id.gen) return null;
    const arch = &self.archetypes.values()[entry.archetype];
    if (!arch.has(T)) return null;
    return arch.getComp(entry.row, T);
}

pub fn getOrAdd(self: *Self, id: EntityID, T: type) !*T {
    return self.getOrAddValue(id, T, undefined);
}

pub fn getOrAddValue(self: *Self, id: EntityID, T: type, default: *const T) !*T {
    return self.getComp(id, T) orelse self.addValue(id, default);
}

pub fn has(self: *const Self, id: EntityID, T: type) bool {
    const entry = self.entries.items[id.row];
    // TODO: Should this be an assert?
    if (entry.gen != id.gen) return false;
    const arch = &self.archetypes.values()[entry.archetype];
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
    const old_arch = &self.archetypes.values()[entry.archetype];

    rtti.registerType(T);
    var new_mask = old_arch.mask;
    if (new_mask.isSet(typeId(T))) return error.CompAlreadyAdded;
    new_mask.set(typeId(T));

    const res = try self.getArch(new_mask);
    const new_arch = res.value_ptr;
    entry.archetype = @intCast(res.index);

    const old_row = entry.row;
    entry.row = try new_arch.copy(old_arch, self.alloc, old_row);

    const i = old_arch.delete(old_row);
    self.entries.items[i].row = old_row;

    return new_arch.getComp(entry.row, T);
}

pub fn remove(self: *Self, id: EntityID, T: type) !void {
    const entry = &self.entries.items[id.row];
    // TODO: Should this be an assert?
    if (entry.gen != id.gen) return error.EntityDead;
    const old_arch = &self.archetypes.values()[entry.archetype];

    var new_mask = old_arch.mask;
    new_mask.unset(typeId(T));

    const res = try self.getArch(new_mask);
    entry.archetype = @intCast(res.index);

    const old_row = entry.row;
    entry.row = try res.value_ptr.copy(old_arch, self.alloc, old_row);

    const i = old_arch.delete(old_row);
    self.entries.items[i].row = old_row;
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
            if (self.arch_iter == null) return null;
            return self.arch_iter.?.next() orelse blk: {
                self.arch_iter = self.nextArch() orelse return null;
                break :blk self.arch_iter.?.next().?;
            };
        }

        fn nextArch(self: *@This()) ?Archetype.Iterator(Row) {
            return while (self.arch_i < self.ecs.archetypes.count()) {
                defer self.arch_i += 1;
                const arch = &self.ecs.archetypes.values()[self.arch_i];
                if (arch.hasAll(Row) and arch.len > 0) break arch.iter(Row);
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
