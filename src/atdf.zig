const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Database = @import("Database.zig");
const EntityId = Database.EntityId;

const xml = @import("xml.zig");
const Peripheral = @import("Peripheral.zig");
const Register = @import("Register.zig");
const Field = @import("Field.zig");

// TODO: scratchpad datastructure for temporary string based relationships,
// then stitch it all together in the end
pub fn loadIntoDb(db: *Database, doc: xml.Doc) !void {
    const root = try doc.getRootElement();
    var module_it = root.iterate(&.{"modules"}, "module");
    while (module_it.next()) |entry|
        try loadModuleType(db, entry);

    var device_it = root.iterate(&.{"devices"}, "device");
    while (device_it.next()) |entry|
        try loadDevice(db, entry);

    db.assertValid();
}

fn loadDevice(db: *Database, node: xml.Node) !void {
    validateAttrs(node, &.{
        "architecture",
        "name",
        "family",
        "series",
    });

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    std.log.debug("{}: creating device", .{id});
    const name = node.getAttribute("name") orelse return error.NoDeviceName;
    const arch = node.getAttribute("architecture") orelse return error.NoDeviceArch;
    const family = node.getAttribute("family") orelse return error.NoDeviceFamily;
    try db.instances.devices.put(db.gpa, id, .{});
    try db.addName(id, name);
    try db.addDeviceProperty(id, "arch", arch);
    try db.addDeviceProperty(id, "family", family);
    if (node.getAttribute("series")) |series|
        try db.addDeviceProperty(id, "series", series);

    var module_it = node.iterate(&.{"peripherals"}, "module");
    while (module_it.next()) |module_node|
        loadModuleInstances(db, module_node) catch |err| {
            std.log.warn("failed to instantiate module: {}", .{err});
        };

    var interrupt_it = node.iterate(&.{"interrupts"}, "interrupt");
    while (interrupt_it.next()) |interrupt_node|
        try loadInterrupt(db, interrupt_node, id);

    // TODO:
    // address-space.memory-segment
    // events.generators.generator
    // events.users.user
    // interfaces.interface.parameters.param
    // TODO: This is capitalized for some reason :facepalm:
    // interrupts.Interrupt
    // interrupts.interrupt-group
    // parameters.param

    // property-groups.property-group.property
}

// TODO: instances use name in module
fn getInlinedRegisterGroup(parent_node: xml.Node, parent_name: []const u8, name_key: [:0]const u8) ?xml.Node {
    var register_group_it = parent_node.iterate(&.{}, "register-group");
    const rg_node = register_group_it.next() orelse return null;
    const rg_name = rg_node.getAttribute(name_key) orelse return null;
    if (register_group_it.next() != null) {
        std.log.debug("register group not alone", .{});
        return null;
    }

    return if (std.mem.eql(u8, rg_name, parent_name))
        rg_node
    else
        null;
}

// module instances are listed under atdf-tools-device-file.modules.
fn loadModuleType(db: *Database, node: xml.Node) !void {
    validateAttrs(node, &.{
        "oldname",
        "name",
        "id",
        "version",
        "caption",
        "name2",
    });

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    std.log.debug("{}: creating peripheral type", .{id});
    try db.types.peripherals.put(db.gpa, id, {});
    const name = node.getAttribute("name") orelse return error.ModuleTypeMissingName;
    try db.addName(id, name);

    if (node.getAttribute("caption")) |caption|
        try db.addDescription(id, caption);

    var value_group_it = node.iterate(&.{}, "value-group");
    while (value_group_it.next()) |value_group_node|
        try loadEnum(db, value_group_node, id);

    // special case but the most common, if there is only one register
    // group and it's name matches the peripheral, then inline the
    // registers. This operation needs to be done in
    // `loadModuleInstance()` as well
    if (getInlinedRegisterGroup(node, name, "name")) |register_group_node| {
        try loadRegisterGroupChildren(db, register_group_node, id);
    } else {
        var register_group_it = node.iterate(&.{}, "register-group");
        while (register_group_it.next()) |register_group_node|
            try loadRegisterGroup(db, register_group_node, id);
    }
    // TODO: interrupt-group
}

