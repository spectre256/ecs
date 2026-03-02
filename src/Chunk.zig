const std = @import("std");
const assert = std.debug.assert;
const List = std.DoublyLinkedList;
const Chunk = @import("Chunk.zig");

header: Header,
buffer: [buffer_size]u8 align(@alignOf(u32)),

pub const buffer_size: usize = std.heap.page_size_min - @sizeOf(Header);
const Self = @This();
pub const Header = struct {
    node: List.Node,
    arch: u16,
    len: u16,
};

pub fn init(self: *Self, arch: u16) void {
    self.* = .{
        .header = .{
            .node = .{},
            .arch = arch,
            .len = 0,
        },
        .buffer = undefined,
    };
}

pub fn ids(self: *Self) [*]u32 {
    return @as([*]u32, @ptrCast(&self.buffer));
}

pub fn new(self: *Self, entry: u32, capacity: u16) u16 {
    assert(self.header.len < capacity);
    defer self.header.len += 1;
    self.ids()[self.header.len] = entry;
    return self.header.len;
}

pub fn isEmpty(self: *const Self) bool {
    return self.header.len <= 0;
}

pub fn isFull(self: *const Self, capacity: u16) bool {
    return self.header.len >= capacity;
}

pub fn next(self: *const Self) ?*Self {
    return .fromOpt(self.header.node.next);
}

pub fn from(node: *List.Node) *Self {
    const header: *Chunk.Header = @fieldParentPtr("node", node);
    return @fieldParentPtr("header", header);
}

pub fn fromOpt(node: ?*List.Node) ?*Self {
    return .from(node orelse return null);
}
