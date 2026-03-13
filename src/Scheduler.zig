const std = @import("std");
const Allocator = std.mem.Allocator;
const Array = std.ArrayListUnmanaged;
const Map = std.AutoHashMapUnmanaged;
const List = std.DoublyLinkedList;
const Atomic = std.atomic.Value;
const Thread = std.Thread;
const AtomicDeque = @import("AtomicDeque.zig");
const World = @import("World.zig");
const Chunk = @import("Chunk.zig");
const rtti = @import("rtti.zig");
const Mask = rtti.Mask;

system: Atomic(*System),
workers: []Worker,
alloc: Allocator,
ecs: *World,

const Self = @This();

const RwMask = struct {
    read: Mask,
    write: Mask,

    pub const empty: @This() = .{
        .read = .initEmpty(),
        .write = .initEmpty(),
    };

    pub fn conflicts(self: @This(), other: @This()) bool {
        const wr_conflict = self.write.intersectWith(other.write.unionWith(other.read)).count() > 0;
        const rw_conflict = other.write.intersectWith(self.write.unionWith(self.read)).count() > 0;
        return wr_conflict or rw_conflict;
    }

    pub fn unionWith(self: @This(), other: @This()) @This() {
        return .{
            .read = self.read.unionWith(other.read),
            .write = self.write.unionWith(other.write),
        };
    }

    pub fn fromType(Row: type) @This() {
        var self: @This() = .empty;

        inline for (std.meta.fields(Row)) |field| {
            const info = @typeInfo(field.type);
            const i = rtti.typeId(info.pointer.child);
            if (info.pointer.is_const) self.read.set(i) else self.write.set(i);
        }

        return self;
    }
};

const System = struct {
    rw: RwMask,
    ctx: ?*anyopaque = null,
    vtable: VTable,
    prev_count: Atomic(u32),
    // TODO: Do I really need this? Perhaps just a count for sorting
    nexts: Array(*System),
    // For graph building and iteration
    node: List.Node,
    // For debugging
    name: [:0]const u8,

    pub const VTable = struct {
        init: ?*const fn () *anyopaque,
        deinit: ?*const fn (?*anyopaque) void,
        run_chunk: *const fn (?*anyopaque, *Chunk) void,
    };

    pub fn next(self: *@This()) ?*@This() {
        return .fromOpt(self.node.next);
    }

    pub fn from(node: *List.Node) *@This() {
        return @fieldParentPtr("node", node);
    }

    pub fn fromOpt(node: ?*List.Node) ?*@This() {
        return .from(node orelse return null);
    }

    pub fn append(self: *@This(), alloc: Allocator, other: *@This()) !void {
        try self.nexts.append(alloc, other);
        other.prev_count.raw += 1;
    }

    pub fn init(self: *@This()) void {
        if (self.vtable.init) |init_fn|
            self.ctx = init_fn();
    }

    pub fn deinit(self: *@This()) void {
        if (self.vtable.deinit) |deinit_fn|
            deinit_fn(self.ctx);
    }

    pub fn runChunk(self: *const @This(), chunk: *Chunk) void {
        self.vtable.run_chunk(self.ctx, chunk);
    }
};

const Level = struct {
    rw: RwMask,
    systems: Array(*System),

    pub const empty: @This() = .{
        .rw = .empty,
        .systems = .empty,
    };

    /// Sort in descending order based on fanout
    pub fn sort(self: *@This()) void {
        std.sort.insertion(*System, self.systems.items, {}, struct {
            pub fn lessThan(_: void, a: *System, b: *System) bool {
                return a.nexts.items.len > b.nexts.items.len; // Greater than to sort descending
            }
        }.lessThan);
    }
};

