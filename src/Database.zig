const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const assert = std.debug.assert;
const HashMap = std.AutoHashMapUnmanaged;
const ArrayHashMap = std.AutoArrayHashMapUnmanaged;

const xml = @import("xml.zig");
const svd = @import("svd.zig");
const atdf = @import("atdf.zig");
const dslite = @import("dslite.zig");
const gen = @import("gen.zig");
const regzon = @import("regzon.zig");

const Database = @This();
const log = std.log.scoped(.database);

pub const EntityId = u32;
pub const EntitySet = ArrayHashMap(EntityId, void);

pub const Access = enum {
    read_only,
    write_only,
    read_write,
};

pub const Device = struct {
    properties: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn deinit(self: *Device, gpa: Allocator) void {
        self.properties.deinit(gpa);
    }
};

pub const Mode = struct {
    qualifier: []const u8,
    value: []const u8,
};

/// a collection of modes that applies to a register or bitfield
pub const Modes = EntitySet;

gpa: Allocator,
arena: *ArenaAllocator,
next_entity_id: u32,

// attributes are extra information that each entity might have, in some
// contexts they're required, in others they're optional
attrs: struct {
    names: HashMap(EntityId, []const u8) = .{},
    descriptions: HashMap(EntityId, []const u8) = .{},
    offsets: HashMap(EntityId, u64) = .{},
    access: HashMap(EntityId, Access) = .{},
    repeated: HashMap(EntityId, u64) = .{},
    sizes: HashMap(EntityId, u64) = .{},
    reset_values: HashMap(EntityId, u64) = .{},
    reset_masks: HashMap(EntityId, u64) = .{},
    versions: HashMap(EntityId, []const u8) = .{},

    // a register or bitfield can be valid in one or more modes of their parent
    modes: HashMap(EntityId, Modes) = .{},

    // a field type might have an enum type
    enums: HashMap(EntityId, EntityId) = .{},

    parents: HashMap(EntityId, EntityId) = .{},
} = .{},

children: struct {
    interrupts: ArrayHashMap(EntityId, EntitySet) = .{},
    peripherals: ArrayHashMap(EntityId, EntitySet) = .{},
    register_groups: ArrayHashMap(EntityId, EntitySet) = .{},
    registers: ArrayHashMap(EntityId, EntitySet) = .{},
    fields: ArrayHashMap(EntityId, EntitySet) = .{},
    enums: ArrayHashMap(EntityId, EntitySet) = .{},
    enum_fields: ArrayHashMap(EntityId, EntitySet) = .{},
    modes: ArrayHashMap(EntityId, EntitySet) = .{},
} = .{},

types: struct {
    peripherals: ArrayHashMap(EntityId, void) = .{},
    register_groups: ArrayHashMap(EntityId, void) = .{},
    registers: ArrayHashMap(EntityId, void) = .{},
    fields: ArrayHashMap(EntityId, void) = .{},
    enums: ArrayHashMap(EntityId, void) = .{},
    enum_fields: ArrayHashMap(EntityId, u32) = .{},

    // atdf has modes which make registers into unions
    modes: ArrayHashMap(EntityId, Mode) = .{},
} = .{},

instances: struct {
    devices: ArrayHashMap(EntityId, Device) = .{},
    interrupts: ArrayHashMap(EntityId, i32) = .{},
    peripherals: ArrayHashMap(EntityId, EntityId) = .{},
    //register_groups: ArrayHashMap(EntityId, EntityId) = .{},
    //registers: ArrayHashMap(EntityId, EntityId) = .{},
} = .{},

// to speed up lookups
indexes: struct {} = .{},

fn deinitMapAndValues(allocator: std.mem.Allocator, map: anytype) void {
    var it = map.iterator();
    while (it.next()) |entry|
        entry.value_ptr.deinit(allocator);

    map.deinit(allocator);
}

