const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

const xml = @import("xml.zig");
const Database = @import("Database.zig");
const EntityId = Database.EntityId;

const log = std.log.scoped(.svd);

// svd specific context to hold extra state like derived entities
const Context = struct {
    db: *Database,
    derived_entities: std.AutoArrayHashMap(EntityId, []const u8),

    fn deinit(ctx: *Context) void {
        ctx.derived_entities.deinit();
    }
};

pub fn loadIntoDb(db: *Database, doc: xml.Doc) !void {
    const root = try doc.getRootElement();

    const device_id = db.createEntity();
    try db.instances.devices.put(db.gpa, device_id, .{});

    const name = root.getValue("name") orelse return error.MissingDeviceName;
    try db.addName(device_id, name);

    if (root.getValue("description")) |description|
        try db.addDescription(device_id, description);

    if (root.getValue("licenseText")) |license|
        try db.addDeviceProperty(device_id, "license", license);

    // vendor
    // vendorID
    // series
    // version
    // licenseText
    // headerSystemFilename
    // headerDefinitionPrefix
    // addressUnitBits
    // width
    // registerPropertiesGroup
    // peripherals
    // vendorExtensions

    var cpu_it = root.iterate(&.{}, "cpu");
    if (cpu_it.next()) |cpu| {
        const cpu_name = cpu.getValue("name") orelse return error.MissingCpuName;
        const cpu_revision = cpu.getValue("revision") orelse return error.MissingCpuRevision;
        const nvic_prio_bits = cpu.getValue("nvicPrioBits") orelse return error.MissingNvicPrioBits;
        const vendor_systick_config = cpu.getValue("vendorSystickConfig") orelse return error.MissingVendorSystickConfig;

        try db.addDeviceProperty(device_id, "arch", cpu_name);
        try db.addDeviceProperty(device_id, "cpu.revision", cpu_revision);
        try db.addDeviceProperty(device_id, "cpu.nvic_prio_bits", nvic_prio_bits);
        try db.addDeviceProperty(device_id, "cpu.vendor_systick_config", vendor_systick_config);

        if (cpu.getValue("endian")) |endian|
            try db.addDeviceProperty(device_id, "cpu.endian", endian);

        if (cpu.getValue("mpuPresent")) |mpu|
            try db.addDeviceProperty(device_id, "cpu.mpu", mpu);

        if (cpu.getValue("fpuPresent")) |fpu|
            try db.addDeviceProperty(device_id, "cpu.fpu", fpu);

        if (cpu.getValue("dspPresent")) |dsp|
            try db.addDeviceProperty(device_id, "cpu.dsp", dsp);

        if (cpu.getValue("icachePresent")) |icache|
            try db.addDeviceProperty(device_id, "cpu.icache", icache);

        if (cpu.getValue("dcachePresent")) |dcache|
            try db.addDeviceProperty(device_id, "cpu.dcache", dcache);

        if (cpu.getValue("itcmPresent")) |itcm|
            try db.addDeviceProperty(device_id, "cpu.itcm", itcm);

        if (cpu.getValue("dtcmPresent")) |dtcm|
            try db.addDeviceProperty(device_id, "cpu.dtcm", dtcm);

        if (cpu.getValue("vtorPresent")) |vtor|
            try db.addDeviceProperty(device_id, "cpu.vtor", vtor);

        if (cpu.getValue("deviceNumInterrupts")) |num_interrupts|
            try db.addDeviceProperty(device_id, "cpu.num_interrupts", num_interrupts);

        // fpuDP
        // sauNumRegions
        // sauRegionsConfig
    }

    if (cpu_it.next() != null)
        log.warn("there are multiple CPUs", .{});

    var ctx = Context{
        .db = db,
    };

    var peripheral_it = root.iterate(&.{"peripherals"}, "peripheral");
    while (peripheral_it.next()) |peripheral_node|
        try loadPeripheral(&ctx, peripheral_node);

    db.assertValid();
}