fn loadRegisterGroupChildren(
    db: *Database,
    node: xml.Node,
    dest_id: EntityId,
) !void {
    assert(db.entityIs("type.peripheral", dest_id) or
        db.entityIs("type.register_group", dest_id));

    var mode_it = node.iterate(&.{}, "mode");
    while (mode_it.next()) |mode_node|
        loadMode(db, mode_node, dest_id) catch |err| {
            std.log.err("{}: failed to load mode: {}", .{ dest_id, err });
        };

    var register_it = node.iterate(&.{}, "register");
    while (register_it.next()) |register_node|
        try loadRegister(db, register_node, dest_id);
}

// loads a register group which is under a peripheral or under another
// register-group
fn loadRegisterGroup(
    db: *Database,
    node: xml.Node,
    parent_id: EntityId,
) !void {
    assert(db.entityIs("type.peripheral", parent_id) or
        db.entityIs("type.register_group", parent_id));

    if (db.entityIs("type.peripheral", parent_id)) {
        validateAttrs(node, &.{
            "name",
            "caption",
            "aligned",
            "section",
            "size",
        });
    } else if (db.entityIs("type.register_group", parent_id)) {
        validateAttrs(node, &.{
            "name",
            "modes",
            "size",
            "name-in-module",
            "caption",
            "count",
            "start-index",
            "offset",
        });
    }

    // TODO: if a register group has the same name as the module then the
    // registers should be flattened in the namespace
    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    std.log.debug("{}: creating register group", .{id});
    try db.types.register_groups.put(db.gpa, id, {});
    if (node.getAttribute("name")) |name|
        try db.addName(id, name);

    if (node.getAttribute("caption")) |caption|
        try db.addDescription(id, caption);

    if (node.getAttribute("size")) |size|
        try db.addSize(id, try std.fmt.parseInt(u64, size, 0));

    try loadRegisterGroupChildren(db, node, id);

    // TODO: register-group
    // connect with parent
    try db.addChild("type.register_group", parent_id, id);
}

fn loadMode(db: *Database, node: xml.Node, parent_id: EntityId) !void {
    assert(db.entityIs("type.peripheral", parent_id) or
        db.entityIs("type.register_group", parent_id) or
        db.entityIs("type.register", parent_id));

    validateAttrs(node, &.{
        "value",
        "mask",
        "name",
        "qualifier",
        "caption",
    });

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    const value_str = node.getAttribute("value") orelse return error.MissingModeValue;
    const qualifier = node.getAttribute("qualifier") orelse return error.MissingModeQualifier;
    std.log.debug("{}: creating mode, value={s}, qualifier={s}", .{ id, value_str, qualifier });
    try db.types.modes.put(db.gpa, id, .{
        .value = try db.arena.allocator().dupe(u8, value_str),
        .qualifier = try db.arena.allocator().dupe(u8, qualifier),
    });

    const name = node.getAttribute("name") orelse return error.MissingModeName;
    try db.addName(id, name);
    if (node.getAttribute("caption")) |caption|
        try db.addDescription(id, caption);

    try db.addChild("type.mode", parent_id, id);
    // TODO: "mask": "optional",
}

// search for modes that the parent entity owns, and if the name matches,
// then we have our entry. If not found then the input is malformed.
// TODO: assert unique mode name
fn assignModesToEntity(
    db: *Database,
    id: EntityId,
    parent_id: EntityId,
    mode_names: []const u8,
) !void {
    var modes = Database.Modes{};
    errdefer modes.deinit(db.gpa);

    const modeset = if (db.children.modes.get(parent_id)) |modeset|
        modeset
    else {
        std.log.warn("{}: failed to find mode set", .{id});
        return;
    };

    var tok_it = std.mem.tokenize(u8, mode_names, " ");
    while (tok_it.next()) |mode_str| {
        var it = modeset.iterator();
        while (it.next()) |mode_entry| {
            const mode_id = mode_entry.key_ptr.*;
            if (db.attrs.names.get(mode_id)) |name|
                if (std.mem.eql(u8, name, mode_str)) {
                    const result = try db.attrs.modes.getOrPut(db.gpa, id);
                    if (!result.found_existing)
                        result.value_ptr.* = .{};

                    try result.value_ptr.put(db.gpa, mode_id, {});
                    std.log.debug("{}: assigned mode '{s}'", .{ id, name });
                    return;
                };
        } else {
            if (db.attrs.names.get(id)) |name|
                std.log.warn("failed to find mode '{s}' for '{s}'", .{
                    mode_str,
                    name,
                })
            else
                std.log.warn("failed to find mode '{s}'", .{
                    mode_str,
                });

            return error.MissingMode;
        }
    }

    if (modes.count() > 0)
        try db.attrs.modes.put(db.gpa, id, modes);
}

