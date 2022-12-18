//! Code generation and associated tests
const std = @import("std");
const assert = std.debug.assert;

const Database = @import("Database.zig");
const EntityId = Database.EntityId;
const EntitySet = Database.EntitySet;

const log = std.log.scoped(.gen);

const EntityWithOffsetAndSize = struct {
    id: EntityId,
    offset: u64,
    size: u64,
};

const EntityWithOffset = struct {
    id: EntityId,
    offset: u64,

    fn lessThan(_: void, lhs: EntityWithOffset, rhs: EntityWithOffset) bool {
        return lhs.offset < rhs.offset;
    }
};

pub fn toZig(db: Database, out_writer: anytype) !void {
    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    const writer = buffer.writer();
    try writer.writeAll("const mmio = @import(\"mmio\");\n");
    try writeDevices(db, writer);
    try writeTypes(db, writer);
    try writer.writeByte(0);

    //try out_writer.writeAll(buffer.items);
    // format the generated code
    var ast = try std.zig.parse(db.gpa, @ptrCast([:0]const u8, buffer.items[0 .. buffer.items.len - 1]));
    defer ast.deinit(db.gpa);

    // TODO: ast check?
    const text = try ast.render(db.gpa);
    defer db.gpa.free(text);

    try out_writer.writeAll(text);
}

