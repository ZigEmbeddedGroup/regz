//! Code generation and associated tests
const std = @import("std");
const Allocator = std.mem.Allocator;
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

fn writeComment(allocator: Allocator, comment: []const u8, writer: anytype) !void {
    var tokenized = std.ArrayList(u8).init(allocator);
    defer tokenized.deinit();

    var first = true;
    var tok_it = std.mem.tokenize(u8, comment, "\n\r \t");
    while (tok_it.next()) |token| {
        if (!first)
            first = false
        else
            try tokenized.writer().writeByte(' ');

        try tokenized.writer().writeAll(token);
    }

    const unescaped = try std.mem.replaceOwned(u8, allocator, tokenized.items, "\\n", "\n");
    defer allocator.free(unescaped);

    var line_it = std.mem.tokenize(u8, unescaped, "\n");
    while (line_it.next()) |line|
        try writer.print("/// {s}\n", .{line});
}

fn writeString(str: []const u8, writer: anytype) !void {
    if (std.mem.containsAtLeast(u8, str, 1, "\n")) {
        try writer.writeByte('\n');
        var line_it = std.mem.split(u8, str, "\n");
        while (line_it.next()) |line|
            try writer.print("\\\\{s}\n", .{line});
    } else {
        try writer.print("\"{s}\"", .{str});
    }
}

fn writeDevice(db: Database, device_id: EntityId, out_writer: anytype) !void {
    assert(db.entityIs("instance.device", device_id));
    const name = db.attrs.name.get(device_id) orelse return error.MissingDeviceName;

    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    const writer = buffer.writer();
    // TODO: multiline?
    if (db.attrs.description.get(device_id)) |description|
        try writeComment(db.arena.allocator(), description, writer);

    try writer.print(
        \\pub const {s} = struct {{
        \\
    , .{std.zig.fmtId(name)});

    // TODO: alphabetic order
    const properties = db.instances.devices.get(device_id).?.properties;
    {
        var it = properties.iterator();
        while (it.next()) |entry| {
            try writer.print("pub const {s} = ", .{
                std.zig.fmtId(entry.key_ptr.*),
            });

            try writeString(entry.value_ptr.*, writer);
            try writer.writeAll(";\n");
        }

        try writer.writeByte('\n');
    }

    // TODO: interrupts

    if (db.children.peripherals.get(device_id)) |peripheral_set| {
        var list = std.ArrayList(EntityWithOffset).init(db.gpa);
        defer list.deinit();

        var it = peripheral_set.iterator();
        while (it.next()) |entry| {
            const peripheral_id = entry.key_ptr.*;
            const offset = db.attrs.offset.get(peripheral_id) orelse return error.MissingPeripheralInstanceOffset;
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
        if (db.attrs.name.get(id)) |next_name|
            try full_name_components.insert(0, next_name)
        else
            return error.MissingTypeName;

        if (db.attrs.parent.get(id)) |parent_id|
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

fn writePeripheralInstance(db: Database, instance_id: EntityId, offset: u64, out_writer: anytype) !void {
    assert(db.entityIs("instance.peripheral", instance_id));
    var buffer = std.ArrayList(u8).init(db.arena.allocator());
    defer buffer.deinit();

    const writer = buffer.writer();
    const name = db.attrs.name.get(instance_id) orelse return error.MissingPeripheralInstanceName;
    const type_id = db.instances.peripherals.get(instance_id).?;
    if (db.attrs.name.contains(type_id)) {
        const type_ref = try typesReference(db, type_id);

        if (db.attrs.description.get(instance_id)) |description|
            try writeComment(db.arena.allocator(), description, writer)
        else if (db.attrs.description.get(type_id)) |description|
            try writeComment(db.arena.allocator(), description, writer);

        try writer.print("pub const {s} = @ptrCast(*volatile {s}, 0x{x});\n", .{
            std.zig.fmtId(name),
            type_ref,
            offset,
        });
    } else {
        try writer.print("pub const {s} = @ptrCast(*volatile ", .{
            std.zig.fmtId(name),
        });

        try writePeripheralBody(db, type_id, writer);

        try writer.print(", 0x{x});\n", .{
            offset,
        });
    }

    try out_writer.writeAll(buffer.items);
}

// Top level types are any types without a parent. In order for them to be
// rendered in the `types` namespace they need a name
fn hasTopLevelNamedTypes(db: Database) bool {
    inline for (@typeInfo(@TypeOf(db.types)).Struct.fields) |field| {
        var it = @field(db.types, field.name).iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            if (!db.attrs.parent.contains(id) and
                db.attrs.name.contains(id))
            {
                return true;
            }
        }
    }

    return false;
}

fn writeTypes(db: Database, writer: anytype) !void {
    if (!hasTopLevelNamedTypes(db))
        return;

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
                db.attrs.name.get(peripheral_id) orelse "<unknown>",
                err,
            });
        };
    }

    try writer.writeAll("};\n");
}