fn loadRegister(
    db: *Database,
    node: xml.Node,
    parent_id: EntityId,
) !void {
    assert(db.entityIs("type.register_group", parent_id) or
        db.entityIs("type.peripheral", parent_id));

    validateAttrs(node, &.{
        "rw",
        "name",
        "access-size",
        "modes",
        "initval",
        "size",
        "access",
        "mask",
        "bit-addressable",
        "atomic-op",
        "ocd-rw",
        "caption",
        "count",
        "offset",
    });

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    std.log.debug("{}: creating register", .{id});
    const name = node.getAttribute("name") orelse return error.MissingRegisterName;
    try db.types.registers.put(db.gpa, id, {});
    try db.addName(id, name);
    if (node.getAttribute("modes")) |modes|
        assignModesToEntity(db, id, parent_id, modes) catch {
            std.log.warn("failed to find mode '{s}' for register '{s}'", .{
                modes,
                name,
            });
        };

    if (node.getAttribute("offset")) |offset_str| {
        const offset = try std.fmt.parseInt(u64, offset_str, 0);
        try db.addOffset(id, offset);
    }

    if (node.getAttribute("size")) |size_str| {
        const size = try std.fmt.parseInt(u64, size_str, 0);
        try db.addSize(id, size);
    }

    if (node.getAttribute("rw")) |access_str| blk: {
        const access = accessFromString(access_str) catch break :blk;
        switch (access) {
            .read_only, .write_only => try db.attrs.access.put(
                db.gpa,
                id,
                access,
            ),
            else => {},
        }
    }

    // assumes that modes are parsed before registers in the register group
    var mode_it = node.iterate(&.{}, "mode");
    while (mode_it.next()) |mode_node|
        loadMode(db, mode_node, id) catch |err| {
            std.log.err("{}: failed to load mode: {}", .{ id, err });
        };

    var field_it = node.iterate(&.{}, "bitfield");
    while (field_it.next()) |field_node|
        loadField(db, field_node, id) catch {};

    try db.addChild("type.register", parent_id, id);
}