pub fn deinit(db: *Database) void {
    // attrs
    db.attrs.names.deinit(db.gpa);
    db.attrs.descriptions.deinit(db.gpa);
    db.attrs.offsets.deinit(db.gpa);
    db.attrs.access.deinit(db.gpa);
    db.attrs.repeated.deinit(db.gpa);
    db.attrs.sizes.deinit(db.gpa);
    db.attrs.reset_values.deinit(db.gpa);
    db.attrs.reset_masks.deinit(db.gpa);
    db.attrs.versions.deinit(db.gpa);
    db.attrs.enums.deinit(db.gpa);
    db.attrs.parents.deinit(db.gpa);
    deinitMapAndValues(db.gpa, &db.attrs.modes);

    // children
    deinitMapAndValues(db.gpa, &db.children.interrupts);
    deinitMapAndValues(db.gpa, &db.children.peripherals);
    deinitMapAndValues(db.gpa, &db.children.register_groups);
    deinitMapAndValues(db.gpa, &db.children.registers);
    deinitMapAndValues(db.gpa, &db.children.fields);
    deinitMapAndValues(db.gpa, &db.children.enums);
    deinitMapAndValues(db.gpa, &db.children.enum_fields);
    deinitMapAndValues(db.gpa, &db.children.modes);

    // types
    db.types.peripherals.deinit(db.gpa);
    db.types.register_groups.deinit(db.gpa);
    db.types.registers.deinit(db.gpa);
    db.types.fields.deinit(db.gpa);
    db.types.enums.deinit(db.gpa);
    db.types.enum_fields.deinit(db.gpa);
    db.types.modes.deinit(db.gpa);

    // instances
    deinitMapAndValues(db.gpa, &db.instances.devices);
    db.instances.interrupts.deinit(db.gpa);
    db.instances.peripherals.deinit(db.gpa);
    //db.instances.register_groups.deinit(db.gpa);
    //db.instances.registers.deinit(db.gpa);

    // indexes

    db.arena.deinit();
    db.gpa.destroy(db.arena);
}

