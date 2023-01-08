//! Common test conditions for code generation and regzon
const std = @import("std");
const Allocator = std.mem.Allocator;

const Database = @import("Database.zig");

pub fn peripheralTypeWithRegisterAndField(allocator: Allocator) !Database {
    var db = try Database.init(allocator);
    errdefer db.deinit();

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

    return db;
}