pub const Graph = struct {
    levels: Array(Level),
    alloc: Allocator,

    pub const ScheduleOptions = struct {
        name: ?[:0]const u8 = null,
        /// Systems that must be run before the current one
        before: []const *System = &.{},
        /// Systems that must be run after the current one
        after: []const *System = &.{},
    };

    pub fn init(alloc: Allocator) @This() {
        return .{
            .levels = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *@This()) void {
        defer self.levels.deinit(self.alloc);

        for (self.levels.items) |*level| {
            for (level.systems.items) |system| {
                system.nexts.deinit(self.alloc);
                self.alloc.destroy(system);
            }

            level.systems.deinit(self.alloc);
        }
    }

    pub fn schedule(self: *@This(), ctx_or_fn: anytype, extra_args: anytype) !*System {
        return self.scheduleOpts(ctx_or_fn, extra_args, .{});
    }

    /// Schedule a system before other systems
    pub fn scheduleBefore(self: *@This(), ctx_or_fn: anytype, extra_args: anytype, after: []const *System) !*System {
        return self.scheduleOpts(ctx_or_fn, extra_args, .{ .after = after });
    }

    /// Schedule a system after other systems
    pub fn scheduleAfter(self: *@This(), ctx_or_fn: anytype, extra_args: anytype, before: []const *System) !*System {
        return self.scheduleOpts(ctx_or_fn, extra_args, .{ .before = before });
    }

    // TODO: Add real type for extra_args
    // TODO: Validate types
    pub fn scheduleOpts(self: *@This(), ctx_or_fn: anytype, extra_args: anytype, opts: ScheduleOptions) !*System {
        const Impl = getImpl(ctx_or_fn, extra_args);

        const system = try self.alloc.create(System);
        system.* = .{
            .rw = .fromType(Impl.Row),
            .vtable = Impl.vtable,
            .prev_count = .init(0),
            .nexts = try .initCapacity(self.alloc, opts.after.len),
            .node = .{},
            .name = opts.name orelse @typeName(Impl.Row),
        };

        try self.addSystem(system, opts);

        return system;
    }

    fn getImpl(ctx_or_fn: anytype, extra_args: anytype) type {
        const info = @typeInfo(@TypeOf(ctx_or_fn));
        return switch (info) {
            .type => struct {
                const Context = ctx_or_fn;
                pub const Row = Context.Row;
                const has_ctx = @typeInfo(@TypeOf(Context.init)).@"fn".return_type != null;

                pub const vtable: System.VTable = .{
                    .init = @This().init,
                    .deinit = @This().deinit,
                    .run_chunk = runChunk,
                };

                pub fn init() !?*anyopaque {
                    return if (has_ctx) @ptrCast(Context.init()) else null;
                }

                pub fn deinit(any_ctx: ?*anyopaque) void {
                    if (has_ctx) Context.deinit(@ptrCast(@alignCast(any_ctx.?)));
                }

                pub fn runChunk(any_ctx: ?*anyopaque, chunk: *Chunk) void {
                    var iter = chunk.iter(Row); // TODO: Chunk iterator
                    while (iter.next()) |row| {
                        if (has_ctx) {
                            const ctx: *Context = @ptrCast(@alignCast(any_ctx.?));
                            @call(.@"always_inline", Context.run, .{ctx, row} ++ extra_args);
                        } else {
                            @call(.@"always_inline", Context.run, .{row} ++ extra_args);
                        }
                    }
                }
            },
            .@"fn" => struct {
                pub const Row = info.@"fn".params[0].type.?;
                pub const vtable: System.VTable = .{
                    .init = null,
                    .deinit = null,
                    .run_chunk = runChunk,
                };

                pub fn runChunk(_: ?*anyopaque, chunk: *Chunk) void {
                    var iter = chunk.iter(Row); // TODO: Chunk iterator
                    while (iter.next()) |row| {
                        @call(.@"always_inline", ctx_or_fn, .{row} ++ extra_args);
                    }
                }
            },
            else => @compileError("Expected a Context type or function to run"),
        };
    }

    // TODO: Might be impossible to schedule based on order that before/after systems got scheduled
    // TODO: Level reordering when possible?
    fn addSystem(self: *@This(), system: *System, opts: ScheduleOptions) !void {
        // Find level of each before and after system, computing range of
        // potential levels
        var min_level: usize = 0;
        for (opts.before) |before_system| {
            const i = self.findSystemLevel(before_system) orelse return error.InvalidBeforeSystem;
            min_level = @max(min_level, i + 1);
        }

        var max_level: usize = self.levels.items.len;
        for (opts.after) |after_system| {
            const i = self.findSystemLevel(after_system) orelse return error.InvalidAfterSystem;
            max_level = @min(max_level, i);
        }

        // If there is no range that satisfies constraints, error
        if (min_level > max_level) return error.CouldntSatisfyConstraints;

        // Find level in range that doesn't conflict with system
        // If none exists, add new level in range
        const level_i = blk: for (min_level..max_level) |i| {
            if (!system.rw.conflicts(self.levels.items[i].rw)) break :blk i;
        } else {
            const i = self.levels.items.len;
            try self.levels.append(self.alloc, .empty);
            break :blk i;
        };

        try self.addToLevel(level_i, system);
    }

    fn findSystemLevel(self: *@This(), system: *System) ?usize {
        for (self.levels.items) |*level| {
            if (!system.rw.conflicts(system.rw)) continue;

            if (std.mem.indexOfScalar(*System, level.systems.items, system)) |i| return i;
        } else return null;
    }

    fn addToLevel(self: *@This(), level_i: usize, system: *System) !void {
        // Add to level and update pointers
        const level = &self.levels.items[level_i];
        try level.systems.append(self.alloc, system);
        level.rw = level.rw.unionWith(system.rw);

        // Add system dependencies
        for (self.levels.items[0..level_i]) |*before_level| {
            for (before_level.systems.items) |before_system| {
                if (system.rw.conflicts(before_system.rw))
                    try before_system.append(self.alloc, system);
            }
        }

        // Add dependent systems
        for (self.levels.items[level_i..][1..]) |*after_level| {
            for (after_level.systems.items) |after_system| {
                if (system.rw.conflicts(after_system.rw))
                    try system.append(self.alloc, after_system);
            }
        }
    }

    // Topologically sorts system graph. Moves ownership to compiled graph
    // TODO: Remove superfluous connections
    pub fn build(self: *@This()) CompiledGraph {
        // Free unnecessary data. Levels must be cleared so as to avoid double free on error
        defer self.levels.clearAndFree(self.alloc);
        defer for (self.levels.items) |*level|
            level.systems.deinit(self.alloc);

        var systems: List = .{};

        // In order traversal, each level sorted by fanout size
        // This should guarantee optimal scheduling order
        for (self.levels.items) |*level| {
            level.sort();
            for (level.systems.items) |system|
                systems.append(&system.node);
        }

        return .{ .systems = systems };
    }
};

pub const CompiledGraph = struct {
    systems: List,

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        var next: ?*System = .fromOpt(self.systems.first);
        while (next) |system| {
            next = system.next();
            system.nexts.deinit(alloc);
            alloc.destroy(system);
        }
    }
};