fn loadField(db: *Database, node: xml.Node, register_id: EntityId) !void {
    assert(db.entityIs("type.register", register_id));
    validateAttrs(node, &.{
        "caption",
        "lsb",
        "mask",
        "modes",
        "name",
        "rw",
        "value",
        "values",
    });

    const name = node.getAttribute("name") orelse return error.MissingFieldName;
    const mask_str = node.getAttribute("mask") orelse return error.MissingFieldMask;
    const mask = std.fmt.parseInt(u64, mask_str, 0) catch |err| {
        std.log.warn("failed to parse mask '{s}' of bitfield '{s}'", .{
            mask_str,
            name,
        });

        return err;
    };

    const offset = @ctz(mask);
    const leading_zeroes = @clz(mask);

    // if the bitfield is discontiguous then we'll break it up into single bit
    // fields. This assumes that the order of the bitfields is in order
    if (@popCount(mask) != @as(u64, 64) - leading_zeroes - offset) {
        var bit_count: u32 = 0;
        var i = offset;
        while (i < 32) : (i += 1) {
            if (0 != (@as(u64, 1) << @intCast(u5, i)) & mask) {
                const field_name = try std.fmt.allocPrint(db.arena.allocator(), "{s}_bit{}", .{
                    name,
                    bit_count,
                });
                bit_count += 1;

                const id = db.createEntity();
                errdefer db.destroyEntity(id);

                std.log.debug("{}: creating field", .{id});
                try db.types.fields.put(db.gpa, id, {});
                try db.addName(id, field_name);
                try db.addOffset(id, i);
                try db.addSize(id, 1);
                if (node.getAttribute("caption")) |caption|
                    try db.addDescription(id, caption);

                if (node.getAttribute("modes")) |modes|
                    assignModesToEntity(db, id, register_id, modes) catch {
                        std.log.warn("failed to find mode '{s}' for field '{s}'", .{
                            modes,
                            name,
                        });
                    };

                if (node.getAttribute("rw")) |access_str| blk: {
                    const access = accessFromString(access_str) catch break :blk;
                    switch (access) {
                        .read_only, .write_only => try db.attrs.access.put(
                            db.gpa,
                            id,
                            access,
                        ),
                        else => {},
                    }
                }

                // discontiguous fields like this don't get to have enums
                try db.addChild("type.field", register_id, id);
            }
        }
    } else {
        const width = @popCount(mask);

        const id = db.createEntity();
        errdefer db.destroyEntity(id);

        std.log.debug("{}: creating field", .{id});
        try db.types.fields.put(db.gpa, id, {});
        try db.addName(id, name);
        try db.addOffset(id, offset);
        try db.addSize(id, width);
        if (node.getAttribute("caption")) |caption|
            try db.addDescription(id, caption);

        // TODO: modes are space delimited, and multiple can apply to a single bitfield or register
        if (node.getAttribute("modes")) |modes|
            assignModesToEntity(db, id, register_id, modes) catch {
                std.log.warn("failed to find mode '{s}' for field '{s}'", .{
                    modes,
                    name,
                });
            };

        if (node.getAttribute("rw")) |access_str| blk: {
            const access = accessFromString(access_str) catch break :blk;
            switch (access) {
                .read_only, .write_only => try db.attrs.access.put(
                    db.gpa,
                    id,
                    access,
                ),
                else => {},
            }
        }

        // values _should_ match to a known enum
        // TODO: namespace the enum to the appropriate register, register_group, or peripheral
        if (node.getAttribute("values")) |values| {
            var it = db.types.enums.iterator();
            while (it.next()) |entry| {
                const enum_id = entry.key_ptr.*;
                const enum_name = db.attrs.names.get(enum_id) orelse continue;
                if (std.mem.eql(u8, enum_name, values)) {
                    std.log.debug("{}: assigned enum '{s}'", .{ id, enum_name });
                    try db.attrs.enums.put(db.gpa, id, enum_id);
                    break;
                }
            } else std.log.debug("{}: failed to find corresponding enum", .{id});
        }

        try db.addChild("type.field", register_id, id);
    }
}

fn accessFromString(str: []const u8) !Database.Access {
    return if (std.mem.eql(u8, "RW", str))
        .read_write
    else if (std.mem.eql(u8, "R", str))
        .read_only
    else if (std.mem.eql(u8, "W", str))
        .write_only
    else
        error.InvalidAccessStr;
}

fn loadEnum(
    db: *Database,
    node: xml.Node,
    peripheral_id: EntityId,
) !void {
    assert(db.entityIs("type.peripheral", peripheral_id));

    validateAttrs(node, &.{
        "name",
        "caption",
    });

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    std.log.debug("{}: creating enum", .{id});
    const name = node.getAttribute("name") orelse return error.MissingEnumName;
    try db.types.enums.put(db.gpa, id, {});
    try db.addName(id, name);
    if (node.getAttribute("caption")) |caption|
        try db.addDescription(id, caption);

    var value_it = node.iterate(&.{}, "value");
    while (value_it.next()) |value_node|
        loadEnumField(db, value_node, id) catch {};

    try db.addChild("type.enum", peripheral_id, id);
}

fn loadEnumField(
    db: *Database,
    node: xml.Node,
    enum_id: EntityId,
) !void {
    assert(db.entityIs("type.enum", enum_id));

    validateAttrs(node, &.{
        "name",
        "caption",
        "value",
    });

    const name = node.getAttribute("name") orelse return error.MissingEnumFieldName;
    const value_str = node.getAttribute("value") orelse {
        std.log.warn("enum missing value: {s}", .{name});
        return error.MissingEnumFieldValue;
    };

    const value = std.fmt.parseInt(u32, value_str, 0) catch |err| {
        std.log.warn("failed to parse enum value '{s}' of enum field '{s}'", .{
            value_str,
            name,
        });
        return err;
    };

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    std.log.debug("{}: creating enum field with value: {}", .{ id, value });
    try db.addName(id, name);
    try db.types.enum_fields.put(db.gpa, id, value);
    if (node.getAttribute("caption")) |caption|
        try db.addDescription(id, caption);

    try db.addChild("type.enum_field", enum_id, id);
}