pub fn init(allocator: std.mem.Allocator) !Database {
    const arena = try allocator.create(ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return Database{
        .gpa = allocator,
        .arena = arena,
        .next_entity_id = 0,
    };
}

// TODO: figure out how to do completions: bash, zsh, fish, powershell, cmd
pub fn initFromAtdf(allocator: Allocator, doc: xml.Doc) !Database {
    var db = try Database.init(allocator);
    errdefer db.deinit();

    try atdf.loadIntoDb(&db, doc);
    return db;
}

pub fn initFromSvd(allocator: Allocator, doc: xml.Doc) !Database {
    var db = try Database.init(allocator);
    errdefer db.deinit();

    try svd.loadIntoDb(&db, doc);
    return db;
}

pub fn initFromDslite(allocator: Allocator, doc: xml.Doc) !Database {
    var db = try Database.init(allocator);
    errdefer db.deinit();

    try dslite.loadIntoDb(&db, doc);
    return db;
}

pub fn initFromJson(allocator: Allocator, reader: anytype) !Database {
    var db = try Database.init(allocator);
    errdefer db.deinit();

    try regzon.loadIntoDb(&db, reader);
    return db;
}

pub fn createEntity(db: *Database) EntityId {
    defer db.next_entity_id += 1;
    return db.next_entity_id;
}

pub fn destroyEntity(db: *Database, id: EntityId) void {
    _ = db;
    _ = id;
}

pub fn addName(db: *Database, id: EntityId, name: []const u8) !void {
    if (name.len == 0)
        return;

    log.debug("{}: adding name: {s}", .{ id, name });
    try db.attrs.names.putNoClobber(
        db.gpa,
        id,
        try db.arena.allocator().dupe(u8, name),
    );
}

pub fn addDescription(
    db: *Database,
    id: EntityId,
    description: []const u8,
) !void {
    if (description.len == 0)
        return;

    log.debug("{}: adding description: {s}", .{ id, description });
    try db.attrs.descriptions.putNoClobber(
        db.gpa,
        id,
        try db.arena.allocator().dupe(u8, description),
    );
}

pub fn addSize(db: *Database, id: EntityId, size: u64) !void {
    log.debug("{}: adding size: {}", .{ id, size });
    try db.attrs.sizes.putNoClobber(db.gpa, id, size);
}

pub fn addOffset(db: *Database, id: EntityId, offset: u64) !void {
    log.debug("{}: adding offset: {}", .{ id, offset });
    try db.attrs.offsets.putNoClobber(db.gpa, id, offset);
}

pub fn addResetValue(db: *Database, id: EntityId, reset_value: u64) !void {
    log.debug("{}: adding reset value: {}", .{ id, reset_value });
    try db.attrs.reset_values.putNoClobber(db.gpa, id, reset_value);
}

pub fn addChild(
    db: *Database,
    comptime entity_location: []const u8,
    parent_id: EntityId,
    child_id: EntityId,
) !void {
    log.debug("{}: ({s}) is child of: {}", .{
        child_id,
        entity_location,
        parent_id,
    });

    assert(db.entityIs(entity_location, child_id));
    comptime var it = std.mem.tokenize(u8, entity_location, ".");
    // the tables are in plural form but "type.peripheral" feels better to me
    // for calling this function
    comptime _ = it.next();
    comptime var table = (it.next() orelse unreachable) ++ "s";

    const result = try @field(db.children, table).getOrPut(db.gpa, parent_id);
    if (!result.found_existing)
        result.value_ptr.* = .{};

    try result.value_ptr.put(db.gpa, child_id, {});
    try db.attrs.parents.putNoClobber(db.gpa, child_id, parent_id);
}

pub fn addDeviceProperty(
    db: *Database,
    id: EntityId,
    key: []const u8,
    value: []const u8,
) !void {
    log.debug("{}: adding device attr: {s}={s}", .{ id, key, value });
    if (db.instances.devices.getEntry(id)) |entry|
        try entry.value_ptr.properties.put(
            db.gpa,
            key,
            try db.arena.allocator().dupe(u8, value),
        )
    else
        unreachable;
}

// TODO: assert that entity is only found in one table
pub fn entityIs(db: Database, comptime entity_location: []const u8, id: EntityId) bool {
    comptime var it = std.mem.tokenize(u8, entity_location, ".");
    // the tables are in plural form but "type.peripheral" feels better to me
    // for calling this function
    comptime var group = (it.next() orelse unreachable) ++ "s";
    comptime var table = (it.next() orelse unreachable) ++ "s";

    // TODO: nice error messages, like group should either be 'type' or 'instance'
    return @field(@field(db, group), table).contains(id);
}

pub fn getEntityIdByName(
    db: Database,
    comptime entity_location: []const u8,
    name: []const u8,
) !EntityId {
    comptime var tok_it = std.mem.tokenize(u8, entity_location, ".");
    // the tables are in plural form but "type.peripheral" feels better to me
    // for calling this function
    comptime var group = (tok_it.next() orelse unreachable) ++ "s";
    comptime var table = (tok_it.next() orelse unreachable) ++ "s";

    var it = @field(@field(db, group), table).iterator();
    return while (it.next()) |entry| {
        const entry_id = entry.key_ptr.*;
        const entry_name = db.attrs.names.get(entry_id) orelse continue;
        if (std.mem.eql(u8, name, entry_name)) {
            assert(db.entityIs(entity_location, entry_id));
            return entry_id;
        }
    } else error.NameNotFound;
}

// assert that the database is in valid state
pub fn assertValid(db: Database) void {
    // entity id's should only ever be the primary key in one of the type or
    // instance maps.
    var id: u32 = 0;
    while (id < db.next_entity_id) : (id += 1) {
        var count: u32 = 0;
        inline for (.{ "types", "instances" }) |area| {
            inline for (@typeInfo(@TypeOf(@field(db, area))).Struct.fields) |field| {
                if (@field(@field(db, area), field.name).contains(id))
                    count += 1;
            }
        }

        assert(count <= 1); // entity id found in more than one place
    }

    // TODO: check for circular dependencies in relationships
}

/// stringify entire database to JSON, you choose what formatting options you
/// want
pub fn jsonStringify(
    db: Database,
    opts: std.json.StringifyOptions,
    writer: anytype,
) !void {
    var value_tree = try regzon.toJson(db);
    defer value_tree.deinit();

    try value_tree.root.jsonStringify(opts, writer);
}

pub fn format(
    db: Database,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = db;
    _ = options;
    _ = fmt;
    _ = writer;
}

pub fn toZig(db: Database, out_writer: anytype) !void {
    try gen.toZig(db, out_writer);
}

test "all" {
    @setEvalBranchQuota(2000);
    std.testing.refAllDeclsRecursive(svd);
    std.testing.refAllDeclsRecursive(atdf);
    std.testing.refAllDeclsRecursive(dslite);
    std.testing.refAllDeclsRecursive(gen);
}