const Worker = struct {
    chunks: AtomicDeque = .empty,

    pub fn run(self: *@This(), scheduler: *Self) void {
        _ = self;
        _ = scheduler;
    }
};

pub const Options = struct {
    alloc: ?Allocator = null,
};

pub fn init(ecs: *World, opts: Options) Self {
    return .{
        .ecs = ecs,
        .system = undefined,
        .workers = &.{},
        .alloc = opts.alloc orelse ecs.alloc,
    };
}

pub fn deinit(_: *Self) void {}

pub fn createGraph(self: *const Self) Graph {
    return .init(self.alloc);
}

pub fn run(self: *Self, graph: CompiledGraph) !void {
    const thread_count = Thread.getCpuCount()
        catch return self.runSingleThreaded();
    var threads = try self.alloc.alloc(Thread, thread_count);
    var workers = try self.alloc.alloc(Worker, thread_count);
    defer self.alloc.free(threads);

    // TODO: Error handling instead of .?
    self.system = .init(.from(graph.systems.first.?));

    for (0..thread_count) |i| {
        workers[i] = .{};
        threads[i] = try Thread.spawn(.{}, Worker.run, .{ &workers[i], self });
    }

    for (threads) |thread| thread.join();
}

pub fn runSingleThreaded(self: *Self) void {
    _ = self;
}


