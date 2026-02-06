const std = @import("std");
const Timer = std.time.Timer;
const print = std.debug.print;
const World = @import("World.zig");

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    dx: f32,
    dy: f32,
};

const Health = struct {
    hp: u16,
};

const iterations: usize = 1_000_000;

// TODO: Implement
const Bench = struct {
    timer: Timer,
    opts: Options,

    pub const Options = struct {
        iterations: usize = 1_000_000,
        warmup_trials: usize = 1,
        trials: usize = 5,
    };
    const Self = @This();

    pub fn init(opts: Options) !Self {
        return .{
            .timer = try .start(),
            .opts = opts,
        };
    }

    // pub fn run(bench_fn: fn (ctx: *Context) )
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ecs: World = .init(alloc);
    defer ecs.deinit();

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var timer: Timer = try Timer.start();
    var elapsed_create: u64 = 0;

    var ids: [iterations]World.EntityID = undefined;
    var pos: Position = undefined;
    var vel: Velocity = undefined;
    random.bytes(@ptrCast(&pos));
    random.bytes(@ptrCast(&vel));

    timer.reset();
    for (0..iterations) |i| {
        ids[i] = try @call(.never_inline, World.create, .{ &ecs, .{ pos, vel } });
        std.mem.doNotOptimizeAway(&ids[i]);
    }
    elapsed_create = timer.read();

    random.shuffle(World.EntityID, &ids);

    timer.reset();
    for (0..iterations) |i| {
        std.mem.doNotOptimizeAway(&ids[i]);
        @call(.never_inline, World.delete, .{ &ecs, ids[i] });
    }
    const elapsed_delete = timer.read();

    timer.reset();
    for (0..iterations) |i| {
        ids[i] = try @call(.never_inline, World.create, .{ &ecs, .{ pos, vel } });
        std.mem.doNotOptimizeAway(&ids[i]);
    }
    const elapsed_reuse = timer.read();

    random.shuffle(World.EntityID, &ids);

    const hp = random.int(u16);
    timer.reset();
    for (0..iterations) |i| {
        std.mem.doNotOptimizeAway(&ids[i]);
        try @call(.never_inline, World.addValue, .{ &ecs, ids[i], Health{ .hp = hp } });
    }
    const elapsed_add = timer.read();

    random.shuffle(World.EntityID, &ids);

    timer.reset();
    for (0..iterations) |i| {
        const data = @call(.never_inline, World.getMany, .{ &ecs, ids[i], struct { Position, Health } });
        std.mem.doNotOptimizeAway(&data);
    }
    const elapsed_get = timer.read();

    random.shuffle(World.EntityID, &ids);

    timer.reset();
    for (0..iterations) |i| {
        std.mem.doNotOptimizeAway(&ids[i]);
        try @call(.never_inline, World.remove, .{ &ecs, ids[i], Health });
    }
    const elapsed_remove = timer.read();

    timer.reset();
    var iter = ecs.iter(struct { pos: Position, vel: Velocity });
    while (iter.next()) |e| {
        e.pos.x += e.vel.dx;
        e.pos.y += e.vel.dy;
    }
    const elapsed_iter = timer.read();

    const elapsed_create_s: f64 = @as(f64, @floatFromInt(elapsed_create)) / 1e9;
    const elapsed_delete_s: f64 = @as(f64, @floatFromInt(elapsed_delete)) / 1e9;
    const elapsed_reuse_s: f64 = @as(f64, @floatFromInt(elapsed_reuse)) / 1e9;
    const elapsed_add_s: f64 = @as(f64, @floatFromInt(elapsed_add)) / 1e9;
    const elapsed_get_s: f64 = @as(f64, @floatFromInt(elapsed_get)) / 1e9;
    const elapsed_remove_s: f64 = @as(f64, @floatFromInt(elapsed_remove)) / 1e9;
    const elapsed_iter_s: f64 = @as(f64, @floatFromInt(elapsed_iter)) / 1e9;
    print("Ran {} iterations\n", .{iterations});
    print("Create:\n", .{});
    print("  Elapsed time: {:.3} s\n", .{elapsed_create_s});
    print("  Average time per op: {e:.3} s\n", .{elapsed_create_s / @as(f64, @floatFromInt(iterations))});
    print("  Throughput: {} ops/s\n", .{@round(@as(f64, @floatFromInt(iterations)) / elapsed_create_s)});
    print("Delete:\n", .{});
    print("  Elapsed time: {:.3} s\n", .{elapsed_delete_s});
    print("  Average time per op: {e:.3} s\n", .{elapsed_delete_s / @as(f64, @floatFromInt(iterations))});
    print("  Throughput: {} ops/s\n", .{@round(@as(f64, @floatFromInt(iterations)) / elapsed_delete_s)});
    print("Create (with reuse):\n", .{});
    print("  Elapsed time: {:.3} s\n", .{elapsed_reuse_s});
    print("  Average time per op: {e:.3} s\n", .{elapsed_reuse_s / @as(f64, @floatFromInt(iterations))});
    print("  Throughput: {} ops/s\n", .{@round(@as(f64, @floatFromInt(iterations)) / elapsed_reuse_s)});
    print("Add component:\n", .{});
    print("  Elapsed time: {:.3} s\n", .{elapsed_add_s});
    print("  Average time per op: {e:.3} s\n", .{elapsed_add_s / @as(f64, @floatFromInt(iterations))});
    print("  Throughput: {} ops/s\n", .{@round(@as(f64, @floatFromInt(iterations)) / elapsed_add_s)});
    print("Get component:\n", .{});
    print("  Elapsed time: {:.3} s\n", .{elapsed_get_s});
    print("  Average time per op: {e:.3} s\n", .{elapsed_get_s / @as(f64, @floatFromInt(iterations))});
    print("  Throughput: {} ops/s\n", .{@round(@as(f64, @floatFromInt(iterations)) / elapsed_get_s)});
    print("Remove component:\n", .{});
    print("  Elapsed time: {:.3} s\n", .{elapsed_remove_s});
    print("  Average time per op: {e:.3} s\n", .{elapsed_remove_s / @as(f64, @floatFromInt(iterations))});
    print("  Throughput: {} ops/s\n", .{@round(@as(f64, @floatFromInt(iterations)) / elapsed_remove_s)});
    print("Iterate:\n", .{});
    print("  Elapsed time: {:.3} s\n", .{elapsed_iter_s});
    print("  Average time per op: {e:.3} s\n", .{elapsed_iter_s / @as(f64, @floatFromInt(iterations))});
    print("  Throughput: {} ops/s\n", .{@round(@as(f64, @floatFromInt(iterations)) / elapsed_iter_s)});
}
