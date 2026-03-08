const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.DoublyLinkedList;
const Chunk = @import("Chunk.zig");

free_chunks: List,
page_alloc: Allocator,

const Self = @This();

pub fn init(alloc: Allocator) Self {
    return .{
        .free_chunks = .{},
        .page_alloc = alloc,
    };
}

pub fn create(self: *Self) !*Chunk {
    if (self.free_chunks.popFirst()) |node| {
        return .from(node);
    } else {
        return self.page_alloc.create(Chunk);
    }
}

pub fn destroy(self: *const Self, chunk: *Chunk) void {
    self.page_alloc.destroy(chunk);
}

pub fn destroyWithReuse(self: *Self, chunk: *Chunk) void {
    self.free_chunks.prepend(&chunk.header.node);
}

pub fn reclaimUnused(self: *Self) void {
    while (self.free_chunks.popFirst()) |node|
        self.destroy(.from(node));
}
