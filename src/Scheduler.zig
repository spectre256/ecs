const std = @import("std");
const Array = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const Thread = std.Thread;
const World = @import("World.zig");
const Chunk = @import("Chunk.zig");
const rtti = @import("rtti.zig");
const Mask = rtti.Mask;

mutex: Thread.Mutex,
cond: Thread.Condition,
init_systems: Array(*System),
alloc: Allocator,
ecs: *World,

const Self = @This();

const System = struct {
    mask: Mask,
    iter_fn: fn (*Chunk) void,
    prev_count: Atomic(u32),
    next: Array(*System),
};

const RunEntry = struct {
    system: *System,
    chunk: *Chunk,

    pub fn run(self: @This()) void {
        self.system.iter_fn(self.chunk);
    }
};

pub const Options = struct {
    alloc: ?Allocator = null,
}

pub fn init(self: *Self, ecs: *World, opts: Options) void {
    self.* = .{
        .mutex = .{},
        .cond = .{},
        .init_systems = .empty,
        .alloc = opts.alloc orelse ecs.alloc,
    };
}

pub fn schedule(self: *Self, system_fn: anytype, extra_args: anytype) !*System {
    const T = @TypeOf(system_fn).@"fn".params[0].type.?.Row;
    const iter_fn = struct {
        pub fn iter_fn(chunk: *Chunk) void {
            // TODO: How do I get the archetype here?
            @call(.auto, system_fn, .{chunk.iter(T)} ++ extra_args);
        }
    }.iter_fn;

    const system = try self.alloc.create(System);
    errdefer self.alloc.destroy(system);
    system.* = .{
        .mask = maskFromType(T),
        .iter_fn = iter_fn,
        .prev_count = .init(0), // TODO: This changes once we schedule with dependencies
        .next = .empty,
    };

    // TODO: Actual scheduling based on type
    try self.init_systems.append(system);

    return system;
}

pub fn run(self: *Self) void {
    for (self.init_systems.items) |system|
        self.enqueueChunks(system.mask);

    const thread_count = Thread.getCpuCount() catch 1;
    var threads = try self.alloc.alloc(Thread, thread_count);
    defer self.alloc.free(threads);

    for (0..thread_count) |i|
        threads[i] = try Thread.spawn(.{}, worker, .{ self });

    for (threads) |thread| thread.join();
}

fn worker(self: *Self) void {
    self.mutex.lock();
    // TODO: Where does the queue go?
    while (queue.isEmpty()) self.cond.wait(&self.mutex);
    self.mutex.unlock();

    while (queue.dequeue()) |entry| {
        entry.run();

        for (entry.systems.next.items) |system| {
            if (system.prev_count.fetchSub(1, .acq_rel) == 0) {
                self.enqueueChunks(system);
                self.cond.broadcast();
            }
        }
    }
}

fn enqueueChunks(self: *Self, system: *System) void {
    for (self.ecs.archetypes.values()) |arch| {
        if (arch.mask.supersetOf(system.mask)) {
            var next: ?*Chunk = .fromOpt(arch.chunks.first);
            while (next) |chunk| : (next = chunk.next()) {
                // TODO: Queue
                const entry: RunEntry = .{
                    .system = system,
                    .chunk = chunk,
                };
                // TODO: What do I really do when enqueuing fails?
                queue.enqueue(entry) catch entry.run();
            }
        }
    }
}
