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

const Name = struct {
    name: []const u8,
};

const Arch = struct {
    pos: Position,
    vel: Velocity,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ecs: World = .init(alloc);
    defer ecs.deinit();

    // const d1: struct { u8, u16 } = undefined;
    // const d1 = .{ @as(u8, 1), @as(u16, 2) };
    // std.debug.print("size: {}, type: {s}\n", .{ @sizeOf(@TypeOf(d1)), @typeName(@TypeOf(d1)) });

    const player = try ecs.create(&Arch{
        .pos = Position{ .x = 0, .y = 5 },
        .vel = Velocity{ .dx = 1, .dy = 2 },
    });
    std.debug.print("Added player, id {}\n", .{player});
    std.debug.print("Player has data {any}\n", .{ecs.getOnly(struct { Position, Velocity }, player)});
    std.debug.print("Player's velocity: {any}, position: {any}, bogus: {any}\n", .{
        ecs.getComp(player, Velocity),
        ecs.getComp(player, Position),
        ecs.getComp(player, u16),
    });
    const data = .{ @as(u8, 1), @as(u16, 2) };
    std.debug.print("Player has data {any}\n", .{ecs.getAll(struct { Position, Velocity }, player)});
    const e1 = try ecs.create(&data);
    const e2 = try ecs.create(&data);
    std.debug.print("Player has data {any}\n", .{ecs.getAll(struct { Position, Velocity }, player)});
    std.debug.print("Added other entities, ids {} and {}\n", .{ e1, e2 });
    try ecs.add(player, &Name{ .name = "Bob" });
    std.debug.print("Player has data {any}\n", .{ecs.getAll(struct { Position, Velocity }, player)});
    std.debug.print("Player has data {any}\n", .{ecs.getOnly(struct { Name, Position, Velocity }, player)});
    try ecs.remove(player, Name);
    std.debug.print("Player has data {any}\n", .{ecs.getAll(struct { Velocity }, player)});
    std.debug.print("Player has data {any}\n", .{ecs.getOnly(struct { Position, Velocity }, player)});

    for (0..3) |_| {
        ecs.each(Arch, movement);
    }

    ecs.delete(player);
}

fn movement(e: *Arch) void {
    e.pos.x += e.vel.dx;
    e.pos.y += e.vel.dy;
    std.debug.print("Entity {} now at ({}, {})\n", .{ e, e.pos.x, e.pos.y });
}

// pub fn movement(ecs: *World) void {
//     var query = ecs.all(struct { pos: Position, vel: Velocity });
//     while (query.next()) |e| {
//         e.pos.x += e.vel.dx;
//         e.pos.y += e.vel.dy;
//         std.debug.print("Entity {} now at ({}, {})\n", .{ e, e.pos.x, e.pos.y });
//     }
//     std.debug.print("Done moving entities\n", .{});
// }