pub fn loadPeripheral(ctx: *Context, node: xml.Node) !void {
    const db = ctx.db;
    _ = db;
    _ = node;

    // dimElementGroup
    // name
    // version
    // description
    // alternatePeripheral
    // groupName
    // prependToName
    // appendToName
    // headerStructName
    // disableCondition
    // baseAddress
    // registerPropertiesGroup
    // addressBlock
    // interrupt
    // registers
    //
    // attribute: derivedFrom
}

pub const Revision = struct {
    release: u64,
    part: u64,

    fn parse(str: []const u8) !Revision {
        if (!std.mem.startsWith(u8, str, "r"))
            return error.Malformed;

        const p_index = std.mem.indexOf(u8, str, "p") orelse return error.Malformed;
        return Revision{
            .release = try std.fmt.parseInt(u64, str[1..p_index], 10),
            .part = try std.fmt.parseInt(u64, str[p_index + 1 ..], 10),
        };
    }
};

pub const Endian = enum { little, big, selectable, other };

pub const DataType = enum {
    uint8_t,
    uint16_t,
    uint32_t,
    uint64_t,
    int8_t,
    int16_t,
    int32_t,
    int64_t,
    @"uint8_t *",
    @"uint16_t *",
    @"uint32_t *",
    @"uint64_t *",
    @"int8_t *",
    @"int16_t *",
    @"int32_t *",
    @"int64_t *",
};

/// pattern: ((%s)|(%s)[_A-Za-z]{1}[_A-Za-z0-9]*)|([_A-Za-z]{1}[_A-Za-z0-9]*(\[%s\])?)|([_A-Za-z]{1}[_A-Za-z0-9]*(%s)?[_A-Za-z0-9]*)
///
/// The dimable identifier optionally has a %s to format where the id should
/// go, it may also be surrounded by []
pub const DimableIdentifier = struct {
    name: []const u8,
    pos: u32,
};

/// pattern: [0-9]+\-[0-9]+|[A-Z]-[A-Z]|[_0-9a-zA-Z]+(,\s*[_0-9a-zA-Z]+)+
pub const DimIndex = struct {};

const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;

test "Revision.parse" {
    try expectEqual(Revision{
        .release = 1,
        .part = 2,
    }, try Revision.parse("r1p2"));

    try expectEqual(Revision{
        .release = 50,
        .part = 100,
    }, try Revision.parse("r50p100"));

    try expectError(error.Malformed, Revision.parse("p"));
    try expectError(error.Malformed, Revision.parse("r"));
    try expectError(error.InvalidCharacter, Revision.parse("rp"));
    try expectError(error.InvalidCharacter, Revision.parse("r1p"));
    try expectError(error.InvalidCharacter, Revision.parse("rp2"));
}

