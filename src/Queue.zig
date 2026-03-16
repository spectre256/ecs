const std = @import("std");
const Atomic = std.atomic.Value;
const List = std.DoublyLinkedList;

head: Atomic(?*List.Node),

const Self = @This();

pub const empty: Self = .{ .head = .init(null) };

pub fn from(list: List) Self {
    return .{ .head = .init(list.first) };
}

pub fn set(self: *Self, list: List) void {
    self.head.store(list.first, .monotonic);
}

/// Multi consumer, take from the end of the queue
pub fn pop(self: *Self) ?*List.Node {
    var head = self.head.load(.acquire) orelse return null;

    while (self.head.cmpxchgWeak(head, head.next, .release, .monotonic)) |new_head|
        head = new_head orelse return null;

    return head;
}


const testing = std.testing;
const expectEqual = testing.expectEqual;

fn Node(T: type) type {
    return struct {
        node: List.Node,
        item: T,
    };
}

fn toList(T: type, items: []const T) !List {
    var list: List = .{};

    for (items) |item| {
        const node = try testing.allocator.create(Node(T));
        node.item = item;
        list.append(&node.node);
    }

    return list;
}

fn freeList(T: type, list: List) void {
    var next = list.first;
    while (next) |node| {
        next = node.next;
        const item: *Node(T) = @fieldParentPtr("node", node);
        testing.allocator.destroy(item);
    }
}

fn get(T: type, node: ?*List.Node) ?T {
    const item: *Node(T) = @fieldParentPtr("node", node orelse return null);
    return item.item;
}

test "single threaded" {
    const list = try toList(i32, &.{ 1, 2, 3, 4 });
    defer freeList(i32, list);

    var queue: Self = .from(list);
    try expectEqual(1, get(i32, queue.pop()));
    try expectEqual(2, get(i32, queue.pop()));
    try expectEqual(3, get(i32, queue.pop()));
    try expectEqual(4, get(i32, queue.pop()));
    try expectEqual(null, get(i32, queue.pop()));
}

// TODO: Multi-threaded test
