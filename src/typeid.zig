const std = @import("std");

// https://zig.news/xq/cool-zig-patterns-type-identifier-3mfd
const section = ".bss.typeids";
const head: u8 align(1) linksection(section) = undefined;

pub fn typeId(T: type) usize {
    _ = head;
    return @intFromPtr(&struct {
        const _ = T;
        const index: u8 align(1) linksection(section) = undefined;
    }.index) - @intFromPtr(&head) - 1;
}

const expect = std.testing.expect;

fn U(V: type) type {
    return struct { v: V };
}
test {
    std.debug.print("u8 = {}, u16 = {}\n", .{ typeId(u8), typeId(u16) });
    try expect(typeId(u8) == 0);
    try expect(typeId(u16) == 1);
    try expect(typeId(u8) == typeId(u8));
    try expect(typeId(u16) == typeId(u16));
    try expect(typeId(u8) != typeId(u16));
    const T = struct { field: []const u8 };
    try expect(typeId(T) == typeId(T));

    try expect(typeId(U(u8)) == typeId(U(u8)));
    try expect(typeId(U(u8)) != typeId(U(u16)));
    try expect(typeId(struct { field: []const u8 }) != typeId(struct { field: []const u8 }));
    try expect(typeId(struct { field1: []const u8 }) != typeId(struct { field2: []const u8 }));
}
