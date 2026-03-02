const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Pool = std.heap.MemoryPool(Chunk);
const LinkedList = std.DoublyLinkedList;
const assert = std.debug.assert;
const typeId = @import("typeid.zig").typeId;
const rtti = @import("rtti.zig");
const Mask = rtti.Mask;

/// List of chunks. Free chunks at the beginning, full
/// chunks at the end
chunks: LinkedList,
/// Offsets of each component array in chunk buffer
offsets: []u16,
/// Component sizes
sizes: []u16,
/// Bitmask of components present in archetype
mask: Mask,
/// Capacity of one chunk. Stored here to save space
capacity: u16,

const Self = @This();
pub const NewResult = struct { *Chunk, u16 };
pub const Chunk = struct {
    header: Header,
    buffer: [buffer_size]u8 align(@alignOf(u32)),

    const buffer_size: usize = std.heap.page_size_min - @sizeOf(Header);
    const Header = struct {
        node: LinkedList.Node,
        arch: u16,
        len: u16,
    };

    pub fn init(self: *@This(), arch: u16) void {
        self.* = .{
            .header = .{
                .node = .{},
                .arch = arch,
                .len = 0,
            },
            .buffer = undefined,
        };
    }

    pub fn ids(self: *@This()) [*]u32 {
        return @as([*]u32, @ptrCast(&self.buffer));
    }

    pub fn new(self: *@This(), entry: u32, capacity: u16) u16 {
        assert(self.header.len < capacity);
        defer self.header.len += 1;
        self.ids()[self.header.len] = entry;
        return self.header.len;
    }

    pub fn isEmpty(self: *const @This()) bool {
        return self.header.len <= 0;
    }

    pub fn isFull(self: *const @This(), capacity: u16) bool {
        return self.header.len >= capacity;
    }

    pub fn next(self: *const @This()) ?*@This() {
        return .from(self.header.node.next);
    }

    pub fn from(node: ?*LinkedList.Node) ?*@This() {
        const header: *Chunk.Header = @fieldParentPtr("node", node orelse return null);
        return @fieldParentPtr("header", header);
    }
};

pub fn init(self: *Self, mask: Mask, alloc: Allocator) !void {
    const len = mask.count();
    const buf = try alloc.alloc(u16, len * 2);
    const offsets = buf[0..len];
    const sizes = buf[len..];

    var padding: usize = 0;
    var last_offset: usize = 0;
    var comps_size: usize = @sizeOf(u32); // Start with size of id

    var bits = mask.iterator(.{});
    var comp_i: usize = 0;
    while (bits.next()) |i| : (comp_i += 1) {
        // Record component size
        const info = rtti.type_infos[i];
        sizes[comp_i] = info.size;
        comps_size += info.size;

        // Calculate sum of padding between component arrays
        const offset = info.alignment.forward(last_offset);
        padding += offset - last_offset;
        last_offset = offset;
    }

    const capacity = (Chunk.buffer_size - padding) / comps_size;
    var offset = @sizeOf(u32) * capacity;

    bits = mask.iterator(.{});
    comp_i = 0;
    while (bits.next()) |i| : (comp_i += 1) {
        // Align to component alignment
        const info = rtti.type_infos[i];
        offset = info.alignment.forward(offset);
        offsets[comp_i] = @intCast(offset);

        // Add size of component array
        offset += sizes[comp_i] * capacity;
    }

    self.* = .{
        .chunks = .{},
        .offsets = offsets,
        .sizes = sizes,
        .mask = mask,
        .capacity = @intCast(capacity),
    };
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    self.offsets.len *= 2; // Allocated in same buffer as sizes
    alloc.free(self.offsets);

    // TODO: Actual chunk allocator
    var next: ?*Chunk = .from(self.chunks.first);
    while (next) |chunk| {
        next = chunk.next();
        alloc.destroy(chunk);
    }
}

pub fn has(self: *const Self, T: type) bool {
    return self.mask.isSet(typeId(T));
}

