//! Code generation and associated tests
const std = @import("std");
const Database = @import("Database.zig");

pub fn toZig(db: *Database, out_writer: anytype) !void {
    _ = db;
    _ = out_writer;
}

test "peripheral type" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    const field_id = db.createEntity();
    try db.types.fields.put(db.gpa, field_id, {});
    try db.addName(field_id, "TEST_FIELD");
    try db.addSize(field_id, 1);
    try db.addOffset(field_id, 0);

    const register_id = db.createEntity();
    try db.types.registers.put(db.gpa, register_id, .{});
    try db.addName(register_id, "TEST_REGISTER");
    try db.addSize(register_id, 32);
    try db.types.registers.getEntry(register_id).?.value_ptr.put(db.gpa, field_id, {});

    const register_group_id = db.createEntity();
    try db.types.register_groups.put(db.gpa, register_group_id, .{});
    try db.addName(register_group_id, "TEST_PERIPHERAL");

    const peripheral_id = db.createEntity();
    try db.types.peripherals.put(db.gpa, peripheral_id, .{});
    try db.addName(peripheral_id, "TEST_PERIPHERAL");

    var fifo = std.fifo.LinearFifo(u8, .Dynamic).init(std.testing.allocator);
    defer fifo.deinit();

    try db.toZig(fifo.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const types = struct {
        \\    pub const TEST_PERIPHERAL = packed struct {
        \\        TEST_REGISTER: packed struct {
        \\            TEST_FIELD: u1,
        \\            reserved0: u31,
        \\        },
        \\    };
        \\};
        \\
    , fifo.readableSlice(0));
}

test "peripheral instantiation" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    const field_id = db.createEntity();
    try db.types.fields.put(db.gpa, field_id, {});
    try db.addName(field_id, "TEST_FIELD");
    try db.addSize(field_id, 1);
    try db.addOffset(field_id, 0);

    const register_id = db.createEntity();
    try db.types.registers.put(db.gpa, register_id, .{});
    try db.addName(register_id, "TEST_REGISTER");
    try db.addSize(register_id, 32);
    try db.types.registers.getEntry(register_id).?.value_ptr.put(db.gpa, field_id, {});

    const register_group_id = db.createEntity();
    try db.types.register_groups.put(db.gpa, register_group_id, .{});
    try db.addName(register_group_id, "TEST_PERIPHERAL");

    const peripheral_id = db.createEntity();
    try db.types.peripherals.put(db.gpa, peripheral_id, .{});
    try db.addName(peripheral_id, "TEST_PERIPHERAL");

    const instance_id = db.createEntity();
    try db.instances.peripherals.put(db.gpa, instance_id, peripheral_id);
    try db.addName(instance_id, "TEST0");
    try db.addOffset(instance_id, 0x1000);

    var fifo = std.fifo.LinearFifo(u8, .Dynamic).init(std.testing.allocator);
    defer fifo.deinit();

    try db.toZig(fifo.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const types = struct {
        \\    pub const TEST_PERIPHERAL = packed struct {
        \\        TEST_REGISTER: packed struct {
        \\            TEST_FIELD: u1,
        \\            reserved0: u31,
        \\        },
        \\    };
        \\};
        \\
        \\pub const registers = struct {
        \\    pub const TEST0 = @ptrCast(*volatile types.TEST_PERIPHERAL, 0x1000);
        \\};
        \\
    , fifo.readableSlice(0));
}

test "peripherals with a shared type" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    const field_id = db.createEntity();
    try db.types.fields.put(db.gpa, field_id, {});
    try db.addName(field_id, "TEST_FIELD");
    try db.addSize(field_id, 1);
    try db.addOffset(field_id, 0);

    const register_id = db.createEntity();
    try db.types.registers.put(db.gpa, register_id, .{});
    try db.addName(register_id, "TEST_REGISTER");
    try db.addSize(register_id, 32);
    try db.types.registers.getEntry(register_id).?.value_ptr.put(db.gpa, field_id, {});

    const register_group_id = db.createEntity();
    try db.types.register_groups.put(db.gpa, register_group_id, .{});
    try db.addName(register_group_id, "TEST_PERIPHERAL");

    const peripheral_id = db.createEntity();
    try db.types.peripherals.put(db.gpa, peripheral_id, .{});
    try db.addName(peripheral_id, "TEST_PERIPHERAL");

    const instance0_id = db.createEntity();
    try db.instances.peripherals.put(db.gpa, instance0_id, peripheral_id);
    try db.addName(instance0_id, "TEST0");
    try db.addOffset(instance0_id, 0x1000);

    const instance1_id = db.createEntity();
    try db.instances.peripherals.put(db.gpa, instance1_id, peripheral_id);
    try db.addName(instance1_id, "TEST1");
    try db.addOffset(instance1_id, 0x2000);

    var fifo = std.fifo.LinearFifo(u8, .Dynamic).init(std.testing.allocator);
    defer fifo.deinit();

    try db.toZig(fifo.writer());
    try std.testing.expectEqualStrings(
        \\const mmio = @import("mmio");
        \\
        \\pub const types = struct {
        \\    pub const TEST_PERIPHERAL = packed struct {
        \\        TEST_REGISTER: mmio.Mmio(packed struct {
        \\            TEST_FIELD: u1,
        \\            reserved0: u31,
        \\        }),
        \\    };
        \\};
        \\
        \\pub const registers = struct {
        \\    pub const TEST0 = @ptrCast(*volatile types.TEST_PERIPHERAL, 0x1000);
        \\    pub const TEST1 = @ptrCast(*volatile types.TEST_PERIPHERAL, 0x2000);
        \\};
        \\
    , fifo.readableSlice(0));
}

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
