const std = @import("std");

// https://zig.news/xq/cool-zig-patterns-type-identifier-3mfd
const section = ".bss.typeids";
const head: u8 align(1) linksection(section) = undefined;

/// Returns a unique integer for every type passed to
/// the function. It is idempotent. For compound types
/// (struct, union), uniqueness is determined by
/// declaration site. Thus, the same struct defined in
/// two places will have a unique type id, whereas the
/// same declaration will always be given the same type
/// id. Anonymous structs are always unique.
pub fn typeId(T: type) usize {
    // Reference head to ensure that it is placed first
    // Note that a simple discard will not work
    const first = @intFromPtr(&head) + 1;
    return @intFromPtr(&struct {
        const _ = T;
        const index: u8 align(1) linksection(section) = undefined;
    }.index) - first;
}

const expect = std.testing.expect;

test "basic types" {
    try expect(typeId(u8) == 0);
    try expect(typeId(u16) == 1);
    try expect(typeId(u8) == typeId(u8));
    try expect(typeId(u16) == typeId(u16));
    try expect(typeId(u8) != typeId(u16));
    try expect(typeId(void) == typeId(void));
}

test "compound types" {
    const T = struct { field: []const u8 };
    try expect(typeId(T) == typeId(T));
    const U = enum { tag1, tag2 };
    try expect(typeId(U) == typeId(U));
    const V = union { tag1: void, tag2: u8 };
    try expect(typeId(V) == typeId(V));
}

test "generic types" {
    const T = struct {
        fn T(U: type) type {
            return struct { u: U };
        }
    }.T;
    try expect(typeId(T(u8)) == typeId(T(u8)));
    try expect(typeId(T(u8)) != typeId(T(u16)));
}

test "anonymous types" {
    try expect(typeId(struct { field: []const u8 }) != typeId(struct { field: []const u8 }));
    try expect(typeId(struct { field1: []const u8 }) != typeId(struct { field2: []const u8 }));
}