// a peripheral is zero sized if it doesn't have any registers, and if none of
// its register groups have an offset
fn isPeripheralZeroSized(db: Database, peripheral_id: EntityId) bool {
    if (db.children.registers.contains(peripheral_id)) {
        return false;
    } else {
        log.debug("no registers found", .{});
    }

    return if (db.children.register_groups.get(peripheral_id)) |register_group_set| blk: {
        var it = register_group_set.iterator();
        while (it.next()) |entry| {
            const register_group_id = entry.key_ptr.*;
            if (db.attrs.offset.contains(register_group_id))
                break :blk false;
        }

        break :blk true;
    } else true;
}

// have to fill this in manually when new errors are introduced. This is because writePeripheral is recursive via writePeripheralBase
const ErrorWritePeripheralBase = error{
    OutOfMemory,
    InvalidCharacter,
    Overflow,
    NameNotFound,
    MissingEnumSize,
    MissingEnumFields,
    MissingEnumFieldName,
    MissingEnumFieldValue,
};

fn WritePeripheralError(comptime Writer: type) type {
    return ErrorWritePeripheralBase || Writer.Error;
}

fn writePeripheral(
    db: Database,
    peripheral_id: EntityId,
    out_writer: anytype,
) WritePeripheralError(@TypeOf(out_writer))!void {
    assert(db.entityIs("type.peripheral", peripheral_id) or
        db.entityIs("type.register_group", peripheral_id));

    // unnamed peripherals are anonymously defined
    const name = db.attrs.name.get(peripheral_id) orelse return;

    // for now only serialize flat peripherals with no register groups
    // TODO: expand this
    if (db.children.register_groups.get(peripheral_id)) |register_group_set| {
        var it = register_group_set.iterator();
        while (it.next()) |entry| {
            if (db.attrs.offset.contains(entry.key_ptr.*)) {
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
    if (db.attrs.description.get(peripheral_id)) |description|
        try writeComment(db.arena.allocator(), description, writer);

    try writer.print("pub const {s} = ", .{std.zig.fmtId(name)});
    try writePeripheralBody(db, peripheral_id, writer);
    try writer.writeAll(";\n");

    try out_writer.writeAll(buffer.items);
}

fn writePeripheralBody(
    db: Database,
    peripheral_id: EntityId,
    writer: anytype,
) WritePeripheralError(@TypeOf(writer))!void {
    const zero_sized = isPeripheralZeroSized(db, peripheral_id);
    const has_modes = db.children.modes.contains(peripheral_id);
    try writer.print(
        \\{s} {s} {{
        \\
    , .{
        if (zero_sized) "" else "packed",
        if (has_modes) "union" else "struct",
    });

    var written = false;
    if (db.children.modes.get(peripheral_id)) |mode_set| {
        try writeNewlineIfWritten(writer, &written);
        try writeModeEnumAndFn(db, mode_set, writer);
    }

    if (db.children.enums.get(peripheral_id)) |enum_set|
        try writeEnums(db, &written, enum_set, writer);

    // namespaced registers
    if (db.children.register_groups.get(peripheral_id)) |register_group_set| {
        var it = register_group_set.iterator();
        while (it.next()) |entry| {
            const register_group_id = entry.key_ptr.*;

            // a register group with an offset means that it has a location within the peripheral
            if (db.attrs.offset.contains(register_group_id))
                continue;

            try writeNewlineIfWritten(writer, &written);
            try writePeripheral(db, register_group_id, writer);
        }
    }

    try writeNewlineIfWritten(writer, &written);
    try writeRegisters(db, peripheral_id, writer);

    try writer.writeAll("\n}");
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
    const name = db.attrs.name.get(enum_id) orelse return;
    const size = db.attrs.size.get(enum_id) orelse return error.MissingEnumSize;

    // TODO: handle this instead of assert
    // assert(std.math.ceilPowerOfTwo(field_set.count()) <= size);

    if (db.attrs.description.get(enum_id)) |description|
        try writeComment(db.arena.allocator(), description, writer);

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
    const size = db.attrs.size.get(enum_id) orelse return error.MissingEnumSize;
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
    const name = db.attrs.name.get(enum_field_id) orelse return error.MissingEnumFieldName;
    const value = db.types.enum_fields.get(enum_field_id) orelse return error.MissingEnumFieldValue;

    // TODO: use size to print the hex value (pad with zeroes accordingly)
    _ = size;
    if (db.attrs.description.get(enum_field_id)) |description|
        try writeComment(db.arena.allocator(), description, writer);

    try writer.print("{s} = 0x{x},\n", .{ std.zig.fmtId(name), value });
}

fn writeModeEnumAndFn(
    db: Database,
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
        const mode_name = db.attrs.name.get(mode_id) orelse unreachable;
        try writer.print("{s},\n", .{std.zig.fmtId(mode_name)});
    }

    try writer.writeAll(
        \\};
        \\
        \\pub fn getMode(self: *volatile @This()) Mode {
        \\
    );

    it = mode_set.iterator();
    while (it.next()) |entry| {
        const mode_id = entry.key_ptr.*;
        const mode_name = db.attrs.name.get(mode_id) orelse unreachable;

        var components = std.ArrayList([]const u8).init(db.gpa);
        defer components.deinit();

        const mode = db.types.modes.get(mode_id).?;
        var tok_it = std.mem.tokenize(u8, mode.qualifier, ".");
        while (tok_it.next()) |token|
            try components.append(token);

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
        const mode_name = db.attrs.name.get(mode_id) orelse unreachable;

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
                try writer.print("reserved{}: [{}]u8,\n", .{ registers[i].offset, registers[i].offset - offset });
                offset = registers[i].offset;
            } else if (offset > registers[i].offset) {
                if (db.attrs.name.get(registers[i].id)) |name|
                    log.warn("skipping register: {s}", .{name});

                i += 1;
                continue;
            }

            var end = i;
            while (end < registers.len and registers[end].offset == offset) : (end += 1) {}
            const next = blk: {
                var ret: ?EntityWithOffsetAndSize = null;
                for (registers[i..end]) |register| {
                    const size = db.attrs.size.get(register.id) orelse unreachable;
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

    const name = db.attrs.name.get(register_id) orelse unreachable;
    const size = db.attrs.size.get(register_id) orelse unreachable;

    const writer = buffer.writer();
    if (db.attrs.description.get(register_id)) |description|
        try writeComment(db.arena.allocator(), description, writer);

    if (db.children.fields.get(register_id)) |field_set| {
        var fields = std.ArrayList(EntityWithOffset).init(db.gpa);
        defer fields.deinit();

        var it = field_set.iterator();
        while (it.next()) |entry| {
            const field_id = entry.key_ptr.*;
            try fields.append(.{
                .id = field_id,
                .offset = db.attrs.offset.get(field_id) orelse continue,
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
            if (db.attrs.name.get(fields[i].id)) |name|
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
                const size = db.attrs.size.get(register.id) orelse unreachable;
                if (ret == null or (size < ret.?.size))
                    ret = .{
                        .id = register.id,
                        .offset = register.offset,
                        .size = size,
                    };
            }

            break :blk ret orelse unreachable;
        };

        const name = db.attrs.name.get(next.id) orelse unreachable;
        if (offset + next.size > register_size) {
            log.warn("register '{s}' is outside register boundaries: offset={}, size={}, register_size={}", .{
                name,
                next.offset,
                next.size,
                register_size,
            });
            break;
        }

        if (db.attrs.description.get(next.id)) |description|
            try writeComment(db.arena.allocator(), description, writer);

        if (db.attrs.@"enum".get(fields[i].id)) |enum_id| {
            if (db.attrs.name.get(enum_id)) |enum_name| {
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
            const offset = db.attrs.offset.get(register_id) orelse continue;
            try registers.append(.{ .id = register_id, .offset = offset });
        }
    }

    std.sort.sort(EntityWithOffset, registers.items, {}, EntityWithOffset.lessThan);
    return registers;
}

test "gen.peripheral type with register and field" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const peripheral_id = try db.createPeripheral(.{
        .name = "TEST_PERIPHERAL",
    });

    const register_id = try db.createRegister(peripheral_id, .{
        .name = "TEST_REGISTER",
        .size = 32,
        .offset = 0,
    });

    _ = try db.createField(register_id, .{
        .name = "TEST_FIELD",
        .size = 1,
        .offset = 0,
    });

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

test "gen.peripheral instantiation" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const peripheral_id = try db.createPeripheral(.{
        .name = "TEST_PERIPHERAL",
    });

    const register_id = try db.createRegister(peripheral_id, .{
        .name = "TEST_REGISTER",
        .size = 32,
        .offset = 0,
    });

    _ = try db.createField(register_id, .{
        .name = "TEST_FIELD",
        .size = 1,
        .offset = 0,
    });

    const device_id = try db.createDevice(.{
        .name = "TEST_DEVICE",
    });

    _ = try db.createPeripheralInstance(device_id, peripheral_id, .{
        .name = "TEST0",
        .offset = 0x1000,
    });

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

test "gen.peripherals with a shared type" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const peripheral_id = try db.createPeripheral(.{
        .name = "TEST_PERIPHERAL",
    });

    const register_id = try db.createRegister(peripheral_id, .{
        .name = "TEST_REGISTER",
        .size = 32,
        .offset = 0,
    });

    _ = try db.createField(register_id, .{
        .name = "TEST_FIELD",
        .size = 1,
        .offset = 0,
    });

    const device_id = try db.createDevice(.{
        .name = "TEST_DEVICE",
    });

    _ = try db.createPeripheralInstance(device_id, peripheral_id, .{ .name = "TEST0", .offset = 0x1000 });
    _ = try db.createPeripheralInstance(device_id, peripheral_id, .{ .name = "TEST1", .offset = 0x2000 });

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

test "gen.peripheral with modes" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

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

    const peripheral_id = try db.createPeripheral(.{ .name = "TEST_PERIPHERAL" });
    try db.addChild("type.mode", peripheral_id, mode1_id);
    try db.addChild("type.mode", peripheral_id, mode2_id);

    const register1_id = try db.createRegister(peripheral_id, .{ .name = "TEST_REGISTER1", .size = 32, .offset = 0 });
    const register2_id = try db.createRegister(peripheral_id, .{ .name = "TEST_REGISTER2", .size = 32, .offset = 0 });
    const common_reg_id = try db.createRegister(peripheral_id, .{ .name = "COMMON_REGISTER", .size = 32, .offset = 4 });

    try db.attrs.modes.put(db.gpa, register1_id, register1_modeset);
    try db.attrs.modes.put(db.gpa, register2_id, register2_modeset);

    _ = try db.createField(common_reg_id, .{
        .name = "TEST_FIELD",
        .size = 1,
        .offset = 0,
    });

    // TODO: study the types of qualifiers that come up. it's possible that
    // we'll have to read different registers or read registers without fields.
    //
    // might also have registers with enum values
    // naive implementation goes through each mode and follows the qualifier,
    // next level will determine if they're reading the same address even if
    // different modes will use different union members

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

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
        \\        pub fn getMode(self: *volatile @This()) Mode {
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

test "gen.peripheral with enum" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const peripheral_id = try db.createPeripheral(.{
        .name = "TEST_PERIPHERAL",
    });

    const enum_id = try db.createEnum(peripheral_id, .{
        .name = "TEST_ENUM",
        .size = 4,
    });

    _ = try db.createEnumField(enum_id, .{ .name = "TEST_ENUM_FIELD1", .value = 0 });
    _ = try db.createEnumField(enum_id, .{ .name = "TEST_ENUM_FIELD2", .value = 1 });

    _ = try db.createRegister(peripheral_id, .{
        .name = "TEST_REGISTER",
        .size = 8,
        .offset = 0,
    });

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

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

test "gen.peripheral with enum, enum is exhausted of values" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const peripheral_id = try db.createPeripheral(.{
        .name = "TEST_PERIPHERAL",
    });

    const enum_id = try db.createEnum(peripheral_id, .{
        .name = "TEST_ENUM",
        .size = 1,
    });

    _ = try db.createEnumField(enum_id, .{ .name = "TEST_ENUM_FIELD1", .value = 0 });
    _ = try db.createEnumField(enum_id, .{ .name = "TEST_ENUM_FIELD2", .value = 1 });

    _ = try db.createRegister(peripheral_id, .{
        .name = "TEST_REGISTER",
        .size = 8,
        .offset = 0,
    });

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

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

test "gen.field with named enum" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const peripheral_id = try db.createPeripheral(.{
        .name = "TEST_PERIPHERAL",
    });

    const enum_id = try db.createEnum(peripheral_id, .{
        .name = "TEST_ENUM",
        .size = 4,
    });

    _ = try db.createEnumField(enum_id, .{ .name = "TEST_ENUM_FIELD1", .value = 0 });
    _ = try db.createEnumField(enum_id, .{ .name = "TEST_ENUM_FIELD2", .value = 1 });

    const register_id = try db.createRegister(peripheral_id, .{
        .name = "TEST_REGISTER",
        .size = 8,
        .offset = 0,
    });

    _ = try db.createField(register_id, .{
        .name = "TEST_FIELD",
        .size = 4,
        .offset = 0,
        .enum_id = enum_id,
    });

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

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

test "gen.field with anonymous enum" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const peripheral_id = try db.createPeripheral(.{
        .name = "TEST_PERIPHERAL",
    });

    const enum_id = try db.createEnum(peripheral_id, .{
        .size = 4,
    });

    _ = try db.createEnumField(enum_id, .{ .name = "TEST_ENUM_FIELD1", .value = 0 });
    _ = try db.createEnumField(enum_id, .{ .name = "TEST_ENUM_FIELD2", .value = 1 });

    const register_id = try db.createRegister(peripheral_id, .{
        .name = "TEST_REGISTER",
        .size = 8,
        .offset = 0,
    });

    _ = try db.createField(register_id, .{
        .name = "TEST_FIELD",
        .size = 4,
        .offset = 0,
        .enum_id = enum_id,
    });

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

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

test "gen.namespaced register groups" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    // peripheral
    const peripheral_id = try db.createPeripheral(.{
        .name = "PORT",
    });

    // register_groups
    const portb_group_id = try db.createRegisterGroup(peripheral_id, .{ .name = "PORTB" });
    const portc_group_id = try db.createRegisterGroup(peripheral_id, .{ .name = "PORTC" });

    // registers
    _ = try db.createRegister(portb_group_id, .{ .name = "PORTB", .size = 8, .offset = 0 });
    _ = try db.createRegister(portb_group_id, .{ .name = "DDRB", .size = 8, .offset = 1 });
    _ = try db.createRegister(portb_group_id, .{ .name = "PINB", .size = 8, .offset = 2 });
    _ = try db.createRegister(portc_group_id, .{ .name = "PORTC", .size = 8, .offset = 0 });
    _ = try db.createRegister(portc_group_id, .{ .name = "DDRC", .size = 8, .offset = 1 });
    _ = try db.createRegister(portc_group_id, .{ .name = "PINC", .size = 8, .offset = 2 });

    // device
    const device_id = try db.createDevice(.{ .name = "ATmega328P" });

    // instances
    _ = try db.createPeripheralInstance(device_id, portb_group_id, .{ .name = "PORTB", .offset = 0x23 });
    _ = try db.createPeripheralInstance(device_id, portc_group_id, .{ .name = "PORTC", .offset = 0x26 });

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

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

test "gen.peripheral without name" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const peripheral_id = try db.createPeripheral(.{});
    _ = try db.createRegister(peripheral_id, .{ .name = "PORTB", .size = 8, .offset = 0 });
    _ = try db.createRegister(peripheral_id, .{ .name = "DDRB", .size = 8, .offset = 1 });
    _ = try db.createRegister(peripheral_id, .{ .name = "PINB", .size = 8, .offset = 2 });

    const device_id = try db.createDevice(.{
        .name = "ATmega328P",
    });

    _ = try db.createPeripheralInstance(device_id, peripheral_id, .{
        .name = "PORTB",
        .offset = 0x23,
    });

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try db.toZig(buffer.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const devices = struct {
        \\    pub const ATmega328P = struct {
        \\        pub const PORTB = @ptrCast(*volatile packed struct {
        \\            PORTB: u8,
        \\            DDRB: u8,
        \\            PINB: u8,
        \\        }, 0x23);
        \\    };
        \\};
        \\
    , buffer.items);
}

test "gen.peripheral with reserved register" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit();

    const peripheral_id = try db.createPeripheral(.{});
    _ = try db.createRegister(peripheral_id, .{ .name = "PORTB", .size = 32, .offset = 0 });
    _ = try db.createRegister(peripheral_id, .{ .name = "PINB", .size = 32, .offset = 8 });

    const device_id = try db.createDevice(.{
        .name = "ATmega328P",
    });

    _ = try db.createPeripheralInstance(device_id, peripheral_id, .{
        .name = "PORTB",
        .offset = 0x23,
    });

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try db.toZig(buffer.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const devices = struct {
        \\    pub const ATmega328P = struct {
        \\        pub const PORTB = @ptrCast(*volatile packed struct {
        \\            PORTB: u32,
        \\            reserved8: [4]u8,
        \\            PINB: u32,
        \\        }, 0x23);
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
// - modes with discontiguous bits
//
