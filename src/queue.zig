const std = @import("std");
const assert = std.debug.assert;
const spinLoopHint = std.atomic.spinLoopHint;
const Atomic = std.atomic.Value;

pub fn Queue(Elem: type, comptime buffer_size: usize) type {
    return struct {
        items: [capacity]T,
        /// Producer side
        head: Atomic(usize),
        /// Consumer side
        tail: Atomic(usize),
        /// Producer side, items finished writing
        committed: Atomic(usize),
        /// Consumer side, items finished reading
        consumed: Atomic(usize),

        pub const T = Elem;
        pub const capacity = buffer_size;
        const Self = @This();

        comptime {
            assert(std.math.isPowerOfTwo(buffer_size));
        }

        pub const empty: Self = .{
            .items = undefined,
            .head = .init(0),
            .tail = .init(0),
            .committed = .init(0),
            .consumed = .init(0),
        };

        pub fn enqueue(self: *Self, item: T) !void {
            // Check if there's space, error if none
            const head = self.head.load(.seq_cst);
            const tail = self.tail.load(.seq_cst);
            if (head -% tail >= capacity) return error.QueueFull;

            // Loop while consumers finish reading
            while (self.consumed.load(.seq_cst) < tail) spinLoopHint();
            // Reserve item to write
            const i = self.head.fetchAdd(1, .seq_cst);
            // Write data
            self.items[i % capacity] = item;
            // Update committed
            _ = self.committed.fetchAdd(1, .seq_cst);
        }

        pub fn dequeue(self: *Self) ?T {
            // Check if there's items, error if none
            const head = self.head.load(.seq_cst);
            const tail = self.tail.load(.seq_cst);
            if (head -% tail == 0) return null;

            // Loop while producers finish writing
            while (self.committed.load(.seq_cst) < head) spinLoopHint();
            // Reserve item to read
            const i = self.tail.fetchAdd(1, .seq_cst);
            // Read data
            const item = self.items[i % capacity];
            // Update consumed
            _ = self.consumed.fetchAdd(1, .seq_cst);

            return item;
        }
    };
}

const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;

test "single threaded enqueue and dequeue" {
    var queue: Queue(i32, 2) = .empty;

    try expectEqual({}, queue.enqueue(1));
    try expectEqual({}, queue.enqueue(2));
    try expectError(error.QueueFull, queue.enqueue(3));

    try expectEqual(1, queue.dequeue());
    try expectEqual(2, queue.dequeue());
    try expectEqual(null, queue.dequeue());

    // Offset head and tail by one to test wraparound
    try expectEqual({}, queue.enqueue(4));
    try expectEqual(4, queue.dequeue());

    try expectEqual({}, queue.enqueue(5));
    try expectEqual({}, queue.enqueue(6));
    try expectError(error.QueueFull, queue.enqueue(3));
    try expectEqual(5, queue.dequeue());
    try expectEqual(6, queue.dequeue());
    try expectEqual(null, queue.dequeue());
}

test "spsc enqueue and dequeue" {
    const Q = Queue(i32, 64);
    var queue: Q = .empty;

    var sent_indices: [Q.capacity]bool = @splat(false);
    const producer_thread = try std.Thread.spawn(.{}, struct {
        pub fn producer(q: *Q, sent: []bool) void {
            for (0..Q.capacity) |i| {
                q.enqueue(@intCast(i)) catch continue;
                sent[i] = true;
            }
        }
    }.producer, .{&queue, &sent_indices});

    var received_items: [Q.capacity]?Q.T = @splat(null);
    const consumer_thread = try std.Thread.spawn(.{}, struct {
        pub fn consumer(q: *Q, recvd: []?Q.T) void {
            for (0..Q.capacity) |i| {
                recvd[i] = q.dequeue();
            }
        }
    }.consumer, .{&queue, &received_items});

    std.Thread.join(producer_thread);
    std.Thread.join(consumer_thread);

    for (0..Q.capacity) |i| {
        expectEqual(true, sent_indices[i]) catch |err| {
            std.debug.print("Failed to enqueue item {}\nsent indices: {any}\nrecv'd items: {any}\n", .{ i, sent_indices, received_items });
            return err;
        };

        expectEqual(@as(Q.T, @intCast(i)), received_items[i]) catch |err| {
            std.debug.print("Failed to dequeue item {}, got {any}\nsent indices: {any}\nrecv'd items: {any}\n", .{ i, received_items[i], sent_indices, received_items });
            return err;
        };
    }

    const item = queue.dequeue();
    expectEqual(null, item) catch |err| {
        std.debug.print("Received extra item {any}\n", .{item});
        return err;
    };
}
