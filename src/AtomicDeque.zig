const std = @import("std");
const Atomic = std.atomic.Value;
const List = std.DoublyLinkedList;

first: Atomic(?*List.Node),
last: Atomic(?*List.Node),

const Self = @This();

pub const empty: Self = .{
    .first = .init(null),
    .last = .init(null),
};

pub fn from(list: List) Self {
    return .{
        .first = .init(list.first),
        .last = .init(list.last),
    };
}

pub fn popFront(self: *Self) ?*List.Node {
    var first = self.first.load(.acquire) orelse return null;
    var last = self.last.load(.monotonic);
    if (first.prev == last) return null;

    while (self.first.cmpxchgWeak(first, first.next, .release, .monotonic)) |new_first| {
        first = new_first orelse return null;
        last = self.last.load(.monotonic);
        if (first.prev == last) return null;
    }

    return first;
}

pub fn popBack(self: *Self) ?*List.Node {
    var last = self.last.load(.acquire) orelse return null;
    var first = self.first.load(.monotonic);
    if (last.next == first) return null;

    while (self.last.cmpxchgWeak(last, last.prev, .release, .monotonic)) |new_last| {
        last = new_last orelse return null;
        first = self.first.load(.monotonic);
        if (last.next == first) return null;
    }

    return last;
}


fn Node(T: type) type {
    return struct {
        node: List.Node,
        item: T,
    };
}

const testing = std.testing;
const expectEqual = testing.expectEqual;

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

    var deque: Self = .from(list);
    try expectEqual(1, get(i32, deque.popFront()));
    try expectEqual(2, get(i32, deque.popFront()));
    try expectEqual(3, get(i32, deque.popFront()));
    try expectEqual(4, get(i32, deque.popFront()));
    try expectEqual(null, get(i32, deque.popFront()));

    deque = .from(list);
    try expectEqual(4, get(i32, deque.popBack()));
    try expectEqual(3, get(i32, deque.popBack()));
    try expectEqual(2, get(i32, deque.popBack()));
    try expectEqual(1, get(i32, deque.popBack()));
    try expectEqual(null, get(i32, deque.popBack()));

    deque = .from(list);
    try expectEqual(1, get(i32, deque.popFront()));
    try expectEqual(4, get(i32, deque.popBack()));
    try expectEqual(2, get(i32, deque.popFront()));
    try expectEqual(3, get(i32, deque.popBack()));
    // try expectEqual(null, get(i32, deque.popFront()));
    try expectEqual(null, get(i32, deque.popBack()));
}
