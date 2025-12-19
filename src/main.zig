const std = @import("std");
const World = @import("ecs.zig");

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    dx: f32,
    dy: f32,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ecs: World = .init(alloc);
    defer ecs.deinit();

    // const player = try ecs.new();
    // player.addComponent(Position{ .x = 0, .y = 5 });
    // player.addComponent(Velocity{ .dx = 1, .dy = 2 });
    const player = try ecs.add(.{
        Position{ .x = 0, .y = 5 },
        Velocity{ .dx = 1, .dy = 2 },
    });
    std.debug.print("Added player, id {}\n", .{player});
    const empty1 = try ecs.new();
    const empty2 = try ecs.new();
    std.debug.print("Added empties, ids {} and {}\n", .{ empty1, empty2 });

    for (0..3) |_| {
        movement(&ecs);
    }
}

pub fn movement(ecs: *World) void {
    var query = ecs.all(struct { pos: Position, vel: Velocity });
    while (query.next()) |e| {
        e.pos.x += e.vel.dx;
        e.pos.y += e.vel.dy;
        std.debug.print("Entity {} now at ({}, {})\n", .{ e, e.pos.x, e.pos.y });
    }
    std.debug.print("Done moving entities\n", .{});
}
