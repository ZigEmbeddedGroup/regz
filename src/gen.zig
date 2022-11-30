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

    // format the generated code
    var ast = try std.zig.parse(db.gpa, @ptrCast([:0]const u8, buffer.items));
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

fn writePeripheralInstance(db: Database, peripheral_id: EntityId, offset: u64, out_writer: anytype) !void {
    assert(db.entityIs("instance.peripheral", peripheral_id));
    const name = db.attrs.names.get(peripheral_id) orelse return error.MissingPeripheralInstanceName;
    const type_name = if (db.instances.peripherals.get(peripheral_id)) |type_id|
        if (db.attrs.names.get(type_id)) |type_name|
            type_name
        else
            return error.MissingPeripheralInstanceType
    else
        return error.MissingPeripheralInstanceType;

    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    const writer = buffer.writer();
    if (db.attrs.descriptions.get(peripheral_id)) |description|
        try writer.print("\n/// {s}\n", .{description});

    try writer.print("pub const {s} = @ptrCast(*volatile types.{s}, 0x{x});\n", .{
        std.zig.fmtId(name),
        std.zig.fmtId(type_name),
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

        try writePeripheral(db, peripheral_id, writer);
    }

    try writer.writeAll("};\n");
}

fn writePeripheral(db: Database, peripheral_id: EntityId, out_writer: anytype) !void {
    assert(db.entityIs("type.peripheral", peripheral_id));

    // unnamed peripherals are anonymously defined
    const name = db.attrs.names.get(peripheral_id) orelse return;

    // for now only serialize flat peripherals with no register groups
    // TODO: expand this
    if (db.children.register_groups.contains(peripheral_id)) {
        log.warn("TODO: implement register groups in peripheral type ({s})", .{name});
        return;
    }

    if (db.children.modes.contains(peripheral_id))
        try writePeripheralWithModes(db, peripheral_id, name, out_writer)
    else
        try writePeripheralNoModes(db, peripheral_id, name, out_writer);
}

fn writePeripheralNoModes(
    db: Database,
    peripheral_id: EntityId,
    name: []const u8,
    out_writer: anytype,
) !void {
    log.debug("writePeripheralNoModes()", .{});

    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    var registers = try getOrderedRegisterList(db, peripheral_id);
    defer registers.deinit();

    const writer = buffer.writer();
    try writer.writeByte('\n');
    if (db.attrs.descriptions.get(peripheral_id)) |description|
        try writer.print("/// {s}\n", .{description});

    try writer.print(
        \\pub const {s} = packed struct {{
        \\
    , .{std.zig.fmtId(name)});

    try writeRegisters(db, peripheral_id, registers.items, writer);
    try writer.writeAll("};\n");

    try out_writer.writeAll(buffer.items);
}

fn writePeripheralWithModes(
    db: Database,
    peripheral_id: EntityId,
    name: []const u8,
    out_writer: anytype,
) !void {
    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    assert(db.children.modes.contains(peripheral_id));
    var registers = try getOrderedRegisterList(db, peripheral_id);
    defer registers.deinit();

    var modes = std.AutoArrayHashMap(EntityId, EntitySet).init(db.gpa);
    defer modes.deinit();

    const mode_set = db.children.modes.get(peripheral_id) orelse unreachable;
    var it = mode_set.iterator();
    while (it.next()) |entry| {
        const mode_id = entry.key_ptr.*;
        try modes.putNoClobber(mode_id, .{});
    }

    const writer = buffer.writer();
    try writer.writeByte('\n');
    if (db.attrs.descriptions.get(peripheral_id)) |description|
        try writer.print("/// {s}\n", .{description});

    try writer.print("pub const {s} = packed union {{\n", .{std.zig.fmtId(name)});
    try writeModeEnumAndFn(db, name, mode_set, writer);
    try writer.writeByte('\n');
    try writeRegistersWithModes(db, peripheral_id, mode_set, registers, writer);
    try writer.writeAll("};\n");

    try out_writer.writeAll(buffer.items);
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
                    if (reg_mode_id == mode_id) {
                        try moded_registers.append(register);
                        const register_name = db.attrs.names.get(register.id).?;
                        log.debug("{s} has register {s}", .{ mode_name, register_name });
                    }
                }
                // if no mode is specified, then it should always be present
            } else {
                try moded_registers.append(register);
                const register_name = db.attrs.names.get(register.id).?;
                log.debug("{s} has register {s}", .{ mode_name, register_name });
            }
        }

        try writer.print("{s}: packed struct {{\n", .{
            std.zig.fmtId(mode_name),
        });

        try writeRegisters(db, parent_id, moded_registers.items, writer);
        try writer.writeAll("},\n");
    }

    try out_writer.writeAll(buffer.items);
}