// module instances are listed under atdf-tools-device-file.devices.device.peripherals
fn loadModuleInstances(db: *Database, node: xml.Node) !void {
    const module_name = node.getAttribute("name") orelse return error.MissingModuleName;
    const type_id = blk: {
        var periph_it = db.types.peripherals.iterator();
        while (periph_it.next()) |entry| {
            if (db.attrs.names.get(entry.key_ptr.*)) |entry_name|
                if (std.mem.eql(u8, entry_name, module_name))
                    break :blk entry.key_ptr.*;
        } else {
            std.log.warn("failed to find the '{s}' peripheral type", .{
                module_name,
            });
            return error.MissingPeripheralType;
        }
    };

    var instance_it = node.iterate(&.{}, "instance");
    while (instance_it.next()) |instance_node|
        try loadModuleInstance(db, instance_node, type_id);
}

fn loadModuleInstance(db: *Database, node: xml.Node, peripheral_type_id: EntityId) !void {
    assert(db.entityIs("type.peripheral", peripheral_type_id));

    validateAttrs(node, &.{
        "oldname",
        "name",
        "caption",
    });

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    std.log.debug("{}: creating module instance", .{id});
    const name = node.getAttribute("name") orelse return error.MissingInstanceName;
    try db.instances.peripherals.put(db.gpa, id, .{ .type_id = peripheral_type_id });
    try db.addName(id, name);
    if (getInlinedRegisterGroup(node, name, "name")) |register_group_node| {
        const offset_str = register_group_node.getAttribute("offset") orelse return error.MissingPeripheralOffset;
        const offset = try std.fmt.parseInt(u64, offset_str, 0);
        try db.addOffset(id, offset);
    } else {
        var register_group_it = node.iterate(&.{}, "register-group");
        while (register_group_it.next()) |register_group_node|
            loadRegisterGroupInstance(db, register_group_node, id, peripheral_type_id) catch {};
    }

    var signal_it = node.iterate(&.{"signals"}, "signal");
    while (signal_it.next()) |signal_node|
        try loadSignal(db, signal_node, id);

    // TODO:
    // clock-groups.clock-group.clock
    // parameters.param
}

fn loadRegisterGroupInstance(
    db: *Database,
    node: xml.Node,
    peripheral_id: EntityId,
    peripheral_type_id: EntityId,
) !void {
    assert(db.entityIs("instance.peripheral", peripheral_id));
    assert(db.entityIs("type.peripheral", peripheral_type_id));
    validateAttrs(node, &.{
        "name",
        "address-space",
        "version",
        "size",
        "name-in-module",
        "caption",
        "id",
        "offset",
    });

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    std.log.debug("{}: creating register group instance", .{id});
    const name = node.getAttribute("name") orelse return error.MissingInstanceName;
    // TODO: this isn't always a set value, not sure what to do if it's left out
    const name_in_module = node.getAttribute("name-in-module") orelse {
        std.log.warn("no 'name-in-module' for register group '{s}'", .{
            name,
        });

        return error.MissingNameInModule;
    };

    const type_id = blk: {
        var type_it = (db.children.register_groups.get(peripheral_type_id) orelse
            return error.MissingRegisterGroupType).iterator();

        while (type_it.next()) |entry| {
            if (db.attrs.names.get(entry.key_ptr.*)) |entry_name|
                if (std.mem.eql(u8, entry_name, name_in_module))
                    break :blk entry.key_ptr.*;
        } else return error.MissingRegisterGroupType;
    };

    try db.instances.register_groups.put(db.gpa, id, type_id);
    try db.addName(id, name);
    if (node.getAttribute("caption")) |caption|
        try db.addDescription(id, caption);

    if (node.getAttribute("size")) |size_str| {
        const size = try std.fmt.parseInt(u64, size_str, 0);
        try db.addSize(id, size);
    }

    if (node.getAttribute("offset")) |offset_str| {
        const offset = try std.fmt.parseInt(u64, offset_str, 0);
        try db.addOffset(id, offset);
    }

    try db.addChild("instance.register_group", peripheral_id, id);

    // TODO:
    // "address-space": "optional",
    // "version": "optional",
    // "id": "optional",
}

fn loadSignal(db: *Database, node: xml.Node, peripheral_id: EntityId) !void {
    assert(db.entityIs("instance.peripheral", peripheral_id));
    validateAttrs(node, &.{
        "group",
        "index",
        "pad",
        "function",
        "field",
        "ioset",
    });

    // TODO: pads
}

