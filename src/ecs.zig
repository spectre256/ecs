const std = @import("std");
const Allocator = std.mem.Allocator;
const Map = std.AutoArrayHashMapUnmanaged;

const comps = blk: {
    var counter: usize = 0;
    var types: []type = &.{};
    var max_align = 1;

    break :blk struct {
        // Finds index of type, registering it if not
        // already registered. This function is
        // idempotent.
        pub fn indexOfType(T: type) usize {
            max_align = @max(max_align, @alignOf(T));
            for (types, 0..) |U, i| {
                if (T == U) return i;
            } else {
                types = types ++ &.{T};
                defer counter += 1;
                return counter;
            }
        }
    };
};

pub const Mask = std.StaticBitSet(comps.counter);

pub fn maskFromType(T: type) Mask {
    var mask: Mask = .initEmpty();
    for (std.meta.fields(T)) |field| {
        for (comps.types, 0..) |U, i| {
            if (field.type == U) mask.set(i);
            break;
        } else @compileError("Unregistered type '" ++ @typeName(T) ++ "'");
    }
    return mask;
}

pub const EntityID = u32;

pub fn Archetype(Row: type) type {
    return struct {
        rows: Map(u32, Row),
        mask: Mask,

        pub const empty: @This() = .{
            .rows = .empty,
            .mask = .fromType(Row),
        };

        pub fn deinit(self: *@This(), alloc: Allocator) void {
            self.rows.deinit(alloc);
        }

        pub fn has(self: *const @This(), T: type) bool {
            return self.mask.supersetOf(.fromType(T));
        }

        pub fn get(self: *const @This(), id: EntityID) ?*Row {
            return self.rows.getPtr(id);
        }

        pub fn add(self: *@This(), alloc: Allocator, id: EntityID, row: Row) !void {
            return self.rows.put(alloc, id, row);
        }

        pub fn remove(self: *@This(), id: EntityID) ?Row {
            return self.rows.fetchSwapRemove(id);
        }

        pub fn values(self: *const @This()) []Row {
            return self.rows.values();
        }
    };
}

/// Archetypes are always same size regardless of type, so we can store them
/// directly. This type allows storing many different archetypes in the same
/// generic data structure
pub const AnyArchetype = struct {
    data: Archetype(void) align(comps.max_align),

    pub const empty: @This() = .{ .data = .empty };

    pub fn cast(self: *@This(), T: type) *Archetype(T) {
        return @ptrCast(@alignCast(self));
    }
};


archetypes: Map(Mask, AnyArchetype),
counter: EntityID,
alloc: Allocator,

const Self = @This();

pub fn init(alloc: Allocator) Self {
    return .{
        .archetypes = .empty,
        .counter = 0,
        .alloc = alloc,
    };
}

pub fn deinit(self: *Self) void {
    self.archetypes.deinit(self.alloc);
}

pub fn new(self: *Self) !EntityID {
    return self.add(.{});
}

pub fn add(self: *Self, row: anytype) !EntityID {
    const arch = self.getArch(@TypeOf(row));
    try arch.add(self.alloc, self.counter, row);
    self.counter += 1;
}

pub fn remove(self: *Self, id: EntityID) void {
    _ = self;
    _ = id;
}

fn getArch(self: *Self, T: type) !*Archetype(T) {
    const mask = maskFromType(T);
    const res = try self.archetypes.getOrPutValue(mask, .empty);
    return res.value_ptr.cast(T);
}

pub fn addComponent(self: *Self, id: EntityID, comp: anytype) !void {
    _ = self;
    _ = id;
    _ = comp;
}

pub fn Iterator(T: type, iter_all: bool) type {
    return struct {
        ecs: *Self,
        archetype: ?*anyopaque,
        archetype_i: usize,
        row_i: usize,

        pub fn init(ecs: *Self) @This() {
            var self: @This() = .{
                .ecs = ecs,
                .archetype = null,
                .archetype_i = 0,
                .index = 0,
            };
            _ = self.nextArch();
            return self;
        }

        pub fn next(self: *@This()) ?T {
            const arch = self.archetype orelse return null;
            if (self.row_i >= arch.rows.count()) {
                _ = nextArch();
                arch = self.archetype orelse return null;
            }

            defer self.row_i += 1;
            return arch[self.row_i];
        }

        fn nextArch(self: *@This()) bool {
            while (self.archetype_i < self.ecs.archetypes.count()) : (self.archetype_i += 1) {
                const arch = self.ecs.archetypes[self.archetype_i];
                if (match(arch)) {
                    self.archetype = arch;
                    return true;
                }
            } else return false;
        }

        fn match(arch: *anyopaque) bool {
            if (iter_all) {
                return arch.mask.supersetOf(maskFromType(T));
            } else {
                return arch.mask.eql(maskFromType(T));
            }
        }
    };
}

pub fn all(self: *Self, Row: type) Iterator(Row) {
    return .init(self);
}

pub fn each(self: *Self, T: type, f: fn (T) void) void {
    for (self.archetypes) |arch| {
        if (arch.mask.supersetOf(maskFromType(T))) {
            for (arch.values()) |row| {
                f(row);
            }
        }
    }
}