fn writeRegisters(
    db: Database,
    parent_id: EntityId,
    registers: []const EntityWithOffset,
    out_writer: anytype,
) !void {
    log.debug("writeRegisters()", .{});
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
                try writer.print("reserved{}: u{},\n", .{ registers[i].offset, (registers[i].offset - offset) * 8 });
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
            // TODO: probably round up to the next power of 8
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
        try writer.print("{s}: mmio.Mmio(packed struct{{\n", .{
            std.zig.fmtId(name),
        });

        log.debug("register name is {s}", .{name});
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
    log.debug("writeFields()", .{});
    assert(std.sort.isSorted(EntityWithOffset, fields, {}, EntityWithOffset.lessThan));
    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    std.log.debug("fields: {any}", .{fields});

    // don't have to care about modes
    // prioritize smaller fields that come earlier
    const writer = buffer.writer();
    var offset: u64 = 0;
    var i: u32 = 0;
    while (i < fields.len and offset < register_size) {
        log.debug("offset={}, field_offset={}", .{ offset, fields[i].offset });
        if (offset < fields[i].offset) {
            log.debug("reserved field size: {}", .{
                fields[i].offset - offset,
            });
            try writer.print("reserved{}: u{},\n", .{ fields[i].offset, fields[i].offset - offset });
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
        log.debug("field is {s}", .{name});
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

        // TODO: check for enum
        try writer.print("{s}: u{},\n", .{ name, next.size });
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
    } else {
        log.warn("{}: has no registers", .{parent_id});
        return error.NoRegisters;
    }

    std.sort.sort(EntityWithOffset, registers.items, {}, EntityWithOffset.lessThan);
    return registers;
}

test "peripheral type with register and field" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const field_id = db.createEntity();
    try db.types.fields.put(db.gpa, field_id, {});
    try db.addName(field_id, "TEST_FIELD");
    try db.addSize(field_id, 1);
    try db.addOffset(field_id, 0);

    const register_id = db.createEntity();
    try db.types.registers.put(db.gpa, register_id, {});
    try db.addName(register_id, "TEST_REGISTER");
    try db.addOffset(register_id, 0);
    try db.addSize(register_id, 32);
    try db.addChild("type.field", register_id, field_id);

    const peripheral_id = db.createEntity();
    try db.types.peripherals.put(db.gpa, peripheral_id, {});
    try db.addName(peripheral_id, "TEST_PERIPHERAL");
    try db.addChild("type.register", peripheral_id, register_id);

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try db.toZig(buffer.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const types = struct {
        \\    pub const TEST_PERIPHERAL = packed struct {
        \\        TEST_REGISTER: mmio.Mmio(packed struct {
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

    const field_id = db.createEntity();
    try db.types.fields.put(db.gpa, field_id, {});
    try db.addName(field_id, "TEST_FIELD");
    try db.addOffset(field_id, 0);
    try db.addSize(field_id, 1);

    const register_id = db.createEntity();
    try db.types.registers.put(db.gpa, register_id, {});
    try db.addName(register_id, "TEST_REGISTER");
    try db.addOffset(register_id, 0);
    try db.addSize(register_id, 32);
    try db.addChild("type.field", register_id, field_id);

    const peripheral_id = db.createEntity();
    try db.types.peripherals.put(db.gpa, peripheral_id, {});
    try db.addName(peripheral_id, "TEST_PERIPHERAL");
    try db.addChild("type.register", peripheral_id, register_id);

    const instance_id = db.createEntity();
    try db.instances.peripherals.put(db.gpa, instance_id, peripheral_id);
    try db.addName(instance_id, "TEST0");
    try db.addOffset(instance_id, 0x1000);

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
        \\        TEST_REGISTER: mmio.Mmio(packed struct {
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

    const field_id = db.createEntity();
    try db.types.fields.put(db.gpa, field_id, {});
    try db.addName(field_id, "TEST_FIELD");
    try db.addSize(field_id, 1);
    try db.addOffset(field_id, 0);

    const register_id = db.createEntity();
    try db.types.registers.put(db.gpa, register_id, {});
    try db.addName(register_id, "TEST_REGISTER");
    try db.addOffset(register_id, 0);
    try db.addSize(register_id, 32);
    try db.addChild("type.field", register_id, field_id);

    const peripheral_id = db.createEntity();
    try db.types.peripherals.put(db.gpa, peripheral_id, {});
    try db.addName(peripheral_id, "TEST_PERIPHERAL");
    try db.addChild("type.register", peripheral_id, register_id);

    const instance0_id = db.createEntity();
    try db.instances.peripherals.put(db.gpa, instance0_id, peripheral_id);
    try db.addName(instance0_id, "TEST0");
    try db.addOffset(instance0_id, 0x1000);

    const instance1_id = db.createEntity();
    try db.instances.peripherals.put(db.gpa, instance1_id, peripheral_id);
    try db.addName(instance1_id, "TEST1");
    try db.addOffset(instance1_id, 0x2000);

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
        \\        TEST_REGISTER: mmio.Mmio(packed struct {
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

    const field_id = db.createEntity();
    try db.types.fields.put(db.gpa, field_id, {});
    try db.addName(field_id, "TEST_FIELD");
    try db.addOffset(field_id, 0);
    try db.addSize(field_id, 1);

    var register1_modeset = EntitySet{};
    try register1_modeset.put(db.gpa, mode1_id, {});

    var register2_modeset = EntitySet{};
    try register2_modeset.put(db.gpa, mode2_id, {});

    const register1_id = db.createEntity();
    try db.types.registers.put(db.gpa, register1_id, {});
    try db.addName(register1_id, "TEST_REGISTER1");
    try db.addOffset(register1_id, 0);
    try db.addSize(register1_id, 32);
    try db.attrs.modes.put(db.gpa, register1_id, register1_modeset);

    const register2_id = db.createEntity();
    try db.types.registers.put(db.gpa, register2_id, {});
    try db.addName(register2_id, "TEST_REGISTER2");
    try db.addOffset(register2_id, 0);
    try db.addSize(register2_id, 32);
    try db.attrs.modes.put(db.gpa, register2_id, register2_modeset);

    const common_reg_id = db.createEntity();
    try db.types.registers.put(db.gpa, common_reg_id, {});
    try db.addName(common_reg_id, "COMMON_REGISTER");
    try db.addOffset(common_reg_id, 4);
    try db.addSize(common_reg_id, 32);
    try db.addChild("type.field", common_reg_id, field_id);

    const peripheral_id = db.createEntity();
    try db.types.peripherals.put(db.gpa, peripheral_id, {});
    try db.addName(peripheral_id, "TEST_PERIPHERAL");
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
        \\            COMMON_REGISTER: mmio.Mmio(packed struct {
        \\                TEST_FIELD: u1,
        \\                padding: u31 = 0,
        \\            }),
        \\        },
        \\        TEST_MODE2: packed struct {
        \\            TEST_REGISTER2: u32,
        \\            COMMON_REGISTER: mmio.Mmio(packed struct {
        \\                TEST_FIELD: u1,
        \\                padding: u31 = 0,
        \\            }),
        \\        },
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
