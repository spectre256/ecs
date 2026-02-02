const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const List = std.ArrayList;
const assert = std.debug.assert;
const typeId = @import("typeid.zig").typeId;
const rtti = @import("rtti.zig");
const Mask = rtti.Mask;

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
    const alignment = rtti.alignFromMask(mask);
    const stride: u16 = @intCast(rtti.sizeFromMask(mask, null));
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
    return self.mask.eql(rtti.maskFromType(Row));
}

pub fn hasAll(self: *const @This(), Row: type) bool {
    return self.mask.supersetOf(rtti.maskFromType(Row));
}

pub fn getBytes(self: *const @This(), i: u32) []u8 {
    return self.buffer[i * self.stride ..][0..self.stride];
}

pub fn getRow(self: *const @This(), Row: type, i: u32) *Row {
    assert(rtti.ensureInorder(Row));
    assert(self.hasExact(Row));

    return @ptrCast(@alignCast(self.getBytes(i)));
}

pub fn getMany(self: *const @This(), i: u32, Row: type) rtti.PtrsTo(Row) {
    // TODO: This is a temporary solution. Users shouldn't have to
    // remember the order in which they created types. This is hard to
    // fix until typeId can be made to work at comptime, however.
    assert(rtti.ensureInorder(Row));
    assert(self.hasAll(Row));

    var res: rtti.PtrsTo(Row) = undefined;
    var offset: usize = i * self.stride;
    var iter = self.mask.iterator(.{});

    inline for (std.meta.fields(Row)) |field| {
        var info_i = iter.next().?;
        while (info_i < typeId(field.type)) {
            const info = rtti.type_infos[info_i];
            info_i = iter.next() orelse break;
            offset = info.alignment.forward(offset) + info.size;
        }

        const info = rtti.type_infos[info_i];
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
    const offset = rtti.sizeFromMask(self.mask, typeId(T));
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
    const Row = @TypeOf(row);
    assert(rtti.ensureInorder(Row));
    assert(self.hasExact(Row));

    const i = try self.new(alloc, entry);
    self.getRow(Row, i).* = row;
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
        const info = rtti.type_infos[i];
        self_offset = info.alignment.forward(self_offset);
        defer self_offset += info.size;

        if (other.mask.isSet(i)) {
            var info_i = other_iter.next().?;
            while (info_i < i) {
                const other_info = rtti.type_infos[info_i];
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
    const id = self.ids.items[len];
    if (i != len) {
        @branchHint(.likely);
        @memcpy(self.getBytes(i), self.getBytes(len));
        self.ids.items[i] = id;
    }

    if (len > 0) {
        @memset(self.getBytes(len), undefined);
        self.ids.shrinkRetainingCapacity(len);
        self.ids.items[len] = undefined;
    }
    return id;
}