pub fn hasExact(self: *const Self, Row: type) bool {
    return self.mask.eql(rtti.maskFromType(Row));
}

pub fn hasAll(self: *const Self, Row: type) bool {
    return self.mask.supersetOf(rtti.maskFromType(Row));
}

pub fn isEmpty(self: *const Self) bool {
    const chunk = Chunk.from(self.chunks.first) orelse return true;
    return chunk.isEmpty();
}

/// Computes offsets and sizes for desired components
fn gatherRtti(self: *const Self, Row: type, offsets: *[std.meta.fields(Row).len]usize, sizes: *[std.meta.fields(Row).len]usize) void {
    const other_mask = rtti.maskFromType(Row);
    var bits = self.mask.intersectWith(other_mask).iterator(.{});
    var other_comp_i: usize = 0;
    while (bits.next()) |bit_i| : (other_comp_i += 1) {
        const self_comp_i = rtti.maskIndexOfBit(self.mask, bit_i).?;
        offsets[other_comp_i] = self.offsets[self_comp_i];
        sizes[other_comp_i] = self.sizes[self_comp_i];
    }
}

pub fn get(self: *const Self, chunk: *Chunk, row: u16, Row: type) rtti.PtrsTo(Row) {
    // TODO: This is a temporary solution. Users shouldn't have to
    // remember the order in which they created types. This is hard to
    // fix until typeId can be made to work at comptime, however.
    assert(rtti.ensureInorder(Row));
    assert(self.hasAll(Row));

    const Vec = @Vector(std.meta.fields(Row).len, usize);
    var offsets: Vec = undefined;
    var sizes: Vec = undefined;
    self.gatherRtti(Row, &offsets, &sizes);

    // Calculate pointers
    const base: Vec = @splat(@intFromPtr(&chunk.buffer));
    const ptrs: Vec = base + offsets + sizes * @as(Vec, @splat(row));

    // Noop, just cast the pointers
    var res: rtti.PtrsTo(Row) = undefined;
    inline for (comptime std.meta.fieldNames(Row), 0..) |name, i|
        @field(res, name) = @ptrFromInt(ptrs[i]);

    return res;
}

pub fn getComp(self: *const Self, chunk: *Chunk, row: u16, T: type) *T {
    assert(self.has(T));

    const i = rtti.maskIndexOf(self.mask, T).?;
    const offset = self.offsets[i];
    const size = self.sizes[i];
    const ptr = &chunk.buffer[offset + row * size];
    return @ptrCast(@alignCast(ptr));
}

pub fn new(self: *Self, alloc: Allocator, arch_i: u16, entry: u32) !NewResult {
    if (Chunk.from(self.chunks.first)) |chunk| {
        if (!chunk.isFull(self.capacity)) {
            const i = chunk.new(entry, self.capacity);
            if (chunk.isFull(self.capacity)) {
                _ = self.chunks.popFirst();
                self.chunks.append(&chunk.header.node);
            }
            return .{ chunk, i };
        }
    }

    // TODO: Actual chunk allocator
    const chunk = try alloc.create(Chunk);
    chunk.init(arch_i);
    self.chunks.prepend(&chunk.header.node);
    return .{ chunk, chunk.new(entry, self.capacity) };
}

pub fn create(self: *Self, alloc: Allocator, row: anytype, arch_i: u16, entry: u32) !NewResult {
    const Row = @TypeOf(row);
    assert(rtti.ensureInorder(Row));
    assert(self.hasExact(Row));

    const chunk, const i = try self.new(alloc, arch_i, entry);
    const ptrs = self.get(chunk, i, Row);

    inline for (comptime std.meta.fieldNames(Row)) |name|
        @field(ptrs, name).* = @field(row, name);

    return .{ chunk, i };
}

