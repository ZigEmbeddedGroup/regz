//! Regz JSON output
const std = @import("std");
const json = std.json;
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;

const Database = @import("Database.zig");
const EntityId = Database.EntityId;
const PeripheralInstance = Database.PeripheralInstance;

pub fn loadIntoDb(db: *Database, reader: anytype) !void {
    _ = db;
    _ = reader;
    return error.Todo;
}

pub fn toJson(db: Database) !json.ValueTree {
    var arena = ArenaAllocator.init(db.gpa);
    errdefer arena.deinit();

    const allocator = arena.allocator();
    var root = json.ObjectMap.init(allocator);
    var types = json.ObjectMap.init(allocator);
    var devices = json.ObjectMap.init(allocator);

    // this is a string map to ensure there are no typename collisions
    var types_to_populate = std.StringArrayHashMap(EntityId).init(allocator);

    var device_it = db.instances.devices.iterator();
    while (device_it.next()) |entry|
        try populateDevice(
            db,
            &arena,
            &types_to_populate,
            &devices,
            entry.key_ptr.*,
        );

    try populateTypes(db, &arena, &types);
    try root.put("types", .{ .Object = types });

    try root.put("devices", .{ .Object = devices });
    return json.ValueTree{
        .arena = arena,
        .root = .{ .Object = root },
    };
}

fn populateTypes(
    db: Database,
    arena: *ArenaAllocator,
    types: *json.ObjectMap,
) !void {
    const allocator = arena.allocator();
    var it = db.types.peripherals.iterator();
    while (it.next()) |entry| {
        const periph_id = entry.key_ptr.*;
        const name = db.attrs.names.get(periph_id) orelse continue;
        var typ = json.ObjectMap.init(allocator);
        try populateType(db, arena, periph_id, &typ);
        try types.put(name, .{ .Object = typ });
    }
}

