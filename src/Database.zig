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

pub const EntityId = u32;
pub const InterruptIndex = u32;
pub const EntitySet = ArrayHashMap(EntityId, void);

pub const Access = enum {
    read_only,
    write_only,
    read_write,
};

/// an interrupt has a numeric index
pub const Interrupt = i32;

/// an enum is a set of enum fields
pub const Enum = EntitySet;

pub const Device = struct {
    properties: std.StringHashMapUnmanaged([]const u8) = .{},
    interrupts: EntitySet = .{},

    pub fn deinit(self: *Device, gpa: Allocator) void {
        self.properties.deinit(gpa);
        self.interrupts.deinit(gpa);
    }
};

/// a peripheral is a set of registers and register groups
pub const Peripheral = struct {
    registers: EntitySet = .{},
    register_groups: EntitySet = .{},
    modes: EntitySet = .{},

    pub fn deinit(self: *Peripheral, gpa: Allocator) void {
        self.registers.deinit(gpa);
        self.register_groups.deinit(gpa);
        self.modes.deinit(gpa);
    }
};

/// a register is a set of fields
pub const Register = struct {
    fields: EntitySet = .{},
    modes: EntitySet = .{},

    pub fn deinit(self: *Register, gpa: Allocator) void {
        self.fields.deinit(gpa);
        self.modes.deinit(gpa);
    }
};

/// a register group is a set of registers and nested register groups
pub const RegisterGroup = struct {
    registers: EntitySet = .{},
    register_groups: EntitySet = .{},
    modes: EntitySet = .{},

    pub fn deinit(self: *RegisterGroup, gpa: Allocator) void {
        self.registers.deinit(gpa);
        self.register_groups.deinit(gpa);
        self.modes.deinit(gpa);
    }
};

/// Field offset is in `offsets` table, width is in `sizes` table. If it has modes
pub const Field = void;

pub const Mode = struct {
    qualifier: []const u8,
    value: []const u8,
};

/// a collection of modes that applies to a register or bitfield
pub const Modes = EntitySet;

/// a peripheral instance has an associated peripheral type, and register and register group instances
pub const PeripheralInstance = struct {
    type_id: EntityId,
    // TODO: be more specific
    children: EntitySet = .{},

    pub fn deinit(self: *PeripheralInstance, gpa: Allocator) void {
        self.children.deinit(gpa);
    }
};

gpa: Allocator,
arena: ArenaAllocator,
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
} = .{},

types: struct {
    peripherals: ArrayHashMap(EntityId, Peripheral) = .{},
    register_groups: ArrayHashMap(EntityId, RegisterGroup) = .{},
    registers: ArrayHashMap(EntityId, Register) = .{},
    fields: ArrayHashMap(EntityId, Field) = .{},
    enums: ArrayHashMap(EntityId, Enum) = .{},
    enum_fields: ArrayHashMap(EntityId, u64) = .{},

    // atdf has modes which make registers into unions
    modes: ArrayHashMap(EntityId, Mode) = .{},
} = .{},

instances: struct {
    devices: ArrayHashMap(EntityId, Device) = .{},
    interrupts: ArrayHashMap(EntityId, Interrupt) = .{},
    peripherals: ArrayHashMap(EntityId, PeripheralInstance) = .{},
    register_groups: ArrayHashMap(EntityId, EntityId) = .{},
    registers: ArrayHashMap(EntityId, EntityId) = .{},
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
    db.attrs.modes.deinit(db.gpa);

    // types
    deinitMapAndValues(db.gpa, &db.types.peripherals);
    deinitMapAndValues(db.gpa, &db.types.register_groups);
    deinitMapAndValues(db.gpa, &db.types.registers);
    db.types.fields.deinit(db.gpa);
    deinitMapAndValues(db.gpa, &db.types.enums);
    db.types.enum_fields.deinit(db.gpa);
    db.types.modes.deinit(db.gpa);

    // instances
    db.instances.interrupts.deinit(db.gpa);
    db.instances.register_groups.deinit(db.gpa);
    db.instances.registers.deinit(db.gpa);

    {
        var it = db.instances.devices.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.interrupts.deinit(db.gpa);
            entry.value_ptr.properties.deinit(db.gpa);
        }
    }
    db.instances.devices.deinit(db.gpa);

    {
        var it = db.instances.peripherals.iterator();
        while (it.next()) |entry|
            entry.value_ptr.children.deinit(db.gpa);
    }
    db.instances.peripherals.deinit(db.gpa);

    // indexes

    db.arena.deinit();
}

pub fn init(allocator: std.mem.Allocator) Database {
    return Database{
        .gpa = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .next_entity_id = 0,
    };
}

// TODO: figure out how to do completions: bash, zsh, fish, powershell, cmd
pub fn initFromAtdf(allocator: Allocator, doc: xml.Doc) !Database {
    var db = Database.init(allocator);
    errdefer db.deinit();

    try atdf.loadIntoDb(&db, doc);
    return db;
}

pub fn initFromSvd(allocator: Allocator, doc: xml.Doc) !Database {
    var db = Database.init(allocator);
    errdefer db.deinit();

    try svd.loadIntoDb(&db, doc);
    return db;
}

pub fn initFromDslite(allocator: Allocator, doc: xml.Doc) !Database {
    var db = Database.init(allocator);
    errdefer db.deinit();

    try dslite.loadIntoDb(&db, doc);
    return db;
}

pub fn initFromJson(allocator: Allocator, reader: anytype) !Database {
    var db = Database.init(allocator);
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

    std.log.debug("{}: adding name: {s}", .{ id, name });
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

    std.log.debug("{}: adding description: {s}", .{ id, description });
    try db.attrs.descriptions.putNoClobber(
        db.gpa,
        id,
        try db.arena.allocator().dupe(u8, description),
    );
}

pub fn addSize(db: *Database, id: EntityId, size: u64) !void {
    std.log.debug("{}: adding size: {}", .{ id, size });
    try db.attrs.sizes.putNoClobber(db.gpa, id, size);
}

pub fn addOffset(db: *Database, id: EntityId, offset: u64) !void {
    std.log.debug("{}: adding offset: {}", .{ id, offset });
    try db.attrs.offsets.putNoClobber(db.gpa, id, offset);
}

pub fn addDeviceProperty(
    db: *Database,
    id: EntityId,
    key: []const u8,
    value: []const u8,
) !void {
    std.log.debug("{}: adding device attr: {s}={s}", .{ id, key, value });
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

pub fn toZig(db: *Database, out_writer: anytype) !void {
    try gen.toZig(db, out_writer);
}

test "all" {
    @setEvalBranchQuota(2000);
    std.testing.refAllDeclsRecursive(svd);
    std.testing.refAllDeclsRecursive(atdf);
    std.testing.refAllDeclsRecursive(dslite);
    std.testing.refAllDeclsRecursive(gen);
}