/// Copy entity from `other` at index `other_i` to `self`. Only copies
/// components present in `self`. Returns the new row index.
pub fn copyFrom(self: *Self, other: *const Self, alloc: Allocator, arch_i: u16, other_chunk: *Chunk, other_i: u32) !NewResult {
    const self_chunk, const self_i = try self.new(alloc, arch_i, other_chunk.ids()[other_i]);

    // Iterate over components in both entities and copy
    var bits = self.mask.intersectWith(other.mask).iterator(.{});
    while (bits.next()) |bit_i| {
        const self_comp_i = rtti.maskIndexOfBit(self.mask, bit_i).?;
        const other_comp_i = rtti.maskIndexOfBit(other.mask, bit_i).?;

        const self_offset = self.offsets[self_comp_i];
        const other_offset = other.offsets[other_comp_i];
        const size = self.sizes[self_comp_i];

        const self_comp = self_chunk.buffer[self_offset..][0..size];
        const other_comp = other_chunk.buffer[other_offset..][0..size];

        @memcpy(self_comp, other_comp);
    }

    return .{ self_chunk, self_i };
}

/// Swaps item to delete with last element and returns entry index of swapped
/// element, or null if the last element was deleted
pub fn delete(self: *Self, chunk: *Chunk, i: u32) ?u32 {
    const len = chunk.header.len - 1;
    assert(i <= len);
    chunk.header.len = len;
    const id = chunk.ids()[len];

    // If deleting from a full chunk, move from full chunk list to free chunk list
    const should_move = chunk.isFull(self.capacity);
    defer if (should_move) {
        self.chunks.remove(&chunk.header.node);
        self.chunks.append(&chunk.header.node);
    };

    if (i != len) {
        @branchHint(.likely);

        // Copy id from last item
        chunk.ids()[i] = id;
        chunk.ids()[len] = undefined;

        // Copy components from last item
        for (self.offsets, self.sizes) |offset, size| {
            const to = chunk.buffer[offset + i * size ..][0..size];
            const from = chunk.buffer[offset + len * size ..][0..size];
            @memcpy(to, from);
            @memset(from, undefined);
        }

        return id;
    } else return null;
}

pub fn iter(self: *const Self, Row: type) Iterator(Row) {
    return .init(self);
}

pub fn Iterator(Row: type) type {
    return struct {
        offsets: Vec,
        ptrs: Vec,
        sizes: Vec,
        chunk: ?*Chunk,
        row: u16,
        len: u16,

        const Vec = @Vector(std.meta.fields(T).len, usize);
        const T = rtti.PtrsTo(Row);

        pub fn init(arch: *const Self) @This() {
            assert(rtti.ensureInorder(Row));
            assert(arch.hasAll(Row));

            var self: @This() = .{
                .offsets = undefined,
                .ptrs = undefined,
                .sizes = undefined,
                .chunk = .from(arch.chunks.first),
                .row = 0,
                .len = undefined,
            };

            arch.gatherRtti(Row, &self.offsets, &self.sizes);
            if (self.chunk) |chunk| {
                const base: Vec = @splat(@intFromPtr(&chunk.buffer));
                self.ptrs = self.offsets + base;
                self.len = chunk.header.len;
            }

            return self;
        }

        pub fn next(self: *@This()) ?T {
            var chunk = self.chunk orelse return null;
            // TODO: Need to have a dedicated chunk pool to avoid empty chunks completely?
            if (self.row >= self.len) {
                while (true) {
                    self.chunk = chunk.next();
                    chunk = self.chunk orelse return null;
                    if (!chunk.isEmpty()) break;
                }

                // Reset iterator
                self.row = 0;
                self.len = chunk.header.len;
                const base: Vec = @splat(@intFromPtr(&chunk.buffer));
                self.ptrs = self.offsets + base;
            }

            self.row += 1;
            defer self.ptrs += self.sizes;

            var item: T = undefined;
            inline for (comptime std.meta.fieldNames(T), 0..) |name, i|
                @field(item, name) = @ptrFromInt(self.ptrs[i]);

            return item;
        }
    };
}
