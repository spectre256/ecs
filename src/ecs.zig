const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Map = std.AutoArrayHashMapUnmanaged;
const List = std.ArrayList;
const Child = std.meta.Child;
const assert = std.debug.assert;
const typeId = @import("typeid.zig").typeId;

pub const num_comps: usize = 64;
pub var type_infos: [num_comps]struct {
    size: usize,
    alignment: Alignment,
} = undefined;
pub const Mask = std.StaticBitSet(num_comps);

fn maskFromType(T: type) Mask {
    var mask: Mask = .initEmpty();
    inline for (std.meta.fields(T)) |field| {
        const id = typeId(field.type);
        mask.set(id);
        type_infos[id] = .{
            .size = @sizeOf(field.type),
            .alignment = .of(field.type),
        };
    }
    return mask;
}

fn sizeFromMask(mask: Mask, maybe_end: ?usize) usize {
    var total: usize = 0;
    const end = maybe_end orelse num_comps;
    for (type_infos[0..end], 0..end) |info, i| {
        if (mask.isSet(i)) {
            total = info.alignment.forward(total) + info.size;
        }
    }
    return total;
}

pub const Archetype = struct {
    /// Raw component storage
    buffer: [*]u8,
    /// Map from row index to entity entry index.
    /// Necessary for deletion
    ids: List(u32),
    mask: Mask,
    len: u32,
    capacity: u32,
    stride: u32,
    alignment: Alignment,

    const init_size = 8;
    const growth_factor = 2;

    pub fn init(self: *@This(), Row: type) void {
        return self.initFrom(null, Row);
    }

    pub fn initFrom(self: *@This(), maybe_old: ?*Archetype, T: type) void {
        var mask = maskFromType(T);
        var alignment: Alignment = .of(T);

        if (maybe_old) |old| {
            mask = mask.unionWith(old.mask);
            alignment = alignment.max(old.alignment);
        }

        const stride: u16 = @intCast(sizeFromMask(mask, null));
        assert(stride > 0);

        self.* = .{
            .buffer = &.{},
            .ids = .empty,
            .mask = mask,
            .len = 0,
            .capacity = 0,
            .stride = stride,
            .alignment = alignment,
        };
    }

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        alloc.rawFree(self.buffer[0 .. self.capacity * self.stride], self.alignment, @returnAddress());
        self.ids.deinit(alloc);
    }

    pub fn has(self: *const @This(), T: type) bool {
        return self.mask.isSet(typeId(T));
    }

    pub fn hasAll(self: *const @This(), Row: type) bool {
        return self.mask.eql(maskFromType(Row));
    }

    pub fn hasAny(self: *const @This(), Row: type) bool {
        return self.mask.supersetOf(maskFromType(Row));
    }

    pub fn getBytes(self: *const @This(), i: u32) []u8 {
        return self.buffer[i * self.stride ..][0..self.stride];
    }

    pub fn get(self: *const @This(), Row: type, i: u32) *Row {
        return @ptrCast(@alignCast(self.getBytes(i)));
    }

    pub fn getComp(self: *const @This(), i: u32, T: type) *T {
        const row = self.getBytes(i);
        const size = sizeFromMask(self.mask, typeId(T));
        const comp = row[size..][0..@sizeOf(T)];
        return @ptrCast(@alignCast(comp));
    }

    pub fn values(self: *const @This(), T: type) []T {
        return @as([*]T, @ptrCast(@alignCast(self.buffer)))[0..self.len];
    }

    fn resize(self: *@This(), alloc: Allocator, capacity: u32) !void {
        assert(capacity > self.capacity);
        defer self.capacity = capacity;

        const bytes = capacity * self.stride;
        const buf = self.buffer[0 .. self.capacity * self.stride];
        if (self.capacity > 0) {
            if (alloc.rawRemap(buf, self.alignment, bytes, @returnAddress())) |new_buf| {
                self.buffer = new_buf;
                return;
            }
        }

        const new_buf = alloc.rawAlloc(bytes, self.alignment, @returnAddress())
            orelse return error.OutOfMemory;
        const copy_bytes = self.len * self.stride;
        @memcpy(new_buf[0..copy_bytes], self.buffer);
        alloc.free(buf);
        self.buffer = new_buf;
    }

    pub fn create(self: *@This(), alloc: Allocator, row: anytype, entry: u32) !u32 {
        const Row = Child(@TypeOf(row));
        // TODO: Enforce type ordering as well
        assert(maskFromType(Row).eql(self.mask));

        if (self.len >= self.capacity) {
            const size = @max(init_size, self.capacity * growth_factor);
            try self.resize(alloc, size);
        }

        try self.ids.append(alloc, entry);
        self.get(Row, self.len).* = row.*;

        defer self.len += 1;
        return self.len;
    }

    /// Swaps item to remove with last element amd
    /// returns entry index of swapped element.
    pub fn delete(self: *@This(), i: u32) u32 {
        const len = self.len - 1;
        self.len = len;
        const id = self.ids.items[i];
        if (i != len) {
            @branchHint(.likely);
            @memcpy(self.getBytes(i), self.getBytes(len));
            self.ids.items[i] = self.ids.items[len];
        }
        self.ids.shrinkRetainingCapacity(len);
        return id;
    }
};