fn writeDevices(db: Database, writer: anytype) !void {
    if (db.instances.devices.count() == 0)
        return;

    try writer.writeAll(
        \\
        \\pub const devices = struct {
        \\
    );

    // TODO: order devices alphabetically
    var it = db.instances.devices.iterator();
    while (it.next()) |entry| {
        const device_id = entry.key_ptr.*;
        writeDevice(db, device_id, writer) catch |err| {
            log.warn("failed to write device: {}", .{err});
        };
    }

    try writer.writeAll("};\n");
}

fn writeDevice(db: Database, device_id: EntityId, out_writer: anytype) !void {
    assert(db.entityIs("instance.device", device_id));
    const name = db.attrs.names.get(device_id) orelse return error.MissingDeviceName;

    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    const writer = buffer.writer();
    // TODO: multiline?
    if (db.attrs.descriptions.get(device_id)) |description|
        try writer.print("/// {s}\n", .{description});

    try writer.print(
        \\pub const {s} = struct {{
        \\
    , .{std.zig.fmtId(name)});

    // TODO: alphabetic order
    const properties = db.instances.devices.get(device_id).?.properties;
    {
        var it = properties.iterator();
        while (it.next()) |entry|
            try writer.print(
                \\pub const {s} = "{s}";
                \\
            , .{
                std.zig.fmtId(entry.key_ptr.*),
                entry.value_ptr.*,
            });

        try writer.writeByte('\n');
    }

    // TODO: interrupts

    if (db.children.peripherals.get(device_id)) |peripheral_set| {
        var list = std.ArrayList(EntityWithOffset).init(db.gpa);
        defer list.deinit();

        var it = peripheral_set.iterator();
        while (it.next()) |entry| {
            const peripheral_id = entry.key_ptr.*;
            const offset = db.attrs.offsets.get(peripheral_id) orelse return error.MissingPeripheralInstanceOffset;
            try list.append(.{ .id = peripheral_id, .offset = offset });
        }

        std.sort.sort(EntityWithOffset, list.items, {}, EntityWithOffset.lessThan);
        for (list.items) |periph|
            writePeripheralInstance(db, periph.id, periph.offset, writer) catch |err| {
                log.warn("failed to serialize peripheral instance: {}", .{err});
            };
    }

    try writer.writeAll("};\n");
    try out_writer.writeAll(buffer.items);
}

// generates a string for a type in the `types` namespace of the generated
// code. Since this is only used in code generation, just going to stuff it in
// the arena allocator
fn typesReference(db: Database, type_id: EntityId) ![]const u8 {
    // TODO: assert type_id is a type
    var full_name_components = std.ArrayList([]const u8).init(db.gpa);
    defer full_name_components.deinit();

    var id = type_id;
    while (true) {
        if (db.attrs.names.get(id)) |next_name|
            try full_name_components.insert(0, next_name)
        else
            return error.MissingTypeName;

        if (db.attrs.parents.get(id)) |parent_id|
            id = parent_id
        else
            break;
    }

    if (full_name_components.items.len == 0)
        return error.CantReference;

    var full_name = std.ArrayList(u8).init(db.arena.allocator());
    const writer = full_name.writer();
    try writer.writeAll("types");
    for (full_name_components.items) |component|
        try writer.print(".{s}", .{
            std.zig.fmtId(component),
        });

    return full_name.toOwnedSlice();
}

fn writePeripheralInstance(db: Database, peripheral_id: EntityId, offset: u64, out_writer: anytype) !void {
    assert(db.entityIs("instance.peripheral", peripheral_id));
    const name = db.attrs.names.get(peripheral_id) orelse return error.MissingPeripheralInstanceName;
    const type_id = db.instances.peripherals.get(peripheral_id).?;
    const type_ref = try typesReference(db, type_id);

    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    const writer = buffer.writer();
    if (db.attrs.descriptions.get(peripheral_id)) |description|
        try writer.print("\n/// {s}\n", .{description})
    else if (db.attrs.descriptions.get(type_id)) |description|
        try writer.print("\n/// {s}\n", .{description});

    try writer.print("pub const {s} = @ptrCast(*volatile {s}, 0x{x});\n", .{
        std.zig.fmtId(name),
        type_ref,
        offset,
    });

    try out_writer.writeAll(buffer.items);
}

fn writeTypes(db: Database, writer: anytype) !void {
    try writer.writeAll(
        \\
        \\pub const types = struct {
        \\
    );

    // TODO: order the peripherals alphabetically?
    var it = db.types.peripherals.iterator();
    while (it.next()) |entry| {
        const peripheral_id = entry.key_ptr.*;
        writePeripheral(db, peripheral_id, writer) catch |err| {
            log.warn("failed to generate peripheral '{s}': {}", .{
                db.attrs.names.get(peripheral_id) orelse "<unknown>",
                err,
            });
        };
    }

    try writer.writeAll("};\n");
}

// a peripheral is zero sized if it doesn't have any registers, and if none of
// its register groups have an offset
fn isPeripheralZeroSized(db: Database, peripheral_id: EntityId) bool {
    if (db.children.registers.contains(peripheral_id))
        return false;

    return if (db.children.register_groups.get(peripheral_id)) |register_group_set| blk: {
        var it = register_group_set.iterator();
        while (it.next()) |entry| {
            const register_group_id = entry.key_ptr.*;
            if (db.attrs.offsets.contains(register_group_id))
                break :blk false;
        }

        break :blk true;
    } else true;
}

fn writePeripheral(db: Database, peripheral_id: EntityId, out_writer: anytype) !void {
    assert(db.entityIs("type.peripheral", peripheral_id) or
        db.entityIs("type.register_group", peripheral_id));

    // unnamed peripherals are anonymously defined
    const name = db.attrs.names.get(peripheral_id) orelse return;

    // for now only serialize flat peripherals with no register groups
    // TODO: expand this
    if (db.children.register_groups.get(peripheral_id)) |register_group_set| {
        var it = register_group_set.iterator();
        while (it.next()) |entry| {
            if (db.attrs.offsets.contains(entry.key_ptr.*)) {
                log.warn("TODO: implement register groups with offset in peripheral type ({s})", .{name});
                return;
            }
        }
    }

    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    var registers = try getOrderedRegisterList(db, peripheral_id);
    defer registers.deinit();

    const writer = buffer.writer();

    try writer.writeByte('\n');
    if (db.attrs.descriptions.get(peripheral_id)) |description|
        try writer.print("/// {s}\n", .{description});

    const zero_sized = isPeripheralZeroSized(db, peripheral_id);
    const has_modes = db.children.modes.contains(peripheral_id);
    try writer.print(
        \\pub const {s} = {s} {s} {{
        \\
    , .{
        std.zig.fmtId(name),
        if (zero_sized) "" else "packed",
        if (has_modes) "union" else "struct",
    });

    var written = false;
    if (db.children.modes.get(peripheral_id)) |mode_set| {
        try writeNewlineIfWritten(writer, &written);
        try writeModeEnumAndFn(db, name, mode_set, writer);
    }

    if (db.children.enums.get(peripheral_id)) |enum_set|
        try writeEnums(db, &written, enum_set, writer);

    // namespaced registers
    if (db.children.register_groups.get(peripheral_id)) |register_group_set| {
        var it = register_group_set.iterator();
        while (it.next()) |entry| {
            const register_group_id = entry.key_ptr.*;

            // a register group with an offset means that it has a location within the peripheral
            if (db.attrs.offsets.contains(register_group_id))
                continue;

            try writeNewlineIfWritten(writer, &written);
            try writePeripheral(db, register_group_id, writer);
        }
    }

    try writeNewlineIfWritten(writer, &written);
    try writeRegisters(db, peripheral_id, writer);
    try writer.writeAll("};\n");

    try out_writer.writeAll(buffer.items);
}

fn writeNewlineIfWritten(writer: anytype, written: *bool) !void {
    if (written.*)
        try writer.writeByte('\n')
    else
        written.* = true;
}

fn writeEnums(db: Database, written: *bool, enum_set: EntitySet, writer: anytype) !void {
    var it = enum_set.iterator();
    while (it.next()) |entry| {
        const enum_id = entry.key_ptr.*;

        try writeNewlineIfWritten(writer, written);
        try writeEnum(db, enum_id, writer);
    }
}

fn writeEnum(db: Database, enum_id: EntityId, out_writer: anytype) !void {
    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    const writer = buffer.writer();
    const name = db.attrs.names.get(enum_id) orelse return;
    const size = db.attrs.sizes.get(enum_id) orelse return error.MissingEnumSize;

    // TODO: handle this instead of assert
    // assert(std.math.ceilPowerOfTwo(field_set.count()) <= size);

    if (db.attrs.descriptions.get(enum_id)) |description|
        try writer.print("/// {s}\n", .{description});

    try writer.print("pub const {s} = enum(u{}) {{\n", .{
        std.zig.fmtId(name),
        size,
    });
    try writeEnumFields(db, enum_id, writer);
    try writer.writeAll("};\n");

    try out_writer.writeAll(buffer.items);
}

fn writeEnumFields(db: Database, enum_id: u32, out_writer: anytype) !void {
    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    const writer = buffer.writer();
    const size = db.attrs.sizes.get(enum_id) orelse return error.MissingEnumSize;
    const field_set = db.children.enum_fields.get(enum_id) orelse return error.MissingEnumFields;
    var it = field_set.iterator();
    while (it.next()) |entry| {
        const enum_field_id = entry.key_ptr.*;
        try writeEnumField(db, enum_field_id, size, writer);
    }

    // if the enum doesn't completely fill the integer then make it a non-exhaustive enum
    if (field_set.count() < std.math.pow(u64, 2, size))
        try writer.writeAll("_,\n");

    try out_writer.writeAll(buffer.items);
}

fn writeEnumField(
    db: Database,
    enum_field_id: EntityId,
    size: u64,
    writer: anytype,
) !void {
    const name = db.attrs.names.get(enum_field_id) orelse return error.MissingEnumFieldName;
    const value = db.types.enum_fields.get(enum_field_id) orelse return error.MissingEnumFieldValue;

    // TODO: use size to print the hex value (pad with zeroes accordingly)
    _ = size;
    if (db.attrs.descriptions.get(enum_field_id)) |description|
        try writer.print("/// {s}\n", .{description});

    try writer.print("{s} = 0x{x},\n", .{ std.zig.fmtId(name), value });
}

fn writeModeEnumAndFn(
    db: Database,
    parent_name: []const u8,
    mode_set: EntitySet,
    out_writer: anytype,
) !void {
    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    const writer = buffer.writer();
    try writer.writeAll("pub const Mode = enum {\n");

    var it = mode_set.iterator();
    while (it.next()) |entry| {
        const mode_id = entry.key_ptr.*;
        const mode_name = db.attrs.names.get(mode_id) orelse unreachable;
        try writer.print("{s},\n", .{std.zig.fmtId(mode_name)});
    }

    try writer.writeAll("};\n");
    try writer.print("\npub fn getMode(self: *volatile {s}) Mode {{\n", .{
        parent_name,
    });

    it = mode_set.iterator();
    while (it.next()) |entry| {
        const mode_id = entry.key_ptr.*;
        const mode_name = db.attrs.names.get(mode_id) orelse unreachable;

        var components = std.ArrayList([]const u8).init(db.gpa);
        defer components.deinit();

        const mode = db.types.modes.get(mode_id).?;
        var tok_it = std.mem.tokenize(u8, mode.qualifier, ".");
        while (tok_it.next()) |token|
            try components.append(token);

        assert(std.mem.eql(u8, components.items[0], parent_name));
        const field_name = components.items[components.items.len - 1];
        _ = try db.getEntityIdByName("type.field", field_name);

        const access_path = try std.mem.join(db.arena.allocator(), ".", components.items[1 .. components.items.len - 1]);
        try writer.writeAll("{\n");
        try writer.print("const value = self.{s}.read().{s};\n", .{
            access_path,
            field_name,
        });
        try writer.writeAll("switch (value) {\n");

        tok_it = std.mem.tokenize(u8, mode.value, " ");
        while (tok_it.next()) |token| {
            const value = try std.fmt.parseInt(u64, token, 0);
            try writer.print("{},\n", .{value});
        }
        try writer.print("=> return .{s},\n", .{std.zig.fmtId(mode_name)});
        try writer.writeAll("else => {},\n");
        try writer.writeAll("}\n");
        try writer.writeAll("}\n");
    }

    try writer.writeAll("\nunreachable;\n");
    try writer.writeAll("}\n");

    try out_writer.writeAll(buffer.items);
}

fn writeRegisters(db: Database, parent_id: EntityId, out_writer: anytype) !void {
    var registers = try getOrderedRegisterList(db, parent_id);
    defer registers.deinit();

    if (db.children.modes.get(parent_id)) |modes|
        try writeRegistersWithModes(db, parent_id, modes, registers, out_writer)
    else
        try writeRegistersBase(db, parent_id, registers.items, out_writer);
}

fn writeRegistersWithModes(
    db: Database,
    parent_id: EntityId,
    mode_set: EntitySet,
    registers: std.ArrayList(EntityWithOffset),
    out_writer: anytype,
) !void {
    const allocator = db.arena.allocator();
    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    const writer = buffer.writer();
    var it = mode_set.iterator();
    while (it.next()) |entry| {
        const mode_id = entry.key_ptr.*;
        const mode_name = db.attrs.names.get(mode_id) orelse unreachable;

        // filter registers for this mode
        var moded_registers = std.ArrayList(EntityWithOffset).init(allocator);
        for (registers.items) |register| {
            if (db.attrs.modes.get(register.id)) |reg_mode_set| {
                var reg_mode_it = reg_mode_set.iterator();
                while (reg_mode_it.next()) |reg_mode_entry| {
                    const reg_mode_id = reg_mode_entry.key_ptr.*;
                    if (reg_mode_id == mode_id)
                        try moded_registers.append(register);
                }
                // if no mode is specified, then it should always be present
            } else try moded_registers.append(register);
        }

        try writer.print("{s}: packed struct {{\n", .{
            std.zig.fmtId(mode_name),
        });

        try writeRegistersBase(db, parent_id, moded_registers.items, writer);
        try writer.writeAll("},\n");
    }

    try out_writer.writeAll(buffer.items);
}

fn writeRegistersBase(
    db: Database,
    parent_id: EntityId,
    registers: []const EntityWithOffset,
    out_writer: anytype,
) !void {
    _ = parent_id;

    // registers _should_ be sorted when then make their way here
    assert(std.sort.isSorted(EntityWithOffset, registers, {}, EntityWithOffset.lessThan));
    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    const writer = buffer.writer();

    // don't have to care about modes
    // prioritize smaller fields that come earlier
    {
        var offset: u64 = 0;
        var i: u32 = 0;

        while (i < registers.len) {
            if (offset < registers[i].offset) {
                try writer.print("reserved{}: u{},\n", .{ registers[i].offset, registers[i].offset - offset });
                offset = registers[i].offset;
            } else if (offset > registers[i].offset) {
                if (db.attrs.names.get(registers[i].id)) |name|
                    log.warn("skipping register: {s}", .{name});

                i += 1;
                continue;
            }

            var end = i;
            while (end < registers.len and registers[end].offset == offset) : (end += 1) {}
            const next = blk: {
                var ret: ?EntityWithOffsetAndSize = null;
                for (registers[i..end]) |register| {
                    const size = db.attrs.sizes.get(register.id) orelse unreachable;
                    if (ret == null or (size < ret.?.size))
                        ret = .{
                            .id = register.id,
                            .offset = register.offset,
                            .size = size,
                        };
                }

                break :blk ret orelse unreachable;
            };

            try writeRegister(db, next.id, writer);
            // TODO: round up to next power of two
            assert(next.size % 8 == 0);
            offset += next.size / 8;
            i = end;
        }
    }

    try out_writer.writeAll(buffer.items);
}

fn writeRegister(
    db: Database,
    register_id: EntityId,
    out_writer: anytype,
) !void {
    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    const name = db.attrs.names.get(register_id) orelse unreachable;
    const size = db.attrs.sizes.get(register_id) orelse unreachable;

    const writer = buffer.writer();
    if (db.attrs.descriptions.get(register_id)) |description|
        try writer.print("/// {s}\n", .{description});

    if (db.children.fields.get(register_id)) |field_set| {
        var fields = std.ArrayList(EntityWithOffset).init(db.gpa);
        defer fields.deinit();

        var it = field_set.iterator();
        while (it.next()) |entry| {
            const field_id = entry.key_ptr.*;
            try fields.append(.{
                .id = field_id,
                .offset = db.attrs.offsets.get(field_id) orelse continue,
            });
        }

        std.sort.sort(EntityWithOffset, fields.items, {}, EntityWithOffset.lessThan);
        try writer.print("{s}: mmio.Mmio({}, packed struct{{\n", .{
            std.zig.fmtId(name),
            size,
        });

        try writeFields(db, fields.items, size, writer);
        try writer.writeAll("}),\n");
    } else try writer.print("{s}: u{},\n", .{ std.zig.fmtId(name), size });

    try out_writer.writeAll(buffer.items);
}

fn writeFields(
    db: Database,
    fields: []const EntityWithOffset,
    register_size: u64,
    out_writer: anytype,
) !void {
    assert(std.sort.isSorted(EntityWithOffset, fields, {}, EntityWithOffset.lessThan));
    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    // don't have to care about modes
    // prioritize smaller fields that come earlier
    const writer = buffer.writer();
    var offset: u64 = 0;
    var i: u32 = 0;
    while (i < fields.len and offset < register_size) {
        if (offset < fields[i].offset) {
            try writer.print("reserved{}: u{} = 0,\n", .{ fields[i].offset, fields[i].offset - offset });
            offset = fields[i].offset;
        } else if (offset > fields[i].offset) {
            if (db.attrs.names.get(fields[i].id)) |name|
                log.warn("skipping field: {s}, offset={}, field_offset={}", .{
                    name,
                    offset,
                    fields[i].offset,
                });

            i += 1;
            continue;
        }

        var end = i;
        while (end < fields.len and fields[end].offset == offset) : (end += 1) {}
        const next = blk: {
            var ret: ?EntityWithOffsetAndSize = null;
            for (fields[i..end]) |register| {
                const size = db.attrs.sizes.get(register.id) orelse unreachable;
                if (ret == null or (size < ret.?.size))
                    ret = .{
                        .id = register.id,
                        .offset = register.offset,
                        .size = size,
                    };
            }

            break :blk ret orelse unreachable;
        };

        const name = db.attrs.names.get(next.id) orelse unreachable;
        if (offset + next.size > register_size) {
            log.warn("register '{s}' is outside register boundaries: offset={}, size={}, register_size={}", .{
                name,
                next.offset,
                next.size,
                register_size,
            });
            break;
        }

        if (db.attrs.descriptions.get(next.id)) |description|
            try writer.print("/// {s}\n", .{description});

        if (db.attrs.enums.get(fields[i].id)) |enum_id| {
            if (db.attrs.names.get(enum_id)) |enum_name| {
                try writer.print(
                    \\{s}: packed union {{
                    \\    raw: u{},
                    \\    value: {s},
                    \\}},
                    \\
                , .{ name, next.size, std.zig.fmtId(enum_name) });
            } else {
                try writer.print(
                    \\{s}: packed union {{
                    \\    raw: u{},
                    \\    value: enum(u{}) {{
                    \\
                , .{ name, next.size, next.size });
                try writeEnumFields(db, enum_id, writer);
                try writer.writeAll("},\n},\n");
            }
        } else {
            try writer.print("{s}: u{},\n", .{ name, next.size });
        }

        offset += next.size;
        i = end;
    }

    assert(offset <= register_size);
    if (offset < register_size)
        try writer.print("padding: u{} = 0,\n", .{register_size - offset});

    try out_writer.writeAll(buffer.items);
}

fn getOrderedRegisterList(
    db: Database,
    parent_id: EntityId,
) !std.ArrayList(EntityWithOffset) {
    var registers = std.ArrayList(EntityWithOffset).init(db.gpa);
    errdefer registers.deinit();

    // get list of registers
    if (db.children.registers.get(parent_id)) |register_set| {
        var it = register_set.iterator();
        while (it.next()) |entry| {
            const register_id = entry.key_ptr.*;
            const offset = db.attrs.offsets.get(register_id) orelse continue;
            try registers.append(.{ .id = register_id, .offset = offset });
        }
    }

    std.sort.sort(EntityWithOffset, registers.items, {}, EntityWithOffset.lessThan);
    return registers;
}

// Test helpers
// ============
fn createRegister(db: *Database, name: []const u8, size: u64, offset: u64) !EntityId {
    const id = db.createEntity();
    try db.types.registers.put(db.gpa, id, {});
    try db.addName(id, name);
    try db.addOffset(id, offset);
    try db.addSize(id, size);

    return id;
}

fn createRegisterGroup(db: *Database, name: []const u8) !EntityId {
    const id = db.createEntity();
    try db.types.register_groups.put(db.gpa, id, {});
    try db.addName(id, name);

    return id;
}

fn createPeripheral(db: *Database, name: []const u8) !EntityId {
    const id = db.createEntity();
    try db.types.peripherals.put(db.gpa, id, {});
    try db.addName(id, name);

    return id;
}

fn createPeripheralInstance(
    db: *Database,
    name: []const u8,
    type_id: EntityId,
    offset: u64,
) !EntityId {
    const id = db.createEntity();
    try db.instances.peripherals.put(db.gpa, id, type_id);
    try db.addName(id, name);
    try db.addOffset(id, offset);

    return id;
}

fn createField(
    db: *Database,
    name: []const u8,
    size: u64,
    offset: u64,
) !EntityId {
    const id = db.createEntity();
    try db.types.fields.put(db.gpa, id, {});
    try db.addName(id, name);
    try db.addSize(id, size);
    try db.addOffset(id, offset);

    return id;
}

test "peripheral type with register and field" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const field_id = try createField(&db, "TEST_FIELD", 1, 0);

    const register_id = try createRegister(&db, "TEST_REGISTER", 32, 0);
    try db.addChild("type.field", register_id, field_id);

    const peripheral_id = try createPeripheral(&db, "TEST_PERIPHERAL");
    try db.addChild("type.register", peripheral_id, register_id);

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try db.toZig(buffer.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const types = struct {
        \\    pub const TEST_PERIPHERAL = packed struct {
        \\        TEST_REGISTER: mmio.Mmio(32, packed struct {
        \\            TEST_FIELD: u1,
        \\            padding: u31 = 0,
        \\        }),
        \\    };
        \\};
        \\
    , buffer.items);
}

test "peripheral instantiation" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const field_id = try createField(&db, "TEST_FIELD", 1, 0);

    const register_id = try createRegister(&db, "TEST_REGISTER", 32, 0);
    try db.addChild("type.field", register_id, field_id);

    const peripheral_id = try createPeripheral(&db, "TEST_PERIPHERAL");
    try db.addChild("type.register", peripheral_id, register_id);

    const instance_id = try createPeripheralInstance(&db, "TEST0", peripheral_id, 0x1000);

    const device_id = db.createEntity();
    try db.instances.devices.put(db.gpa, device_id, .{});
    try db.addName(device_id, "TEST_DEVICE");
    try db.addChild("instance.peripheral", device_id, instance_id);

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try db.toZig(buffer.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const devices = struct {
        \\    pub const TEST_DEVICE = struct {
        \\        pub const TEST0 = @ptrCast(*volatile types.TEST_PERIPHERAL, 0x1000);
        \\    };
        \\};
        \\
        \\pub const types = struct {
        \\    pub const TEST_PERIPHERAL = packed struct {
        \\        TEST_REGISTER: mmio.Mmio(32, packed struct {
        \\            TEST_FIELD: u1,
        \\            padding: u31 = 0,
        \\        }),
        \\    };
        \\};
        \\
    , buffer.items);
}

test "peripherals with a shared type" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const field_id = try createField(&db, "TEST_FIELD", 1, 0);

    const register_id = try createRegister(&db, "TEST_REGISTER", 32, 0);
    try db.addChild("type.field", register_id, field_id);

    const peripheral_id = try createPeripheral(&db, "TEST_PERIPHERAL");
    try db.addChild("type.register", peripheral_id, register_id);

    const instance0_id = try createPeripheralInstance(&db, "TEST0", peripheral_id, 0x1000);
    const instance1_id = try createPeripheralInstance(&db, "TEST1", peripheral_id, 0x2000);

    const device_id = db.createEntity();
    try db.instances.devices.put(db.gpa, device_id, .{});
    try db.addName(device_id, "TEST_DEVICE");
    try db.addChild("instance.peripheral", device_id, instance0_id);
    try db.addChild("instance.peripheral", device_id, instance1_id);

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try db.toZig(buffer.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const devices = struct {
        \\    pub const TEST_DEVICE = struct {
        \\        pub const TEST0 = @ptrCast(*volatile types.TEST_PERIPHERAL, 0x1000);
        \\        pub const TEST1 = @ptrCast(*volatile types.TEST_PERIPHERAL, 0x2000);
        \\    };
        \\};
        \\
        \\pub const types = struct {
        \\    pub const TEST_PERIPHERAL = packed struct {
        \\        TEST_REGISTER: mmio.Mmio(32, packed struct {
        \\            TEST_FIELD: u1,
        \\            padding: u31 = 0,
        \\        }),
        \\    };
        \\};
        \\
    , buffer.items);
}

test "peripheral with modes" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const mode1_id = db.createEntity();
    try db.addName(mode1_id, "TEST_MODE1");
    try db.types.modes.put(db.gpa, mode1_id, .{
        .value = "0x00",
        .qualifier = "TEST_PERIPHERAL.TEST_MODE1.COMMON_REGISTER.TEST_FIELD",
    });

    const mode2_id = db.createEntity();
    try db.addName(mode2_id, "TEST_MODE2");
    try db.types.modes.put(db.gpa, mode2_id, .{
        .value = "0x01",
        .qualifier = "TEST_PERIPHERAL.TEST_MODE2.COMMON_REGISTER.TEST_FIELD",
    });

    var register1_modeset = EntitySet{};
    try register1_modeset.put(db.gpa, mode1_id, {});

    var register2_modeset = EntitySet{};
    try register2_modeset.put(db.gpa, mode2_id, {});

    const register1_id = try createRegister(&db, "TEST_REGISTER1", 32, 0);
    try db.attrs.modes.put(db.gpa, register1_id, register1_modeset);

    const register2_id = try createRegister(&db, "TEST_REGISTER2", 32, 0);
    try db.attrs.modes.put(db.gpa, register2_id, register2_modeset);

    const field_id = try createField(&db, "TEST_FIELD", 1, 0);

    const common_reg_id = try createRegister(&db, "COMMON_REGISTER", 32, 4);
    try db.addChild("type.field", common_reg_id, field_id);

    const peripheral_id = try createPeripheral(&db, "TEST_PERIPHERAL");
    try db.addChild("type.register", peripheral_id, register1_id);
    try db.addChild("type.register", peripheral_id, register2_id);
    try db.addChild("type.register", peripheral_id, common_reg_id);
    try db.addChild("type.mode", peripheral_id, mode1_id);
    try db.addChild("type.mode", peripheral_id, mode2_id);

    // TODO: study the types of qualifiers that come up. it's possible that
    // we'll have to read different registers or read registers without fields.
    //
    // might also have registers with enum values
    // naive implementation goes through each mode and follows the qualifier,
    // next level will determine if they're reading the same address even if
    // different modes will use different union members

    try db.toZig(buffer.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const types = struct {
        \\    pub const TEST_PERIPHERAL = packed union {
        \\        pub const Mode = enum {
        \\            TEST_MODE1,
        \\            TEST_MODE2,
        \\        };
        \\
        \\        pub fn getMode(self: *volatile TEST_PERIPHERAL) Mode {
        \\            {
        \\                const value = self.TEST_MODE1.COMMON_REGISTER.read().TEST_FIELD;
        \\                switch (value) {
        \\                    0 => return .TEST_MODE1,
        \\                    else => {},
        \\                }
        \\            }
        \\            {
        \\                const value = self.TEST_MODE2.COMMON_REGISTER.read().TEST_FIELD;
        \\                switch (value) {
        \\                    1 => return .TEST_MODE2,
        \\                    else => {},
        \\                }
        \\            }
        \\
        \\            unreachable;
        \\        }
        \\
        \\        TEST_MODE1: packed struct {
        \\            TEST_REGISTER1: u32,
        \\            COMMON_REGISTER: mmio.Mmio(32, packed struct {
        \\                TEST_FIELD: u1,
        \\                padding: u31 = 0,
        \\            }),
        \\        },
        \\        TEST_MODE2: packed struct {
        \\            TEST_REGISTER2: u32,
        \\            COMMON_REGISTER: mmio.Mmio(32, packed struct {
        \\                TEST_FIELD: u1,
        \\                padding: u31 = 0,
        \\            }),
        \\        },
        \\    };
        \\};
        \\
    , buffer.items);
}

test "peripheral with enum" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const enum_field1_id = db.createEntity();
    try db.types.enum_fields.put(db.gpa, enum_field1_id, 0);
    try db.addName(enum_field1_id, "TEST_ENUM_FIELD1");

    const enum_field2_id = db.createEntity();
    try db.types.enum_fields.put(db.gpa, enum_field2_id, 1);
    try db.addName(enum_field2_id, "TEST_ENUM_FIELD2");

    const enum_id = db.createEntity();
    try db.types.enums.put(db.gpa, enum_id, {});
    try db.addName(enum_id, "TEST_ENUM");
    try db.addSize(enum_id, 4);
    try db.addChild("type.enum_field", enum_id, enum_field1_id);
    try db.addChild("type.enum_field", enum_id, enum_field2_id);

    const register_id = try createRegister(&db, "TEST_REGISTER", 8, 0);

    const peripheral_id = try createPeripheral(&db, "TEST_PERIPHERAL");
    try db.addChild("type.enum", peripheral_id, enum_id);
    try db.addChild("type.register", peripheral_id, register_id);

    try db.toZig(buffer.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const types = struct {
        \\    pub const TEST_PERIPHERAL = packed struct {
        \\        pub const TEST_ENUM = enum(u4) {
        \\            TEST_ENUM_FIELD1 = 0x0,
        \\            TEST_ENUM_FIELD2 = 0x1,
        \\            _,
        \\        };
        \\
        \\        TEST_REGISTER: u8,
        \\    };
        \\};
        \\
    , buffer.items);
}

test "peripheral with enum, enum is exhausted of values" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const enum_field1_id = db.createEntity();
    try db.types.enum_fields.put(db.gpa, enum_field1_id, 0);
    try db.addName(enum_field1_id, "TEST_ENUM_FIELD1");

    const enum_field2_id = db.createEntity();
    try db.types.enum_fields.put(db.gpa, enum_field2_id, 1);
    try db.addName(enum_field2_id, "TEST_ENUM_FIELD2");

    const enum_id = db.createEntity();
    try db.types.enums.put(db.gpa, enum_id, {});
    try db.addName(enum_id, "TEST_ENUM");
    try db.addSize(enum_id, 1);
    try db.addChild("type.enum_field", enum_id, enum_field1_id);
    try db.addChild("type.enum_field", enum_id, enum_field2_id);

    const register_id = try createRegister(&db, "TEST_REGISTER", 8, 0);

    const peripheral_id = try createPeripheral(&db, "TEST_PERIPHERAL");
    try db.addChild("type.enum", peripheral_id, enum_id);
    try db.addChild("type.register", peripheral_id, register_id);

    try db.toZig(buffer.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const types = struct {
        \\    pub const TEST_PERIPHERAL = packed struct {
        \\        pub const TEST_ENUM = enum(u1) {
        \\            TEST_ENUM_FIELD1 = 0x0,
        \\            TEST_ENUM_FIELD2 = 0x1,
        \\        };
        \\
        \\        TEST_REGISTER: u8,
        \\    };
        \\};
        \\
    , buffer.items);
}

test "field with named enum" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const enum_field1_id = db.createEntity();
    try db.types.enum_fields.put(db.gpa, enum_field1_id, 0);
    try db.addName(enum_field1_id, "TEST_ENUM_FIELD1");

    const enum_field2_id = db.createEntity();
    try db.types.enum_fields.put(db.gpa, enum_field2_id, 1);
    try db.addName(enum_field2_id, "TEST_ENUM_FIELD2");

    const enum_id = db.createEntity();
    try db.types.enums.put(db.gpa, enum_id, {});
    try db.addName(enum_id, "TEST_ENUM");
    try db.addSize(enum_id, 4);
    try db.addChild("type.enum_field", enum_id, enum_field1_id);
    try db.addChild("type.enum_field", enum_id, enum_field2_id);

    const field_id = try createField(&db, "TEST_FIELD", 4, 0);
    try db.attrs.enums.put(db.gpa, field_id, enum_id);

    const register_id = try createRegister(&db, "TEST_REGISTER", 8, 0);
    try db.addChild("type.field", register_id, field_id);

    const peripheral_id = try createPeripheral(&db, "TEST_PERIPHERAL");
    try db.addChild("type.enum", peripheral_id, enum_id);
    try db.addChild("type.register", peripheral_id, register_id);

    try db.toZig(buffer.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const types = struct {
        \\    pub const TEST_PERIPHERAL = packed struct {
        \\        pub const TEST_ENUM = enum(u4) {
        \\            TEST_ENUM_FIELD1 = 0x0,
        \\            TEST_ENUM_FIELD2 = 0x1,
        \\            _,
        \\        };
        \\
        \\        TEST_REGISTER: mmio.Mmio(8, packed struct {
        \\            TEST_FIELD: packed union {
        \\                raw: u4,
        \\                value: TEST_ENUM,
        \\            },
        \\            padding: u4 = 0,
        \\        }),
        \\    };
        \\};
        \\
    , buffer.items);
}

test "field with anonymous enum" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const enum_field1_id = db.createEntity();
    try db.types.enum_fields.put(db.gpa, enum_field1_id, 0);
    try db.addName(enum_field1_id, "TEST_ENUM_FIELD1");

    const enum_field2_id = db.createEntity();
    try db.types.enum_fields.put(db.gpa, enum_field2_id, 1);
    try db.addName(enum_field2_id, "TEST_ENUM_FIELD2");

    const enum_id = db.createEntity();
    try db.types.enums.put(db.gpa, enum_id, {});
    try db.addSize(enum_id, 4);
    try db.addChild("type.enum_field", enum_id, enum_field1_id);
    try db.addChild("type.enum_field", enum_id, enum_field2_id);

    const field_id = try createField(&db, "TEST_FIELD", 4, 0);
    try db.attrs.enums.put(db.gpa, field_id, enum_id);

    const register_id = try createRegister(&db, "TEST_REGISTER", 8, 0);
    try db.addChild("type.field", register_id, field_id);

    const peripheral_id = try createPeripheral(&db, "TEST_PERIPHERAL");
    try db.addChild("type.enum", peripheral_id, enum_id);
    try db.addChild("type.register", peripheral_id, register_id);

    try db.toZig(buffer.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const types = struct {
        \\    pub const TEST_PERIPHERAL = packed struct {
        \\        TEST_REGISTER: mmio.Mmio(8, packed struct {
        \\            TEST_FIELD: packed union {
        \\                raw: u4,
        \\                value: enum(u4) {
        \\                    TEST_ENUM_FIELD1 = 0x0,
        \\                    TEST_ENUM_FIELD2 = 0x1,
        \\                    _,
        \\                },
        \\            },
        \\            padding: u4 = 0,
        \\        }),
        \\    };
        \\};
        \\
    , buffer.items);
}

test "namespaced register groups" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    // registers
    const portb_id = try createRegister(&db, "PORTB", 8, 0);
    const ddrb_id = try createRegister(&db, "DDRB", 8, 1);
    const pinb_id = try createRegister(&db, "PINB", 8, 2);

    const portc_id = try createRegister(&db, "PORTC", 8, 0);
    const ddrc_id = try createRegister(&db, "DDRC", 8, 1);
    const pinc_id = try createRegister(&db, "PINC", 8, 2);

    // register_groups
    const portb_group_id = try createRegisterGroup(&db, "PORTB");
    try db.addChild("type.register", portb_group_id, portb_id);
    try db.addChild("type.register", portb_group_id, ddrb_id);
    try db.addChild("type.register", portb_group_id, pinb_id);

    const portc_group_id = try createRegisterGroup(&db, "PORTC");
    try db.addChild("type.register", portc_group_id, portc_id);
    try db.addChild("type.register", portc_group_id, ddrc_id);
    try db.addChild("type.register", portc_group_id, pinc_id);

    // peripheral
    const peripheral_id = try createPeripheral(&db, "PORT");
    try db.addChild("type.register_group", peripheral_id, portb_group_id);
    try db.addChild("type.register_group", peripheral_id, portc_group_id);

    // instances
    const portb_instance_id = try createPeripheralInstance(&db, "PORTB", portb_group_id, 0x23);
    const portc_instance_id = try createPeripheralInstance(&db, "PORTC", portc_group_id, 0x26);

    // device
    const device_id = db.createEntity();
    try db.instances.devices.put(db.gpa, device_id, .{});
    try db.addName(device_id, "ATmega328P");
    try db.addChild("instance.peripheral", device_id, portb_instance_id);
    try db.addChild("instance.peripheral", device_id, portc_instance_id);

    try db.toZig(buffer.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const devices = struct {
        \\    pub const ATmega328P = struct {
        \\        pub const PORTB = @ptrCast(*volatile types.PORT.PORTB, 0x23);
        \\        pub const PORTC = @ptrCast(*volatile types.PORT.PORTC, 0x26);
        \\    };
        \\};
        \\
        \\pub const types = struct {
        \\    pub const PORT = struct {
        \\        pub const PORTB = packed struct {
        \\            PORTB: u8,
        \\            DDRB: u8,
        \\            PINB: u8,
        \\        };
        \\
        \\        pub const PORTC = packed struct {
        \\            PORTC: u8,
        \\            DDRC: u8,
        \\            PINC: u8,
        \\        };
        \\    };
        \\};
        \\
    , buffer.items);
}

// TODO:
// - write some tests regarding register scoped modes, and what fields look like
//   when they have a peripheral/register_group scoped mode
// - default values should be reset value, otherwise 0
//

// more test ideas:
// - interrupts
// - anonymous peripherals
// - multiple register groups
// - access
// - modes
// - repeated
// - ordered address printing
// - enums
// - modes with discontiguous bits
//
