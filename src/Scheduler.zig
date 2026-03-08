const std = @import("std");
const Allocator = std.mem.Allocator;
const Array = std.ArrayListUnmanaged;
const List = std.DoublyLinkedList;
const Atomic = std.atomic.Value;
const Thread = std.Thread;
const World = @import("World.zig");
const Chunk = @import("Chunk.zig");
const rtti = @import("rtti.zig");
const Mask = rtti.Mask;

mutex: Thread.Mutex,
cond: Thread.Condition,
graph: CompiledGraph,
alloc: Allocator,
ecs: *World,

const Self = @This();

const System = struct {
    mask: Mask,
    iter_fn: fn (*Chunk) void,
    prev_count: Atomic(u32),
    next: Array(*System),
    // For graph building and iteration
    node: List.Node,
    height: usize,

    pub fn next(self: *@This()) ?*@This() {
        return .fromOpt(self.node.next);
    }

    pub fn from(node: *List.Node) *@This() {
        return @fieldParentPtr("node", node);
    }

    pub fn fromOpt(node: ?*List.Node) ?*@This() {
        return .from(node orelse return null);
    }
};

pub const Graph = struct {
    roots: Array(*System),
    alloc: Allocator,

    pub const ScheduleOptions = struct {
        /// Systems that must be run before the current one
        before: []*System = &.{},
        /// Systems that must be run after the current one
        after: []*System = &.{},
    };

    pub fn init(alloc: Allocator) @This() {
        return .{
            .roots = .empty,
            .alloc = alloc,
        };
    }

    pub fn scheduleBefore(self: *@This(), system_fn: anytype, extra_args: anytype, before: []*System) !*System {
        return scheduleOpts(self, system_fn, extra_args, .{ .before = before });
    }

    pub fn scheduleAfter(self: *@This(), system_fn: anytype, extra_args: anytype, after: []*System) !*System {
        return scheduleOpts(self, system_fn, extra_args, .{ .after = after });
    }

    // TODO: Add real type for extra_args
    // TODO: Auto scheduling based on iter type?
    pub fn scheduleOpts(self: *@This(), system_fn: anytype, extra_args: anytype, opts: ScheduleOptions) !*System {
        const Row = @TypeOf(system_fn).@"fn".params[0].type.?.Row;
        const iter_fn = struct {
            pub fn iter_fn(chunk: *Chunk) void {
                // TODO: How do I get the archetype here?
                @call(.auto, system_fn, .{chunk.iter(T)} ++ extra_args);
            }
        }.iter_fn;

        const system = try self.alloc.create(System);
        errdefer self.alloc.destroy(system);
        system.* = .{
            .mask = rtti.maskFromType(Row),
            .iter_fn = iter_fn,
            .prev_count = .init(opts.before.len),
            .next = .empty,
            .node = .{},
            .height = undefined,
        };

        // TODO: Proper error handling in case of append failure
        // With the current implementation, allocation failure results in an incomplete graph
        // Either rollback (annoying) or explicitly state that graph is invalid after error on schedule
        if (opts.before.len == 0) {
            try self.roots.append(system);
        } else {
            for (opts.before) |before_system|
                try before_system.next.append(system);
        }

        // No atomics needed, this function doesn't need to be thread safe
        for (opts.after) |after_system|
            after_system.prev_count.raw += 1;

        return system;
    }

    // Topologically sort system graph
    pub fn build(self: *@This()) CompiledGraph {
        // Calculate and set heights for system graph
        for (self.roots.items) |system| _ = calcHeight(system);

        var queue: List = .{};
        var systems: List = .{};

        // Start with all root nodes
        sortSystems(self.roots.items);
        for (self.roots.items) |system|
            queue.append(&system.node);

        // In order traversal, each level sorted by fanout size and then by height
        // This should guarantee optimal scheduling order
        while (queue.popFirst()) |node| {
            const system: *System = @fieldParentPtr("node", node);
            sortSystems(system.next.items);

            systems.append(&system.node);
            for (system.next.items) |next_system|
                queue.append(&next_system.node);
        }

        return .{ .systems = systems };
    }

    // TODO: Oh no, recursion, unsafe unsafe unsafe!!
    fn calcHeight(system: *System) usize {
        if (system.next.items.len == 0) return 0;

        var height: usize = 1;
        for (system.next.items) |next_system|
            height = @max(height, calcHeight(next_system));

        system.height = height;
        return height;
    }

    fn sortSystems(systems: []*System) void {
        std.sort.insertion(*System, systems, void, struct {
            pub fn lessThan(_: void, a: *System, b: *System) bool {
                const a_fanout = a.next.items.len;
                const b_fanout = b.next.items.len;
                // If fanouts are equal, compare by height, otherwise compare by fanout
                return if (a_fanout == b_fanout) a.height < b.height else a_fanout < b_fanout;
            }
        }.lessThan);
    }
};

pub const CompiledGraph = struct {
    systems: List,

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        var next: ?*System = .fromOpt(self.systems.first);
        while (next) |system| {
            next = system.next();
            system.next.deinit(alloc);
            alloc.destroy(system);
        }
    }
};

pub const Options = struct {
    alloc: ?Allocator = null,
};

pub fn init(self: *Self, ecs: *World, opts: Options) void {
    self.* = .{
        .mutex = .{},
        .cond = .{},
        .init_systems = .empty,
        .alloc = opts.alloc orelse ecs.alloc,
    };
}

pub fn run(self: *Self) void {
    const thread_count = Thread.getCpuCount() catch 1;
    var threads = try self.alloc.alloc(Thread, thread_count);
    defer self.alloc.free(threads);

    for (0..thread_count) |i|
        threads[i] = try Thread.spawn(.{}, worker, .{ self });

    for (threads) |thread| thread.join();
}

fn worker(self: *Self) void {
    _ = self;

    // Load next archetype and iterate over all chunks
    // If none, load next system (atomic spinwait on prev_count)
    // If none, steal chunk and run, then retry
    // If none, finish
}
