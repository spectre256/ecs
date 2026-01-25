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

fn registerType(T: type) void {
    type_infos[typeId(T)] = .{
        .size = @sizeOf(T),
        .alignment = .of(T),
    };
}

fn maskFromType(Row: type) Mask {
    var mask: Mask = .initEmpty();
    inline for (std.meta.fields(Row)) |field| {
        const id = typeId(field.type);
        mask.set(id);
        registerType(field.type);
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
    var iter = mask.iterator(.{});
    while (iter.next()) |i| {
        if (i >= end) break;
        const info = type_infos[i];
        total = info.alignment.forward(total) + info.size;
    }
    return total;
}

fn alignFromMask(mask: Mask) Alignment {
    var res: Alignment = .@"1";
    var iter = mask.iterator(.{});
    while (iter.next()) |i| res = res.max(type_infos[i].alignment);
    return res;
}

// TODO: This won't work until typeId works at comptime
fn Sorted(Row: type) type {
    const Field = std.builtin.Type.StructField;
    const old_fields = std.meta.fields(Row);
    var new_fields: [old_fields.len]Field = undefined;
    @memcpy(&new_fields, old_fields);
    std.sort.insertion(Field, &new_fields, struct {
        fn lessThan(a: Field, b: Field) bool {
            return typeId(a.type) < typeId(b.type);
        }
    }.lessThan);
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &new_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
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

    pub fn init(self: *@This(), mask: Mask) void {
        const alignment = alignFromMask(mask);
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
        // TODO: This is a temporary solution. Users shouldn't have to
        // remember the order in which they created types. This is hard to
        // fix until typeId can be made to work at comptime, however.
        assert(ensureInorder(Row));
        assert(self.hasAll(Row));

        var res: PtrsTo(Row) = undefined;
        var offset: usize = i * self.stride;
        var iter = self.mask.iterator(.{});

        inline for (std.meta.fields(Row)) |field| {
            var info_i = iter.next().?;
            while (info_i < typeId(field.type)) {
                const info = type_infos[info_i];
                info_i = iter.next() orelse break;
                offset = info.alignment.forward(offset) + info.size;
            }

            const info = type_infos[info_i];
            offset = info.alignment.forward(offset);
            defer offset += info.size;

            const ptr = &self.buffer[offset];
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

    pub fn values(self: *const @This(), Row: type) []Row {
        return @as([*]Row, @ptrCast(@alignCast(self.buffer)))[0..self.len];
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

    pub fn new(self: *@This(), alloc: Allocator, entry: u32) !u32 {
        if (self.len >= self.capacity) {
            const size = @max(init_size, self.capacity * growth_factor);
            try self.resize(alloc, size);
        }

        try self.ids.append(alloc, entry);
        @memset(self.getBytes(self.len), undefined);

        defer self.len += 1;
        return self.len;
    }

    pub fn create(self: *@This(), alloc: Allocator, row: anytype, entry: u32) !u32 {
        const Row = Child(@TypeOf(row));
        assert(ensureInorder(Row));
        assert(self.hasExact(Row));

        const i = try self.new(alloc, entry);
        self.getOnly(Row, i).* = row.*;
        return i;
    }

    /// Copy entity from `other` at index `other_i` to `self`. Only copies
    /// components present in `self`. Returns the new row index.
    pub fn copy(self: *@This(), other: *const @This(), alloc: Allocator, other_i: u32) !u32 {
        const self_i = try self.new(alloc, other.ids.items[other_i]);

        var self_offset: usize = self_i * self.stride;
        var other_offset: usize = other_i * other.stride;
        var self_iter = self.mask.iterator(.{});
        var other_iter = other.mask.iterator(.{});

        // Iterate over components in other entity
        while (self_iter.next()) |i| {
            const info = type_infos[i];
            self_offset = info.alignment.forward(self_offset);
            defer self_offset += info.size;

            if (other.mask.isSet(i)) {
                var info_i = other_iter.next().?;
                while (info_i < i) {
                    const other_info = type_infos[info_i];
                    info_i = other_iter.next() orelse break;
                    other_offset = other_info.alignment.forward(other_offset) + other_info.size;
                }

                other_offset = info.alignment.forward(other_offset);
                defer other_offset += info.size;

                const other_comp = other.buffer[other_offset..][0..info.size];
                const self_comp = self.buffer[self_offset..][0..info.size];
                @memcpy(self_comp, other_comp);
            }
        }

        return self_i;
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
    const Row = Child(@TypeOf(row));
    const res = try self.getArch(maskFromType(Row));
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
    entry.row = self.free_entry orelse entry.row;
    entry.gen +%= 1; // Increment immediately that way subsequent checks detect that the entity was deleted
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
    // TODO: Should this be an assert?
    if (entry.gen != id.gen) return false;
    const arch = &self.archetypes.values()[entry.archetype];
    return arch.has(T);
}

pub fn add(self: *Self, id: EntityID, comp: anytype) !void {
    const entry = &self.entries.items[id.row];
    // TODO: Should this be an assert?
    if (entry.gen != id.gen) return error.EntityDead;
    const old_arch = &self.archetypes.values()[entry.archetype];

    // TODO: Error if bit already set, no duplicate components
    const T = Child(@TypeOf(comp));
    registerType(T);
    var new_mask = old_arch.mask;
    new_mask.set(typeId(T));

    const res = try self.getArch(new_mask);
    const new_arch = res.value_ptr;
    entry.archetype = @intCast(res.index);

    const old_row = entry.row;
    entry.row = try new_arch.copy(old_arch, self.alloc, old_row);
    new_arch.getComp(entry.row, T).* = comp.*;

    const i = old_arch.delete(old_row);
    self.entries.items[i].row = old_row;
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
