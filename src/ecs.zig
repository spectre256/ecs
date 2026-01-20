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

fn ensureInorder(T: type) bool {
    var last_id: ?usize = null;
    inline for (std.meta.fields(T)) |field| {
        if (last_id) |id|
            if (typeId(field.type) <= id) return false;

        last_id = typeId(field.type);
    } else return true;
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

fn PtrsTo(Row: type) type {
    const old_fields = std.meta.fields(Row);
    var new_fields: [old_fields.len]std.builtin.Type.StructField = undefined;
    @memcpy(&new_fields, old_fields);
    for (&new_fields) |*field| {
        field.type = *field.type;
        field.default_value_ptr = null;
        field.alignment = @alignOf(*field.type);
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &new_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
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

    pub fn hasExact(self: *const @This(), Row: type) bool {
        return self.mask.eql(maskFromType(Row));
    }

    pub fn hasAll(self: *const @This(), Row: type) bool {
        return self.mask.supersetOf(maskFromType(Row));
    }

    pub fn getBytes(self: *const @This(), i: u32) []u8 {
        return self.buffer[i * self.stride ..][0..self.stride];
    }

    pub fn getOnly(self: *const @This(), Row: type, i: u32) *Row {
        assert(ensureInorder(Row));
        assert(self.hasExact(Row));

        return @ptrCast(@alignCast(self.getBytes(i)));
    }

    pub fn getAll(self: *const @This(), Row: type, i: u32) PtrsTo(Row) {
        assert(self.hasAll(Row));

        var res: PtrsTo(Row) = undefined;
        var offset: usize = 0;
        var iter = maskFromType(Row).iterator(.{});

        inline for (std.meta.fields(Row)) |field| {
            const info = type_infos[iter.next().?];
            offset = info.alignment.forward(offset);
            defer offset += info.size;

            const byte_i = i * self.stride;
            const ptr = &self.buffer[offset + byte_i];
            @field(res, field.name) = @ptrCast(@alignCast(ptr));
        }
        return res;
    }

    pub fn getComp(self: *const @This(), i: u32, T: type) *T {
        assert(self.has(T));

        const row = self.getBytes(i);
        const offset = sizeFromMask(self.mask, typeId(T));
        const comp = &row[offset];
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
        assert(ensureInorder(Row));
        assert(self.hasExact(Row));

        if (self.len >= self.capacity) {
            const size = @max(init_size, self.capacity * growth_factor);
            try self.resize(alloc, size);
        }

        try self.ids.append(alloc, entry);
        self.getOnly(Row, self.len).* = row.*;

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

        if (len > 0) {
            @memset(self.getBytes(len), undefined);
            self.ids.shrinkRetainingCapacity(len);
            self.ids.items[len] = undefined;
        }
        return id;
    }
};

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
    const res = try self.getArch(Child(@TypeOf(row)));
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

        entry.archetype = arch_i;
        entry.gen +%= 1;
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

fn getArch(self: *Self, Row: type) !Map(Mask, Archetype).GetOrPutResult {
    const mask = maskFromType(Row);
    const res = try self.archetypes.getOrPut(self.alloc, mask);
    if (!res.found_existing) res.value_ptr.init(Row);
    return res;
}

pub fn delete(self: *Self, id: EntityID) void {
    const entry = &self.entries.items[id.row];
    const arch = &self.archetypes.values()[entry.archetype];
    const i = arch.delete(entry.row);

    // Update moved entry
    self.entries.items[i].row = id.row;

    // Prepend free entry
    entry.row = self.free_entry orelse entry.row;
    self.free_entry = entry.row;
}

pub fn alive(self: *const Self, id: EntityID) bool {
    return id.gen == self.entries.items[id.row].gen;
}

pub fn getOnly(self: *const Self, Row: type, id: EntityID) Error!*Row {
    const entry = self.entries.items[id.row];
    if (entry.gen != id.gen) return error.EntityDead;
    const arch = &self.archetypes.values()[entry.archetype];
    return arch.getOnly(Row, entry.row);
}

pub fn getAll(self: *const Self, Row: type, id: EntityID) Error!PtrsTo(Row) {
    const entry = self.entries.items[id.row];
    if (entry.gen != id.gen) return error.EntityDead;
    const arch = &self.archetypes.values()[entry.archetype];
    return arch.getAll(Row, entry.row);
}

pub fn getComp(self: *const Self, id: EntityID, T: type) ?*T {
    const entry = self.entries.items[id.row];
    if (entry.gen != id.gen) return null;
    const arch = &self.archetypes.values()[entry.archetype];
    if (!arch.has(T)) return null;
    return arch.getComp(entry.row, T);
}

pub fn has(self: *const Self, id: EntityID, T: type) bool {
    const entry = self.entries.items[id.row];
    const arch = &self.archetypes.values()[entry.archetype];
    return arch.has(T);
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
                return arch.hasAll(T);
            } else {
                return arch.hasExact(T);
            }
        }
    };
}

pub fn all(self: *Self, Row: type) Iterator(Row, true) {
    return .init(self);
}

pub fn each(self: *Self, T: type, f: fn (*T) void) void {
    for (self.archetypes.values()) |*arch| {
        if (arch.hasExact(T)) {
            for (arch.values(T)) |*row| {
                f(row);
            }
        }
    }
}