pub const EntityID = packed struct {
    gen: u32,
    row: u32,
};
pub const EntityEntry = struct {
    archetype: *Archetype,
    gen: u32,
    row: u32,
};

archetypes: Map(Mask, Archetype),
entries: List(EntityEntry),
alloc: Allocator,
/// Index of the head of free entries, if there is one
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
    const arch = try self.getArch(Child(@TypeOf(row)));
    const row_i = try arch.create(self.alloc, row);
    errdefer _ = arch.delete(row_i);

    // Reuse deleted entry if possible
    if (self.free_entry) |entry_i| {
        const entry = &self.entries.items[entry_i];

        // Set to next free entry
        self.free_entry = if (entry.row != entry_i) entry.row else null;

        entry.archetype = arch;
        entry.gen +%= 1;
        entry.row = row_i;

        return .{ .gen = entry.gen, .row = entry_i };
    } else {
        // No free entries, allocate a new one
        const entry_i = self.entries.items.len;
        try self.entries.append(self.alloc, .{
            .archetype = arch,
            .gen = 0,
            .row = row_i,
        });

        return .{ .gen = 0, .row = entry_i };
    }
}

fn getArch(self: *Self, Row: type) !*Archetype {
    const mask = maskFromType(Row);
    const res = try self.archetypes.getOrPut(self.alloc, mask);
    if (!res.found_existing) res.value_ptr.init(Row);
    return res.value_ptr;
}

pub fn delete(self: *Self, id: EntityID) void {
    const entry = self.entries.items[id];
    const i = entry.archetype.delete(entry.row);
    // TODO: Delete entry
    _ = i;

    // Prepend free entry
    entry.row = self.free_entry orelse entry.row;
    self.free_entry = entry.row;
}

pub fn alive(self: *const Self, id: EntityID) bool {
    return id.gen == self.entries.items[id.row].gen;
}

pub fn get(self: *const Self, Row: type, id: EntityID) !*Row {
    const entry = self.entries.items[id];
    if (entry.gen != id.gen) return error.EntityDead;
    return entry.archetype.get(Row, entry.row);
}

pub fn getComp(self: *const Self, id: EntityID, T: type) ?*T {
    const entry = self.entries.items[id];
    const arch = entry.archetype;
    if (!arch.has(T)) return null;
    return arch.getComp(entry.row, T);
}

pub fn has(self: *const Self, id: EntityID, T: type) bool {
    return self.entries.items[id].archetype.has(T);
}

pub fn add(self: *Self, id: EntityID, comp: anytype) !void {
    const T = Child(@TypeOf(comp));
    _ = T;

    self.delete(id);
}

pub fn remove(self: *Self, id: EntityID, T: type) !void {
    _ = self;
    _ = id;
    _ = T;
}

pub fn Iterator(T: type, iter_all: bool) type {
    return struct {
        ecs: *Self,
        archetype: ?*Archetype,
        archetype_i: usize,
        row_i: u32,

        pub fn init(ecs: *Self) @This() {
            var self: @This() = .{
                .ecs = ecs,
                .archetype = null,
                .archetype_i = 0,
                .row_i = 0,
            };
            _ = self.nextArch();
            return self;
        }

        pub fn next(self: *@This()) ?*T {
            var arch = self.archetype orelse return null;
            if (self.row_i >= arch.len) {
                _ = self.nextArch();
                arch = self.archetype orelse return null;
            }

            defer self.row_i += 1;
            return arch.get(T, self.row_i);
        }

        fn nextArch(self: *@This()) bool {
            while (self.archetype_i < self.ecs.archetypes.count()) : (self.archetype_i += 1) {
                const arch = &self.ecs.archetypes.values()[self.archetype_i];
                if (match(arch)) {
                    self.archetype = arch;
                    return true;
                }
            } else return false;
        }

        fn match(arch: *const Archetype) bool {
            if (iter_all) {
                return arch.has(T);
            } else {
                return arch.mask.eql(maskFromType(T));
            }
        }
    };
}

pub fn all(self: *Self, Row: type) Iterator(Row, true) {
    return .init(self);
}

pub fn each(self: *Self, T: type, f: fn (*T) void) void {
    for (self.archetypes.values()) |*arch| {
        // TODO: Properly handle getting a subset of a row
        // if (arch.has(T)) {
        if (arch.mask.eql(maskFromType(T))) {
            for (arch.values(T)) |*row| {
                f(row);
            }
        }
    }
}
