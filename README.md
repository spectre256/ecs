# ECS

## Description

This project is an implementation of the
[ECS](https://en.wikipedia.org/wiki/Entity_component_system) design pattern
in Zig.


It's essentially a data structure that allows for fast insertion, deletion, and
iteration over elements (entities), while allowing pieces of data (components)
to be dynamically added and removed.


## Roadmap

- [x] Core data structure design
- [x] Creation and deletion of entities
- [x] Addition and removal of components
- [ ] Benchmarks
- [ ] Maybe refactor everything to allocate data in chunks instead of one
      big array per archetype (for stable performance at large capacities)
- [ ] Thread safety
- [ ] Concurrent system runner


## Installation

First, add the library to your `build.zig.zon`.
```sh
> zig fetch --save https://github.com/spectre256/ecs/#89250f2
```

Then in your `build.zig`, add the following lines.
```zig
const ecs = b.dependency("ecs", .{});
exe.root_module.addImport("ecs", ecs.module("ecs"));
```


## Usage

```zig
const World = @import("ecs");

// Some sample components for us to play with
const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    dx: f32,
    dy: f32,
};

// A set of components we want to use
// In the future, it won't be necessary to explicitly define them up front like this
const Arch = struct {
    pos: Position,
    vel: Velocity,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Initialize
    var ecs: World = .init(alloc);
    defer ecs.deinit();

    // Create an entity by passing a pointer to the component data
    const player = try ecs.create(&Arch{
        .pos = Position{ .x = 0, .y = 5 },
        .vel = Velocity{ .dx = 1, .dy = 2 },
    })

    // Get all components from an entity. Types must be passed in order that the components were created
    const player_ptr = ecs.getRow(struct { Position, Velocity }, player);

    // Get a single component
    const vel_ptr = ecs.getComp(player, Velocity);
    vel_ptr.dx += 5;

    // Get multiple components. Can be used even if the entity has more components
    const comps = ecs.getMany(player, struct { pos: Position, vel: Velocity });
    comps.pos.x = 3;

    // Add and remove components
    try ecs.addValue(player, &Name{ .name = "Bob" });
    try ecs.remove(player, Name);

    // Run a function on every entity with the given components
    ecs.each(Arch, movement);
}

fn movement(e: *Arch) void {
    e.pos.x += e.vel.dx;
    e.pos.y += e.vel.dy;
    std.debug.print("Entity {*} now at ({}, {})\n", .{ e, e.pos.x, e.pos.y });
}
```
