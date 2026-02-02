const std = @import("std");
const Alignment = std.mem.Alignment;
const typeId = @import("typeid.zig").typeId;

pub const num_comps: usize = 64;
pub var type_infos: [num_comps]struct {
    size: usize,
    alignment: Alignment,
} = undefined;
pub const Mask = std.StaticBitSet(num_comps);

pub fn registerType(T: type) void {
    type_infos[typeId(T)] = .{
        .size = @sizeOf(T),
        .alignment = .of(T),
    };
}

pub fn maskFromType(Row: type) Mask {
    var mask: Mask = .initEmpty();
    inline for (std.meta.fields(Row)) |field| {
        const id = typeId(field.type);
        mask.set(id);
        registerType(field.type);
    }
    return mask;
}

pub fn ensureInorder(T: type) bool {
    var last_id: ?usize = null;
    inline for (std.meta.fields(T)) |field| {
        if (last_id) |id|
            if (typeId(field.type) <= id) return false;

        last_id = typeId(field.type);
    } else return true;
}

pub fn sizeFromMask(mask: Mask, maybe_end: ?usize) usize {
    var total: usize = 0;
    const end = maybe_end orelse num_comps;
    var iter = mask.iterator(.{});
    while (iter.next()) |i| {
        if (i >= end) break;
        const info = type_infos[i];
        total = info.alignment.forward(total) + info.size;
    }
    return total;
}

pub fn alignFromMask(mask: Mask) Alignment {
    var res: Alignment = .@"1";
    var iter = mask.iterator(.{});
    while (iter.next()) |i| res = res.max(type_infos[i].alignment);
    return res;
}

// TODO: This won't work until typeId works at comptime
pub fn Sorted(Row: type) type {
    const Field = std.builtin.Type.StructField;
    const old_fields = std.meta.fields(Row);
    var new_fields: [old_fields.len]Field = undefined;
    @memcpy(&new_fields, old_fields);
    std.sort.insertion(Field, &new_fields, struct {
        fn lessThan(a: Field, b: Field) bool {
            return typeId(a.type) < typeId(b.type);
        }
    }.lessThan);
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &new_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub fn PtrsTo(Row: type) type {
    const old_fields = std.meta.fields(Row);
    var new_fields: [old_fields.len]std.builtin.Type.StructField = undefined;
    @memcpy(&new_fields, old_fields);
    for (&new_fields) |*field| {
        field.type = *field.type;
        field.default_value_ptr = null;
        field.alignment = @alignOf(*field.type);
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &new_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}