fn populateType(
    db: Database,
    arena: *ArenaAllocator,
    id: EntityId,
    typ: *json.ObjectMap,
) !void {
    const allocator = arena.allocator();
    if (db.attrs.descriptions.get(id)) |description|
        try typ.put("description", .{ .String = description });

    if (db.attrs.offsets.get(id)) |offset|
        try typ.put("offset", .{ .Integer = @intCast(i64, offset) });

    if (db.attrs.sizes.get(id)) |size|
        try typ.put("size", .{ .Integer = @intCast(i64, size) });

    if (db.attrs.reset_values.get(id)) |reset_value|
        try typ.put("reset_value", .{ .Integer = @intCast(i64, reset_value) });

    if (db.attrs.reset_masks.get(id)) |reset_mask|
        try typ.put("reset_mask", .{ .Integer = @intCast(i64, reset_mask) });

    if (db.attrs.versions.get(id)) |version|
        try typ.put("version", .{ .String = version });

    if (db.attrs.access.get(id)) |access| if (access != .read_write)
        try typ.put("access", .{
            .String = switch (access) {
                .read_only => "read-only",
                .write_only => "write-only",
                else => unreachable,
            },
        });

    if (db.types.peripherals.get(id)) |peripheral| {
        var modes = json.ObjectMap.init(allocator);
        {
            var it = peripheral.modes.iterator();
            while (it.next()) |entry| {
                const child_id = entry.key_ptr.*;
                const name = db.attrs.names.get(child_id) orelse continue;
                var child_typ = json.ObjectMap.init(allocator);
                try populateType(db, arena, child_id, &child_typ);
                try modes.put(name, .{ .Object = child_typ });
            }
        }

        var enums = json.ObjectMap.init(allocator);
        {
            var it = peripheral.enums.iterator();
            while (it.next()) |entry| {
                const child_id = entry.key_ptr.*;
                const name = db.attrs.names.get(child_id) orelse continue;
                var child_typ = json.ObjectMap.init(allocator);
                try populateType(db, arena, child_id, &child_typ);
                try enums.put(name, .{ .Object = child_typ });
            }
        }

        var registers = json.ObjectMap.init(allocator);
        {
            var it = peripheral.registers.iterator();
            while (it.next()) |entry| {
                const child_id = entry.key_ptr.*;
                const name = db.attrs.names.get(child_id) orelse continue;
                var child_typ = json.ObjectMap.init(allocator);
                try populateType(db, arena, child_id, &child_typ);
                try registers.put(name, .{ .Object = child_typ });
            }
        }

        var register_groups = json.ObjectMap.init(allocator);
        {
            var it = peripheral.register_groups.iterator();
            while (it.next()) |entry| {
                const child_id = entry.key_ptr.*;
                const name = db.attrs.names.get(child_id) orelse continue;
                var child_typ = json.ObjectMap.init(allocator);
                try populateType(db, arena, child_id, &child_typ);
                try registers.put(name, .{ .Object = child_typ });
            }
        }

        if (modes.count() > 0)
            try typ.put("modes", .{ .Object = modes });
        if (enums.count() > 0)
            try typ.put("enums", .{ .Object = enums });
        if (registers.count() > 0)
            try typ.put("registers", .{ .Object = registers });
        if (register_groups.count() > 0)
            try typ.put("register_groups", .{ .Object = register_groups });
    } else if (db.types.register_groups.get(id)) |register_group| {
        var modes = json.ObjectMap.init(allocator);
        {
            var it = register_group.modes.iterator();
            while (it.next()) |entry| {
                const child_id = entry.key_ptr.*;
                const name = db.attrs.names.get(child_id) orelse continue;
                var child_typ = json.ObjectMap.init(allocator);
                try populateType(db, arena, child_id, &child_typ);
                try modes.put(name, .{ .Object = child_typ });
            }
        }

        var registers = json.ObjectMap.init(allocator);
        {
            var it = register_group.registers.iterator();
            while (it.next()) |entry| {
                const child_id = entry.key_ptr.*;
                const name = db.attrs.names.get(child_id) orelse continue;
                var child_typ = json.ObjectMap.init(allocator);
                try populateType(db, arena, child_id, &child_typ);
                try registers.put(name, .{ .Object = child_typ });
            }
        }

        var register_groups = json.ObjectMap.init(allocator);
        {
            var it = register_group.register_groups.iterator();
            while (it.next()) |entry| {
                const child_id = entry.key_ptr.*;
                const name = db.attrs.names.get(child_id) orelse continue;
                var child_typ = json.ObjectMap.init(allocator);
                try populateType(db, arena, child_id, &child_typ);
                try registers.put(name, .{ .Object = child_typ });
            }
        }

        if (modes.count() > 0)
            try typ.put("modes", .{ .Object = modes });
        if (registers.count() > 0)
            try typ.put("registers", .{ .Object = registers });
        if (register_groups.count() > 0)
            try typ.put("register_group", .{ .Object = register_groups });
    } else if (db.types.registers.get(id)) |register| {
        var modes = json.ObjectMap.init(allocator);
        {
            var it = register.modes.iterator();
            while (it.next()) |entry| {
                const child_id = entry.key_ptr.*;
                const name = db.attrs.names.get(child_id) orelse continue;
                var child_typ = json.ObjectMap.init(allocator);
                try populateType(db, arena, child_id, &child_typ);
                try modes.put(name, .{ .Object = child_typ });
            }
        }

        var fields = json.ObjectMap.init(allocator);
        {
            var it = register.fields.iterator();
            while (it.next()) |entry| {
                const field_id = entry.key_ptr.*;
                assert(db.entityIs("type.field", field_id));
                const name = db.attrs.names.get(field_id) orelse continue;
                var child_typ = json.ObjectMap.init(allocator);
                try populateType(db, arena, field_id, &child_typ);
                try fields.put(name, .{ .Object = child_typ });
            }
        }

        // A register should either have modes, or be active in one of the
        // register group's modes. `modes` will then either be an object or an
        // array respectively
        // TODO: make it less crufty, find better names
        if (modes.count() > 0) {
            try typ.put("modes", .{ .Object = modes });
        } else if (db.attrs.modes.get(id)) |modeset| {
            var array = json.Array.init(allocator);
            var mode_it = modeset.iterator();
            while (mode_it.next()) |entry| {
                const mode_id = entry.key_ptr.*;
                const mode_name = db.attrs.names.get(mode_id) orelse continue;
                try array.append(.{ .String = mode_name });
            }

            try typ.put("modes", .{ .Array = array });
        }

        if (fields.count() > 0)
            try typ.put("fields", .{ .Object = fields });
    } else if (db.types.fields.get(id)) |field| {
        std.log.debug("looking at field: {}", .{field});
        if (db.attrs.enums.get(id)) |enum_id|
            if (db.attrs.names.get(enum_id)) |enum_name|
                try typ.put("enum", .{ .String = enum_name });

        if (db.attrs.modes.get(id)) |modes| {
            var array = json.Array.init(allocator);
            var mode_it = modes.iterator();
            while (mode_it.next()) |entry| {
                const mode_id = entry.key_ptr.*;
                const mode_name = db.attrs.names.get(mode_id) orelse continue;
                try array.append(.{ .String = mode_name });
            }

            try typ.put("modes", .{ .Array = array });
        }
    } else if (db.types.enums.get(id)) |enumeration| {
        var fields = json.ObjectMap.init(allocator);
        var field_it = enumeration.iterator();
        while (field_it.next()) |entry| {
            const field_id = entry.key_ptr.*;
            assert(db.entityIs("type.enum_field", field_id));
            const name = db.attrs.names.get(field_id) orelse continue;
            var child_typ = json.ObjectMap.init(allocator);
            try populateType(db, arena, field_id, &child_typ);
            try fields.put(name, .{ .Object = child_typ });
        }
        if (fields.count() > 0)
            try typ.put("fields", .{ .Object = fields });
    } else if (db.types.enum_fields.get(id)) |enum_field| {
        try typ.put("value", .{ .Integer = enum_field });
    } else if (db.types.modes.get(id)) |mode| {
        try typ.put("value", .{ .String = mode.value });
        try typ.put("qualifier", .{ .String = mode.qualifier });
    }
}

