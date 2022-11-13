//! Regz JSON output
const std = @import("std");
const json = std.json;
const assert = std.debug.assert;

const Database = @import("Database.zig");

pub fn loadIntoDb(db: *Database, reader: anytype) !void {
    _ = db;
    _ = reader;
}

pub fn toJson(db: Database) !json.ValueTree {
    _ = db;
}

// =============================================================================
// loadIntoDb Tests
// =============================================================================

// =============================================================================
// toJson Tests
// =============================================================================
