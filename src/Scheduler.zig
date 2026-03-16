const std = @import("std");
const Allocator = std.mem.Allocator;
const Array = std.ArrayListUnmanaged;
const Map = std.AutoHashMapUnmanaged;
const List = std.DoublyLinkedList;
const Atomic = std.atomic.Value;
const Thread = std.Thread;
const Queue = @import("Queue.zig");
const World = @import("World.zig");
const Chunk = @import("Chunk.zig");
const rtti = @import("rtti.zig");
const Mask = rtti.Mask;

systems: CompiledGraph.Iterator,
arch: Atomic(u16),
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
        const w_conflict = !self.write.intersectWith(other.write.unionWith(other.read)).eql(.initEmpty());
        const r_conflict = !self.read.intersectWith(other.write).eql(.initEmpty());
        return w_conflict or r_conflict;
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

    pub fn toMask(self: @This()) Mask {
        return self.read.unionWith(self.write);
    }
};

const System = struct {
    rw: RwMask,
    ctx: ?*anyopaque = null,
    vtable: VTable,
    prevs: []const *System,
    nexts: []const *System,
    // For debugging
    name: [:0]const u8,

    pub const VTable = struct {
        init: ?*const fn () *anyopaque,
        deinit: ?*const fn (?*anyopaque) void,
        run_chunk: *const fn (?*anyopaque, *Chunk) void,
    };

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

/// Set of systems to be run in parallel
const Level = struct {
    rw: RwMask,
    systems: Array(*System),
    // Systems left to run before moving on to next level
    remaining: Atomic(usize) = undefined,

    pub const empty: @This() = .{
        .rw = .empty,
        .systems = .empty,
    };

    /// Sort in descending order based on fanout
    pub fn sort(self: *@This()) void {
        std.sort.insertion(*System, self.systems.items, {}, struct {
            pub fn lessThan(_: void, a: *System, b: *System) bool {
                return a.nexts.len > b.nexts.len; // Greater than to sort descending
            }
        }.lessThan);
    }
};

/// DAG of systems to run
pub const Graph = struct {
    levels: Array(Level),
    alloc: Allocator,

    pub const ScheduleOptions = struct {
        name: ?[:0]const u8 = null,
        /// Must run after these systems
        after: []const *System = &.{},
        /// Must run before these systems
        before: []const *System = &.{},
    };

    pub fn init(alloc: Allocator) @This() {
        return .{
            .levels = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.levels.items) |*level| {
            for (level.systems.items) |system|
                self.alloc.destroy(system);

            level.systems.deinit(self.alloc);
        }

        self.levels.deinit(self.alloc);
    }

    pub fn schedule(self: *@This(), ctx_or_fn: anytype, extra_args: anytype) !*System {
        return self.scheduleOpts(ctx_or_fn, extra_args, .{});
    }

    /// Schedule a system before other systems
    pub fn scheduleBefore(self: *@This(), ctx_or_fn: anytype, extra_args: anytype, before: []const *System) !*System {
        return self.scheduleOpts(ctx_or_fn, extra_args, .{ .before = before });
    }

    /// Schedule a system after other systems
    pub fn scheduleAfter(self: *@This(), ctx_or_fn: anytype, extra_args: anytype, after: []const *System) !*System {
        return self.scheduleOpts(ctx_or_fn, extra_args, .{ .after = after });
    }

    // TODO: Add real type for extra_args
    // TODO: Validate types
    pub fn scheduleOpts(self: *@This(), ctx_or_fn: anytype, extra_args: anytype, opts: ScheduleOptions) !*System {
        const Impl = getImpl(ctx_or_fn, extra_args);

        const system = try self.alloc.create(System);
        system.* = .{
            .rw = .fromType(Impl.Row),
            .vtable = Impl.vtable,
            .prevs = opts.after,
            .nexts = opts.before,
            .name = Impl.name,
        };

        try self.addSystem(system);

        return system;
    }

    fn getImpl(ctx_or_fn: anytype, extra_args: anytype) type {
        const info = @typeInfo(@TypeOf(ctx_or_fn));
        return switch (info) {
            .type => struct {
                const Context = ctx_or_fn;
                pub const Row = Context.Row;
                pub const name = if (@hasDecl(Context, "name")) Context.name else @typeName(Row);
                pub const vtable: System.VTable = .{
                    .init = @This().init,
                    .deinit = @This().deinit,
                    .run_chunk = runChunk,
                };

                const has_ctx = @typeInfo(@TypeOf(Context.init)).@"fn".return_type != null;

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
                pub const name = @typeName(Row);
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
    // TODO: Coffman-Graham algorithm, offline graph creation
    fn addSystem(self: *@This(), system: *System) !void {
        // Find level of each before and after system, computing range of
        // potential levels
        var min_level: usize = 0;
        for (system.prevs) |before_system| {
            const i = self.findSystemLevel(before_system) orelse return error.InvalidBeforeSystem;
            min_level = @max(min_level, i + 1);
        }

        var max_level: usize = self.levels.items.len;
        for (system.nexts) |after_system| {
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
            try self.levels.insert(self.alloc, max_level, .empty);
            break :blk max_level;
        };

        try self.addToLevel(level_i, system);
    }

    // Returns index of level where system is present
    fn findSystemLevel(self: *@This(), system: *System) ?usize {
        for (self.levels.items, 0..) |*level, i| {
            if (!system.rw.conflicts(level.rw)) continue;

            if (std.mem.indexOfScalar(*System, level.systems.items, system)) |_| return i;
        } else return null;
    }

    fn addToLevel(self: *@This(), level_i: usize, system: *System) !void {
        const level = &self.levels.items[level_i];
        try level.systems.append(self.alloc, system);
        level.rw = level.rw.unionWith(system.rw);
    }

    // Topologically sorts system graph. Moves ownership to compiled graph
    pub fn build(self: *@This()) CompiledGraph {
        // Sort each level sorted by fanout size
        // This should guarantee optimal scheduling order
        for (self.levels.items) |*level|
            level.sort();

        return .{
            .levels = self.levels,
            .alloc = self.alloc,
        };
    }
};

pub const CompiledGraph = struct {
    levels: Array(Level),
    alloc: Allocator,

    pub fn deinit(self: *@This()) void {
        for (self.levels.items) |*level| {
            for (level.systems.items) |system|
                self.alloc.destroy(system);

            level.systems.deinit(self.alloc);
        }

        self.levels.deinit(self.alloc);
    }

    // Reset between uses
    pub fn reset(self: *@This(), thread_count: usize) void {
        for (self.levels.items) |*level|
            level.remaining = .init(thread_count);
    }

    pub fn iter(self: *@This()) Iterator {
        return .init(self);
    }

    pub const Iterator = struct {
        levels: []Level,
        level_i: Atomic(usize),
        system_i: Atomic(usize),

        pub fn init(graph: *CompiledGraph) @This() {
            return .{
                .levels = graph.levels.items,
                .level_i = .init(0),
                .system_i = .init(0),
            };
        }

        // TODO: Assert at least one system in init?
        pub fn get(self: *@This()) *System {
            const level_i = self.level_i.load(.monotonic);
            const system_i = self.system_i.load(.monotonic);
            return self.levels[level_i].systems.items[system_i];
        }

        // TODO
        pub fn next(self: *@This()) ?*System {
            _ = self;
            return null;
        }
    };
};

const Worker = struct {
    chunks: Queue = .empty,

    pub fn run(self: *@This(), scheduler: *Self) void {
        var system = scheduler.systems.get();
        main: while (true) {
            // Run all chunks in archetype
            while (self.chunks.pop()) |node|
                system.runChunk(.from(node));

            // Get next archetype
            // TODO: refactor into fn
            const archs = &scheduler.ecs.archetypes;
            while (true) {
                const arch_i = scheduler.arch.fetchAdd(1, .monotonic);
                if (arch_i >= archs.count()) break;

                const arch = archs.values()[arch_i];
                if (arch.mask.supersetOf(system.rw.toMask())) {
                    // Found a matching archetype, update chunks and retry
                    self.chunks.set(arch.chunks);
                    continue :main;
                }
            }

            // No more archetypes to try, get next system
            system = scheduler.systems.next() orelse break :main;
            // system = scheduler.system.load(.acquire);
            // var next_system = system.next() orelse break :main;
            // while (scheduler.system.cmpxchgWeak(system, next_system, .release, .monotonic)) |new_system| {
            //     next_system = new_system.next() orelse break :main;
            // }

            // Spin wait until system ready
            // var prev_count = system.prev_count.load(.monotonic);
            // while (prev_count == 0)
            //     prev_count = system.prev_count.load(.monotonic);

            // TODO: Work stealing opportunity?

            // Load next archetype

        }

        // Try to work steal
        // Done
    }
};

pub const Options = struct {
    alloc: ?Allocator = null,
};

pub fn init(ecs: *World, opts: Options) Self {
    return .{
        .ecs = ecs,
        .systems = undefined,
        .arch = .init(0),
        .workers = &.{},
        .alloc = opts.alloc orelse ecs.alloc,
    };
}

pub fn deinit(_: *Self) void {}

pub fn createGraph(self: *const Self) Graph {
    return .init(self.alloc);
}

pub fn run(self: *Self, graph: *CompiledGraph) !void {
    const thread_count = Thread.getCpuCount()
        catch return self.runSingleThreaded();
    var threads = try self.alloc.alloc(Thread, thread_count);
    var workers = try self.alloc.alloc(Worker, thread_count);
    defer self.alloc.free(threads);

    graph.reset(thread_count);
    self.systems = .init(graph);

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

fn expectLevels(expected: []const []const *const System, graph: *const CompiledGraph) !void {
    errdefer {
        var lookup: [rtti.num_comps][]const u8 = @splat("");
        // This is kind of a hack, but oh well. I guess I could at least do it for every type in tests?
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

    for (graph.levels.items, 0..) |*level, i|
        try expectEqualSlices(*const System, expected[i], level.systems.items);
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
    defer compiled.deinit();

    try expectLevels(&.{
        &.{ move_sys },
        &.{ acc_sys },
    }, &compiled);
}

test "complex graph" {
    var ecs = try setup();
    defer ecs.deinit();

    var scheduler: Self = .init(&ecs, .{});
    defer scheduler.deinit();

    var graph: Graph = scheduler.createGraph();
    errdefer graph.deinit();

    const move_sys = try graph.schedule(tests.movement, .{});
    const acc_sys = try graph.schedule(tests.accelerate, .{});
    const norm_pos_sys = try graph.scheduleAfter(tests.normalizePos, .{}, &.{move_sys});
    const norm_vel_sys = try graph.scheduleAfter(tests.normalizeVel, .{}, &.{acc_sys});
    var compiled = graph.build();
    defer compiled.deinit();

    try expectLevels(&.{
        &.{ move_sys },
        &.{ acc_sys, norm_pos_sys },
        &.{ norm_vel_sys },
    }, &compiled);
}