// TODO: there are fields like irq-index
fn loadInterrupt(db: *Database, node: xml.Node, device_id: EntityId) !void {
    assert(db.entityIs("instance.device", device_id));
    validateAttrs(node, &.{
        "index",
        "name",
        "irq-caption",
        "alternate-name",
        "irq-index",
        "caption",
        // TODO: probably connects module instance to interrupt
        "module-instance",
        "irq-name",
        "alternate-caption",
    });

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    const name = node.getAttribute("name") orelse return error.MissingInterruptName;
    const index_str = node.getAttribute("index") orelse return error.MissingInterruptIndex;
    const index = std.fmt.parseInt(i32, index_str, 0) catch |err| {
        std.log.warn("failed to parse value '{s}' of interrupt '{s}'", .{
            index_str,
            name,
        });
        return err;
    };

    std.log.debug("{}: creating interrupt {}", .{ id, index });
    try db.instances.interrupts.put(db.gpa, id, index);
    try db.addName(id, name);
    if (node.getAttribute("caption")) |caption|
        try db.addDescription(id, caption);

    try db.addChild("instance.interrupt", device_id, id);
}

// for now just emit warning logs when the input has attributes that it shouldn't have
// TODO: better output
fn validateAttrs(node: xml.Node, attrs: []const []const u8) void {
    var it = node.iterateAttrs();
    while (it.next()) |attr| {
        for (attrs) |expected_attr| {
            if (std.mem.eql(u8, attr.key, expected_attr))
                break;
        } else std.log.warn("line {}: the '{s}' isn't usually found in the '{s}' element, this could mean unhandled ATDF behaviour or your input is malformed", .{
            node.impl.line,
            attr.key,
            std.mem.span(node.impl.name),
        });
    }
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "register with mode" {
    const text =
        \\<avr-tools-device-file>
        \\  <modules>
        \\    <module caption="16-bit Timer/Counter Type A" id="I2117" name="TCA">
        \\      <register-group caption="16-bit Timer/Counter Type A" name="TCA" size="0x40">
        \\        <mode caption="Single Mode"
        \\              name="SINGLE"
        \\              qualifier="TCA.SINGLE.CTRLD.SPLITM"
        \\              value="0"/>
        \\        <mode caption="Split Mode"
        \\              name="SPLIT"
        \\              qualifier="TCA.SPLIT.CTRLD.SPLITM"
        \\              value="1"/>
        \\        <register caption="Control A"
        \\                  initval="0x00"
        \\                  modes="SINGLE"
        \\                  name="CTRLA"
        \\                  offset="0x00"
        \\                  rw="RW"
        \\                  size="1"/>
        \\      </register-group>
        \\    </module>
        \\  </modules>
        \\</avr-tools-device-file>
        \\
    ;

    var doc = try xml.Doc.fromMemory(text);
    var db = try Database.initFromAtdf(std.testing.allocator, doc);
    defer db.deinit();

    // there will only be one register
    try expectEqual(@as(usize, 1), db.types.registers.count());
    const register_id = blk: {
        var it = db.types.registers.iterator();
        break :blk it.next().?.key_ptr.*;
    };

    // the register will have one associated mode
    try expect(db.attrs.modes.contains(register_id));
    const modeset = db.attrs.modes.get(register_id).?;
    try expectEqual(@as(usize, 1), modeset.count());
    const mode_id = blk: {
        var it = modeset.iterator();
        break :blk it.next().?.key_ptr.*;
    };

    // the name of the mode is 'SINGLE'
    try expect(db.attrs.names.contains(register_id));
    const mode_name = db.attrs.names.get(mode_id).?;
    try expectEqualStrings("SINGLE", mode_name);

    // the register group should be flattened, so the mode should be a child of
    // the peripheral
    try expectEqual(@as(usize, 1), db.types.peripherals.count());
    const peripheral_id = blk: {
        var it = db.types.peripherals.iterator();
        break :blk it.next().?.key_ptr.*;
    };
    try expect(db.children.modes.contains(peripheral_id));
    const peripheral_modes = db.children.modes.get(peripheral_id).?;
    try expect(peripheral_modes.contains(mode_id));
}
