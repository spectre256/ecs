# ECS

## Description

This project is an implementation of the
[ECS](https://en.wikipedia.org/wiki/Entity_component_system) design pattern
in Zig.


It's essentially a data structure that allows for fast insertion, deletion, and
iteration over elements (entities), while allowing pieces of data (components)
to be dynamically added and removed. It supports:

- O(1) random access
- O(1) creation
- O(1) deletion
- O(1) component addition
- O(1) component removal
- O(N) iteration

Entities are accessed by id, as pointers to their data
are not stable.


## Roadmap

- [x] Core data structure design
- [x] Creation and deletion of entities
- [x] Addition and removal of components
- [x] Benchmarks
- [x] Switch to chunk allocation

    This change was made to allow for stable
    performance even at large capacities and reduce
    memory fragmentation. Each archetype has a list of
    chunks and entity entries store a pointer to the
    chunk their data resides in.
    The list of entity entries is still one large
    array, however. This should be split into an array
    of fixed size chunks as well.
    Currently, the benchmarks only show average time,
    so it is unclear how this affected the worst case
    performance. Average performance has remained the
    same, which is to be expected.

- [ ] Tests
- [ ] Investigate performance anomalies

    Currently, creating new entities after deleting
    others takes roughly twice as long as creating
    entities without deleting any first. The system is
    designed to reuse memory, so this doesn't make
    sense. I would expect a performance improvement
    since the allocation overhead is removed.

- [ ] Parallel system runner

    Since the data is allocated in chunks, it makes
    sense to split up work based on this. I'm thinking
    about implementing the runner with a thread pool
    and thread-local work queues. Since different
    systems may have dramatically different
    performance, I'm considering integrating work
    stealing as well.

- [ ] Command buffer for scheduling changes inside systems

    Any mutating operation (creation, deletion, etc.)
    will invalidate iterators. This limitation may be
    restrictive. Rather than expend the effort to
    implement thread safe operations and accept a
    performance penalty, I am considering implementing
    a "command buffer" which will allow users to
    schedule changes between system invocations.


## Installation

First, add the library to your `build.zig.zon`.
```sh
> zig fetch --save https://github.com/spectre256/ecs/#fdf9fd0
```

Then in your `build.zig`, add the following lines.
```zig
const ecs = b.dependency("ecs", .{});
exe.root_module.addImport("ecs", ecs.module("ecs"));
```


## Usage

```zig
const World = @import("ecs").World;

// Some sample components for us to play with
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

    // Initialize
    var ecs: World = .init(alloc, .{});
    defer ecs.deinit();

    // Create an entity by passing the component data
    const player = try ecs.create(.{
        Position{ .x = 0, .y = 5 },
        Velocity{ .dx = 1, .dy = 2 },
    })

    // Get a single component
    const vel_ptr = ecs.getComp(player, Velocity);
    vel_ptr.dx += 5;

    // Get multiple components from an entity. Can be used
    // even if the entity has more components. Types must be
    // passed in the order that the components were created
    const player_ptrs = ecs.get(player, struct { Position, Velocity });
    player_ptrs.pos.x = 3;

    // Add and remove components
    try ecs.addValue(player, &Name{ .name = "Bob" });
    try ecs.remove(player, Name);

    // Iterate over every entity with the given components
    var iter = ecs.iter(struct { pos: Position, vel: Velocity });
    while (iter.next()) |e| {
        e.pos.x += e.vel.dx;
        e.pos.y += e.vel.dy;
        std.debug.print("Entity {*} now at ({}, {})\n", .{ e, e.pos.x, e.pos.y });
    }

    // Delete an entity
    ecs.delete(player);
}
```
