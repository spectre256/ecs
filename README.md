= ECS

== Description

This project is an implementation of the
(ECS)[https://en.wikipedia.org/wiki/Entity_component_system] design pattern
in Zig.


It's essentially a data structure that allows for fast insertion, deletion, and
iteration over elements (entities), while allowing pieces of data (components)
to be dynamically added and removed.


== Roadmap

- [x] Core data structure design
- [x] Creation and deletion of entities
- [x] Addition and removal of components
- [ ] Benchmarks
- [ ] Maybe refactor everything to allocate data in chunks instead of one
      big array per archetype (for stable performance at large capacities)
- [ ] Thread safety
- [ ] Concurrent system runner