fn populateDevice(
    db: Database,
    arena: *ArenaAllocator,
    types_to_populate: *std.StringArrayHashMap(EntityId),
    devices: *json.ObjectMap,
    id: EntityId,
) !void {
    const allocator = arena.allocator();
    const name = db.attrs.names.get(id) orelse return error.MissingDeviceName;

    var device = json.ObjectMap.init(allocator);
    var properties = json.ObjectMap.init(allocator);
    var prop_it = db.instances.devices.get(id).?.properties.iterator();
    while (prop_it.next()) |entry|
        try properties.put(entry.key_ptr.*, .{ .String = entry.value_ptr.* });

    var interrupts = json.ObjectMap.init(allocator);
    var interrupt_it = db.instances.devices.get(id).?.interrupts.iterator();
    while (interrupt_it.next()) |entry|
        try populateInterrupt(db, arena, &interrupts, entry.key_ptr.*);

    // TODO: link peripherals to device
    var peripherals = json.ObjectMap.init(allocator);
    var periph_it = db.instances.peripherals.iterator();
    while (periph_it.next()) |entry|
        try populatePeripheral(
            db,
            arena,
            types_to_populate,
            &peripherals,
            entry.key_ptr.*,
            entry.value_ptr.*,
        );

    if (properties.count() > 0)
        try device.put("properties", .{ .Object = properties });

    if (interrupts.count() > 0)
        try device.put("interrupts", .{ .Object = interrupts });

    if (peripherals.count() > 0)
        try device.put("peripherals", .{ .Object = peripherals });

    try devices.put(name, .{ .Object = device });
}

fn populateInterrupt(
    db: Database,
    arena: *ArenaAllocator,
    interrupts: *json.ObjectMap,
    id: EntityId,
) !void {
    const allocator = arena.allocator();
    var interrupt = json.ObjectMap.init(allocator);

    const name = db.attrs.names.get(id) orelse return error.MissingInterruptName;
    const index = db.instances.interrupts.get(id) orelse return error.MissingInterruptIndex;
    try interrupt.put("index", .{ .Integer = index });
    if (db.attrs.descriptions.get(id)) |description|
        try interrupt.put("description", .{ .String = description });

    try interrupts.put(name, .{ .Object = interrupt });
}

fn populatePeripheral(
    db: Database,
    arena: *ArenaAllocator,
    types_to_populate: *std.StringArrayHashMap(EntityId),
    peripherals: *json.ObjectMap,
    id: EntityId,
    instance: PeripheralInstance,
) !void {
    const allocator = arena.allocator();
    const name = db.attrs.names.get(id) orelse return error.MissingPeripheralName;
    var peripheral = json.ObjectMap.init(allocator);
    if (db.attrs.descriptions.get(id)) |description|
        try peripheral.put("description", .{ .String = description });

    if (db.attrs.offsets.get(id)) |offset|
        try peripheral.put("offset", .{ .Integer = @intCast(i64, offset) });

    if (db.attrs.versions.get(id)) |version|
        try peripheral.put("version", .{ .String = version });

    // if the peripheral instance's type is named, then we add it to the list
    // of types to populate
    if (db.attrs.names.get(instance.type_id)) |type_name| {
        // TODO: handle collisions -- will need to inline the type
        try types_to_populate.put(type_name, instance.type_id);
        try peripheral.put("type", .{ .String = type_name });
    }

    var child_it = instance.children.iterator();
    while (child_it.next()) |entry| {
        const child_id = entry.key_ptr.*;
        _ = child_id;
    }

    try peripherals.put(name, .{ .Object = peripheral });
}

// =============================================================================
// loadIntoDb Tests
// =============================================================================

// =============================================================================
// toJson Tests
// =============================================================================