//pub const Device = struct {
//    vendor: ?[]const u8 = null,
//    vendor_id: ?[]const u8 = null,
//    name: ?[]const u8 = null,
//    series: ?[]const u8 = null,
//    version: ?[]const u8 = null,
//    description: ?[]const u8 = null,
//    license_text: ?[]const u8 = null,
//    address_unit_bits: usize,
//    width: u16,
//    register_properties: struct {
//        size: ?u16 = null,
//        access: ?Access = null,
//        protection: ?[]const u8 = null,
//        reset_value: ?u64 = null,
//        reset_mask: ?u64 = null,
//    },
//
//    pub fn parse(arena: *ArenaAllocator, nodes: *xml.Node) !Device {
//        const allocator = arena.allocator();
//        return Device{
//            .vendor = if (xml.findValueForKey(nodes, "vendor")) |str| try allocator.dupe(u8, str) else null,
//            .vendor_id = if (xml.findValueForKey(nodes, "vendorID")) |str| try allocator.dupe(u8, str) else null,
//            .name = if (xml.findValueForKey(nodes, "name")) |name| try allocator.dupe(u8, name) else null,
//            .series = if (xml.findValueForKey(nodes, "series")) |str| try allocator.dupe(u8, str) else null,
//            .version = if (xml.findValueForKey(nodes, "version")) |str| try allocator.dupe(u8, str) else null,
//            .description = if (xml.findValueForKey(nodes, "description")) |str| try allocator.dupe(u8, str) else null,
//            .license_text = if (xml.findValueForKey(nodes, "licenseText")) |str| try allocator.dupe(u8, str) else null,
//            .address_unit_bits = try std.fmt.parseInt(usize, xml.findValueForKey(nodes, "addressUnitBits") orelse return error.NoAddressUnitBits, 0),
//            .width = try std.fmt.parseInt(u16, xml.findValueForKey(nodes, "width") orelse return error.NoDeviceWidth, 0),
//            .register_properties = .{
//                // register properties group
//                .size = if (xml.findValueForKey(nodes, "size")) |size_str|
//                    try std.fmt.parseInt(u16, size_str, 0)
//                else
//                    null,
//                .access = if (xml.findValueForKey(nodes, "access")) |access_str|
//                    try Access.parse(access_str)
//                else
//                    null,
//                .protection = if (xml.findValueForKey(nodes, "protection")) |str| try allocator.dupe(u8, str) else null,
//                .reset_value = if (xml.findValueForKey(nodes, "resetValue")) |size_str|
//                    try std.fmt.parseInt(u64, size_str, 0)
//                else
//                    null,
//                .reset_mask = if (xml.findValueForKey(nodes, "resetMask")) |size_str|
//                    try std.fmt.parseInt(u64, size_str, 0)
//                else
//                    null,
//            },
//        };
//    }
//};
//
//pub const CpuName = enum {
//    cortex_m0,
//    cortex_m0plus,
//    cortex_m1,
//    sc000, // kindof like an m3
//    cortex_m23,
//    cortex_m3,
//    cortex_m33,
//    cortex_m35p,
//    cortex_m55,
//    sc300,
//    cortex_m4,
//    cortex_m7,
//    arm_v8_mml,
//    arm_v8_mbl,
//    arm_v81_mml,
//    cortex_a5,
//    cortex_a7,
//    cortex_a8,
//    cortex_a9,
//    cortex_a15,
//    cortex_a17,
//    cortex_a53,
//    cortex_a57,
//    cortex_a72,
//
//    // avr
//    avr,
//    other,
//
//    // TODO: finish
//    pub fn parse(str: []const u8) ?CpuName {
//        return if (std.mem.eql(u8, "CM0", str))
//            CpuName.cortex_m0
//        else if (std.mem.eql(u8, "CM0PLUS", str))
//            CpuName.cortex_m0plus
//        else if (std.mem.eql(u8, "CM0+", str))
//            CpuName.cortex_m0plus
//        else if (std.mem.eql(u8, "CM1", str))
//            CpuName.cortex_m1
//        else if (std.mem.eql(u8, "SC000", str))
//            CpuName.sc000
//        else if (std.mem.eql(u8, "CM23", str))
//            CpuName.cortex_m23
//        else if (std.mem.eql(u8, "CM3", str))
//            CpuName.cortex_m3
//        else if (std.mem.eql(u8, "CM33", str))
//            CpuName.cortex_m33
//        else if (std.mem.eql(u8, "CM35P", str))
//            CpuName.cortex_m35p
//        else if (std.mem.eql(u8, "CM55", str))
//            CpuName.cortex_m55
//        else if (std.mem.eql(u8, "SC300", str))
//            CpuName.sc300
//        else if (std.mem.eql(u8, "CM4", str))
//            CpuName.cortex_m4
//        else if (std.mem.eql(u8, "CM7", str))
//            CpuName.cortex_m7
//        else if (std.mem.eql(u8, "AVR8", str))
//            CpuName.avr
//        else
//            null;
//    }
//};
//
//pub const Endian = enum {
//    little,
//    big,
//    selectable,
//    other,
//
//    pub fn parse(str: []const u8) !Endian {
//        return if (std.meta.stringToEnum(Endian, str)) |val|
//            val
//        else
//            error.UnknownEndianType;
//    }
//};
//
//pub const Cpu = struct {
//    //name: ?CpuName,
//    name: ?[]const u8,
//    revision: []const u8,
//    endian: Endian,
//    mpu_present: bool,
//    //fpu_present: bool,
//    //fpu_dp: bool,
//    //dsp_present: bool,
//    //icache_present: bool,
//    //dcache_present: bool,
//    //itcm_present: bool,
//    //dtcm_present: bool,
//    vtor_present: bool,
//    nvic_prio_bits: u8,
//    vendor_systick_config: bool,
//    device_num_interrupts: ?usize,
//    //sau_num_regions: usize,
//
//    pub fn parse(arena: *ArenaAllocator, nodes: *xml.Node) !Cpu {
//        return Cpu{
//            .name = if (xml.findValueForKey(nodes, "name")) |name| try arena.allocator().dupe(u8, name) else null,
//            .revision = xml.findValueForKey(nodes, "revision") orelse unreachable,
//            .endian = try Endian.parse(xml.findValueForKey(nodes, "endian") orelse unreachable),
//            .nvic_prio_bits = if (xml.findValueForKey(nodes, "nvicPrioBits")) |nvic_prio_bits|
//                try std.fmt.parseInt(u8, nvic_prio_bits, 0)
//            else
//                0,
//            // TODO: booleans
//            .vendor_systick_config = (try xml.parseBoolean(arena.child_allocator, nodes, "vendorSystickConfig")) orelse false,
//            .device_num_interrupts = if (xml.findValueForKey(nodes, "deviceNumInterrupts")) |size_str|
//                try std.fmt.parseInt(usize, size_str, 0)
//            else
//                null,
//            .vtor_present = (try xml.parseBoolean(arena.child_allocator, nodes, "vtorPresent")) orelse false,
//            .mpu_present = (try xml.parseBoolean(arena.child_allocator, nodes, "mpuPresent")) orelse false,
//        };
//    }
//};
//
//pub const Access = enum {
//    read_only,
//    write_only,
//    read_write,
//    writeonce,
//    read_writeonce,
//
//    pub fn parse(str: []const u8) !Access {
//        return if (std.mem.eql(u8, "read-only", str))
//            Access.read_only
//        else if (std.mem.eql(u8, "write-only", str))
//            Access.write_only
//        else if (std.mem.eql(u8, "read-write", str))
//            Access.read_write
//        else if (std.mem.eql(u8, "writeOnce", str))
//            Access.writeonce
//        else if (std.mem.eql(u8, "read-writeOnce", str))
//            Access.read_writeonce
//        else
//            error.UnknownAccessType;
//    }
//};
//
//pub fn parsePeripheral(arena: *ArenaAllocator, nodes: *xml.Node) !Peripheral {
//    const allocator = arena.allocator();
//    return Peripheral{
//        .name = try allocator.dupe(u8, xml.findValueForKey(nodes, "name") orelse return error.NoName),
//        .version = if (xml.findValueForKey(nodes, "version")) |version|
//            try allocator.dupe(u8, version)
//        else
//            null,
//        .description = try xml.parseDescription(allocator, nodes, "description"),
//        .base_addr = (try xml.parseIntForKey(usize, arena.child_allocator, nodes, "baseAddress")) orelse return error.NoBaseAddr, // isDefault?
//    };
//}
//
//pub const Interrupt = struct {
//    name: []const u8,
//    description: ?[]const u8,
//    value: usize,
//
//    pub fn parse(arena: *ArenaAllocator, nodes: *xml.Node) !Interrupt {
//        const allocator = arena.allocator();
//        return Interrupt{
//            .name = try allocator.dupe(u8, xml.findValueForKey(nodes, "name") orelse return error.NoName),
//            .description = try xml.parseDescription(allocator, nodes, "description"),
//            .value = try std.fmt.parseInt(usize, xml.findValueForKey(nodes, "value") orelse return error.NoValue, 0),
//        };
//    }
//
//    pub fn lessThan(_: void, lhs: Interrupt, rhs: Interrupt) bool {
//        return lhs.value < rhs.value;
//    }
//
//    pub fn compare(_: void, lhs: Interrupt, rhs: Interrupt) std.math.Order {
//        return if (lhs.value < rhs.value)
//            std.math.Order.lt
//        else if (lhs.value == rhs.value)
//            std.math.Order.eq
//        else
//            std.math.Order.gt;
//    }
//};
//
//pub fn parseRegister(arena: *ArenaAllocator, nodes: *xml.Node) !Register {
//    const allocator = arena.allocator();
//    return Register{
//        .name = try allocator.dupe(u8, xml.findValueForKey(nodes, "name") orelse return error.NoName),
//        .description = try xml.parseDescription(allocator, nodes, "description"),
//        .addr_offset = try std.fmt.parseInt(usize, xml.findValueForKey(nodes, "addressOffset") orelse return error.NoAddrOffset, 0),
//        .size = null,
//        .access = .read_write,
//        .reset_value = if (xml.findValueForKey(nodes, "resetValue")) |value|
//            try std.fmt.parseInt(u64, value, 0)
//        else
//            null,
//        .reset_mask = if (xml.findValueForKey(nodes, "resetMask")) |value|
//            try std.fmt.parseInt(u64, value, 0)
//        else
//            null,
//    };
//}
//
//pub const Cluster = struct {
//    name: []const u8,
//    description: ?[]const u8,
//    addr_offset: usize,
//
//    pub fn parse(arena: *ArenaAllocator, nodes: *xml.Node) !Cluster {
//        const allocator = arena.allocator();
//        return Cluster{
//            .name = try allocator.dupe(u8, xml.findValueForKey(nodes, "name") orelse return error.NoName),
//            .description = try xml.parseDescription(allocator, nodes, "description"),
//            .addr_offset = try std.fmt.parseInt(usize, xml.findValueForKey(nodes, "addressOffset") orelse return error.NoAddrOffset, 0),
//        };
//    }
//};
//
//const BitRange = struct {
//    offset: u8,
//    width: u8,
//};
//
//pub fn parseField(arena: *ArenaAllocator, nodes: *xml.Node) !Field {
//    const allocator = arena.allocator();
//    // TODO:
//    const bit_range = blk: {
//        const lsb_opt = xml.findValueForKey(nodes, "lsb");
//        const msb_opt = xml.findValueForKey(nodes, "msb");
//        if (lsb_opt != null and msb_opt != null) {
//            const lsb = try std.fmt.parseInt(u8, lsb_opt.?, 0);
//            const msb = try std.fmt.parseInt(u8, msb_opt.?, 0);
//
//            if (msb < lsb)
//                return error.InvalidRange;
//
//            break :blk BitRange{
//                .offset = lsb,
//                .width = msb - lsb + 1,
//            };
//        }
//
//        const bit_offset_opt = xml.findValueForKey(nodes, "bitOffset");
//        const bit_width_opt = xml.findValueForKey(nodes, "bitWidth");
//        if (bit_offset_opt != null and bit_width_opt != null) {
//            const offset = try std.fmt.parseInt(u8, bit_offset_opt.?, 0);
//            const width = try std.fmt.parseInt(u8, bit_width_opt.?, 0);
//
//            break :blk BitRange{
//                .offset = offset,
//                .width = width,
//            };
//        }
//
//        const bit_range_opt = xml.findValueForKey(nodes, "bitRange");
//        if (bit_range_opt) |bit_range_str| {
//            var it = std.mem.tokenize(u8, bit_range_str, "[:]");
//            const msb = try std.fmt.parseInt(u8, it.next() orelse return error.NoMsb, 0);
//            const lsb = try std.fmt.parseInt(u8, it.next() orelse return error.NoLsb, 0);
//
//            if (msb < lsb)
//                return error.InvalidRange;
//
//            break :blk BitRange{
//                .offset = lsb,
//                .width = msb - lsb + 1,
//            };
//        }
//
//        return error.InvalidRange;
//    };
//
//    return Field{
//        .name = try allocator.dupe(u8, xml.findValueForKey(nodes, "name") orelse return error.NoName),
//        .offset = bit_range.offset,
//        .width = bit_range.width,
//        .description = try xml.parseDescription(allocator, nodes, "description"),
//        .access = if (xml.findValueForKey(nodes, "access")) |access_str|
//            try Access.parse(access_str)
//        else
//            null,
//    };
//}
//
//pub const EnumeratedValue = struct {
//    name: []const u8,
//    description: ?[]const u8,
//    value: ?usize,
//
//    pub fn parse(arena: *ArenaAllocator, nodes: *xml.Node) !EnumeratedValue {
//        const allocator = arena.allocator();
//        return EnumeratedValue{
//            .name = try allocator.dupe(u8, xml.findValueForKey(nodes, "name") orelse return error.NoName),
//            .description = try xml.parseDescription(allocator, nodes, "description"),
//            .value = try xml.parseIntForKey(usize, arena.child_allocator, nodes, "value"), // TODO: isDefault?
//        };
//    }
//};
//
//pub const Dimension = struct {
//    dim: usize,
//    increment: usize,
//    /// a range of 0-index, only index is recorded
//    index: ?Index,
//    name: ?[]const u8,
//    //array_index: ,
//
//    const Index = union(enum) {
//        num: usize,
//        list: std.ArrayList([]const u8),
//    };
//
//    pub fn parse(arena: *ArenaAllocator, nodes: *xml.Node) !?Dimension {
//        const allocator = arena.allocator();
//        return Dimension{
//            .dim = (try xml.parseIntForKey(usize, arena.child_allocator, nodes, "dim")) orelse return null,
//            .increment = (try xml.parseIntForKey(usize, arena.child_allocator, nodes, "dimIncrement")) orelse return null,
//            .index = if (xml.findValueForKey(nodes, "dimIndex")) |index_str|
//                if (std.mem.indexOf(u8, index_str, ",") != null) blk: {
//                    var list = std.ArrayList([]const u8).init(allocator);
//                    var it = std.mem.tokenize(u8, index_str, ",");
//                    var expected: usize = 0;
//                    while (it.next()) |token| : (expected += 1)
//                        try list.append(try allocator.dupe(u8, token));
//
//                    break :blk Index{
//                        .list = list,
//                    };
//                } else blk: {
//                    var it = std.mem.tokenize(u8, index_str, "-");
//                    const begin = try std.fmt.parseInt(usize, it.next() orelse return error.InvalidDimIndex, 10);
//                    const end = try std.fmt.parseInt(usize, it.next() orelse return error.InvalidDimIndex, 10);
//
//                    if (begin == 0)
//                        break :blk Index{
//                            .num = end + 1,
//                        };
//
//                    var list = std.ArrayList([]const u8).init(allocator);
//                    var i = begin;
//                    while (i <= end) : (i += 1)
//                        try list.append(try std.fmt.allocPrint(allocator, "{}", .{i}));
//
//                    break :blk Index{
//                        .list = list,
//                    };
//                }
//            else
//                null,
//            .name = if (xml.findValueForKey(nodes, "dimName")) |name_str|
//                try allocator.dupe(u8, name_str)
//            else
//                null,
//        };
//    }
//};
//
//pub const RegisterProperties = struct {
//    size: ?u16,
//    access: ?Access,
//    reset_value: ?u64,
//    reset_mask: ?u64,
//
//    pub fn parse(arena: *ArenaAllocator, nodes: *xml.Node) !RegisterProperties {
//        return RegisterProperties{
//            .size = try xml.parseIntForKey(u16, arena.child_allocator, nodes, "size"),
//            .reset_value = try xml.parseIntForKey(u64, arena.child_allocator, nodes, "resetValue"),
//            .reset_mask = try xml.parseIntForKey(u64, arena.child_allocator, nodes, "resetMask"),
//            .access = if (xml.findValueForKey(nodes, "access")) |access_str|
//                try Access.parse(access_str)
//            else
//                null,
//        };
//    }
//};