const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

const tests = struct {
    const Position = struct {
        x: f32,
        y: f32,
        z: f32,
    };

    const Velocity = struct {
        x: f32,
        y: f32,
        z: f32,
    };

    const Acceleration = struct {
        x: f32,
        y: f32,
        z: f32,
    };

    fn movement(e: struct { pos: *Position, vel: *const Velocity }) void {
        e.pos.x += e.vel.x;
        e.pos.y += e.vel.y;
        e.pos.z += e.vel.z;
    }

    fn accelerate(e: struct { vel: *Velocity, acc: *const Acceleration }) void {
        e.vel.x += e.acc.x;
        e.vel.y += e.acc.y;
        e.vel.z += e.acc.z;
    }

    // I don't know why you'd actually do this; this is just for testing
    fn normalizePos(e: struct { pos: *Position }) void {
        const mag = @sqrt(e.pos.x * e.pos.x + e.pos.y * e.pos.y + e.pos.z * e.pos.z);
        e.pos.x /= mag;
        e.pos.y /= mag;
        e.pos.z /= mag;
    }

    fn normalizeVel(e: struct { vel: *Velocity }) void {
        const mag = @sqrt(e.vel.x * e.vel.x + e.vel.y * e.vel.y + e.vel.z * e.vel.z);
        e.vel.x /= mag;
        e.vel.y /= mag;
        e.vel.z /= mag;
    }
};

fn setup() !World {
    var ecs: World = .init(testing.allocator, .{});

    const pos1: tests.Position = .{ .x = 1, .y = 2, .z = 3 };
    const vel1: tests.Velocity = .{ .x = 1, .y = 2, .z = 3 };
    const pos2: tests.Position = .{ .x = 4, .y = 5, .z = 6 };
    const vel2: tests.Velocity = .{ .x = 4, .y = 5, .z = 6 };
    const acc1: tests.Acceleration = .{ .x = 1, .y = 1, .z = 1 };

    const e1 = try ecs.create(.{ pos1 });
    const e2 = try ecs.create(.{ pos1, vel1 });
    const e3 = try ecs.create(.{ pos2, vel1 });
    const e4 = try ecs.create(.{ pos2, vel1 });
    const e5 = try ecs.create(.{ pos1, vel2, acc1 });

    try ecs.expectGet(e1, .{ pos1 });
    try ecs.expectGet(e2, .{ pos1, vel1 });
    try ecs.expectGet(e3, .{ pos2, vel1 });
    try ecs.expectGet(e4, .{ pos2, vel1 });
    try ecs.expectGet(e5, .{ pos1, vel2, acc1 });

    return ecs;
}

fn expectOrder(expected: []const *const System, graph: *const CompiledGraph) !void {
    var next: ?*System = .fromOpt(graph.systems.first);
    var actual: Array(*const System) = .empty;
    defer actual.deinit(testing.allocator);

    while (next) |system| : (next = system.next())
        try actual.append(testing.allocator, system);

    errdefer {
        for (actual.items) |system| {
            std.debug.print("{s}: &.{{ .read = {}, .write = {} }}, &.{{\n", .{ system.name, system.rw.read.mask, system.rw.write.mask });
            for (system.nexts.items) |next_system|
                std.debug.print("    {s}: &.{{ .read = {}, .write = {} }},\n", .{ next_system.name, next_system.rw.read.mask, next_system.rw.write.mask });
            std.debug.print("}}\n", .{});
        }
    }

    try expectEqualSlices(*const System, expected, actual.items);
}

fn expectLevels(expected: []const []const *const System, graph: *const Graph) !void {
    errdefer {
        var lookup: [rtti.num_comps][]const u8 = @splat("");
        inline for (&.{ tests.Position, tests.Velocity, tests.Acceleration }) |T|
            lookup[rtti.typeId(T)] = @typeName(T);

        std.debug.print("expected levels: &.{{\n", .{});
        for (expected) |row| {
            std.debug.print("    &.{{\n", .{});
            for (row) |system| {
                std.debug.print("        {*}{{ .read = &.{{ ", .{system});
                var iter = system.rw.read.iterator(.{});
                while (iter.next()) |i|
                    std.debug.print("{s}, ", .{lookup[i]});

                std.debug.print("}}, .write = &.{{ ", .{});
                iter = system.rw.write.iterator(.{});
                while (iter.next()) |i|
                    std.debug.print("{s}, ", .{lookup[i]});

                std.debug.print("}},\n", .{});
            }
            std.debug.print("    }},\n", .{});
        }
        std.debug.print("}}\n", .{});

        std.debug.print("actual levels: &.{{\n", .{});
        for (graph.levels.items) |*level| {
            std.debug.print("    &.{{\n", .{});
            for (level.systems.items) |system| {
                std.debug.print("        {*}{{ .read = &.{{ ", .{system});
                var iter = system.rw.read.iterator(.{});
                while (iter.next()) |i|
                    std.debug.print("{s}, ", .{lookup[i]});

                std.debug.print("}}, .write = &.{{ ", .{});
                iter = system.rw.write.iterator(.{});
                while (iter.next()) |i|
                    std.debug.print("{s}, ", .{lookup[i]});

                std.debug.print("}},\n", .{});
            }
            std.debug.print("    }},\n", .{});
        }
        std.debug.print("}}\n", .{});
    }

    if (expected.len != graph.levels.items.len)
        return error.DifferentColLengths;

    for (graph.levels.items, 0..) |*level, i| {
        // Prematurely sort to test ordering
        level.sort();

        try expectEqualSlices(*const System, expected[i], level.systems.items);
    }
}

test "simple graph" {
    var ecs: World = .init(testing.allocator, .{});
    defer ecs.deinit();
    var scheduler: Self = .init(&ecs, .{});
    defer scheduler.deinit();

    var graph: Graph = scheduler.createGraph();
    errdefer graph.deinit();

    const move_sys = try graph.schedule(tests.movement, .{});
    const acc_sys = try graph.schedule(tests.accelerate, .{});
    var compiled = graph.build();
    defer compiled.deinit(scheduler.alloc);

    try expectOrder(&.{ move_sys, acc_sys }, &compiled);
}

test "complex graph" {
    var ecs = try setup();
    defer ecs.deinit();

    var scheduler: Self = .init(&ecs, .{});
    defer scheduler.deinit();

    var graph: Graph = scheduler.createGraph();
    errdefer graph.deinit();

    const move_sys = try graph.scheduleOpts(tests.movement, .{}, .{ .name = "movement" });
    const acc_sys = try graph.scheduleOpts(tests.accelerate, .{}, .{ .name = "acceleration" });
    const norm_pos_sys = try graph.scheduleOpts(tests.normalizePos, .{}, .{
        .name = "normalize_position",
        .before = &.{move_sys},
    });
    const norm_vel_sys = try graph.scheduleOpts(tests.normalizeVel, .{}, .{
        .name = "normalize_velocity",
        .before = &.{acc_sys},
    });
    try expectLevels(&.{
        &.{ move_sys },
        &.{ acc_sys, norm_pos_sys },
        &.{ norm_vel_sys },
    }, &graph);

    var compiled = graph.build();
    defer compiled.deinit(scheduler.alloc);

    try expectOrder(&.{ move_sys, acc_sys, norm_pos_sys, norm_vel_sys }, &compiled);
}
