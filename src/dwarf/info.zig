//! DWARF .debug_info parser
//!
//! Parses compilation unit headers and DIEs to extract debug information.

const std = @import("std");
const types = @import("types.zig");
const abbrev = @import("abbrev.zig");

/// A parsed attribute value.
pub const AttrValue = union(enum) {
    address: u64,
    unsigned: u64,
    signed: i64,
    string: []const u8,
    reference: u64,
    block: []const u8,
    flag: bool,
};

/// A Debug Information Entry (DIE).
pub const Die = struct {
    offset: u64,
    tag: u16,
    has_children: bool,
    attrs: std.ArrayList(Attr),
    children: std.ArrayList(*Die),
    parent: ?*Die,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .offset = 0,
            .tag = 0,
            .has_children = false,
            .attrs = std.ArrayList(Attr).init(allocator),
            .children = std.ArrayList(*Die).init(allocator),
            .parent = null,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        // Recursively free children
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit();
        self.attrs.deinit();
    }

    /// Get attribute by name.
    pub fn getAttr(self: *const Self, name: u16) ?AttrValue {
        for (self.attrs.items) |attr| {
            if (attr.name == name) {
                return attr.value;
            }
        }
        return null;
    }

    /// Get string attribute.
    pub fn getString(self: *const Self, name: u16) ?[]const u8 {
        if (self.getAttr(name)) |val| {
            if (val == .string) {
                return val.string;
            }
        }
        return null;
    }

    /// Get address attribute.
    pub fn getAddress(self: *const Self, name: u16) ?u64 {
        if (self.getAttr(name)) |val| {
            if (val == .address) {
                return val.address;
            }
        }
        return null;
    }

    /// Get unsigned attribute.
    pub fn getUnsigned(self: *const Self, name: u16) ?u64 {
        if (self.getAttr(name)) |val| {
            switch (val) {
                .unsigned => |v| return v,
                .address => |v| return v,
                else => {},
            }
        }
        return null;
    }
};

/// An attribute name/value pair.
pub const Attr = struct {
    name: u16,
    value: AttrValue,
};

/// Compilation unit header.
pub const CompUnitHeader = struct {
    unit_length: u64,
    version: u16,
    abbrev_offset: u64,
    address_size: u8,
    is_64bit: bool,
};

/// A parsed compilation unit.
pub const CompUnit = struct {
    header: CompUnitHeader,
    root_die: *Die,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.root_die.deinit(self.allocator);
        self.allocator.destroy(self.root_die);
    }

    /// Find subprogram (function) by name.
    pub fn findFunction(self: *const Self, name: []const u8) ?*Die {
        return findDieByTagAndName(self.root_die, types.TAG.subprogram, name);
    }

    /// Find variable by name.
    pub fn findVariable(self: *const Self, name: []const u8) ?*Die {
        return findDieByTagAndName(self.root_die, types.TAG.variable, name);
    }
};

fn findDieByTagAndName(die: *Die, tag: u16, name: []const u8) ?*Die {
    if (die.tag == tag) {
        if (die.getString(types.AT.name)) |die_name| {
            if (std.mem.eql(u8, die_name, name)) {
                return die;
            }
        }
    }

    for (die.children.items) |child| {
        if (findDieByTagAndName(child, tag, name)) |found| {
            return found;
        }
    }

    return null;
}

/// Read unsigned LEB128.
fn readUleb128(data: []const u8, pos: *usize) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;

    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;

        result |= @as(u64, byte & 0x7f) << shift;

        if (byte & 0x80 == 0) {
            return result;
        }

        shift +%= 7;
        if (shift > 63) return error.Overflow;
    }

    return error.UnexpectedEndOfData;
}

/// Read signed LEB128.
fn readSleb128(data: []const u8, pos: *usize) !i64 {
    var result: i64 = 0;
    var shift: u6 = 0;

    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;

        result |= @as(i64, byte & 0x7f) << shift;
        shift +%= 7;

        if (byte & 0x80 == 0) {
            // Sign extend if negative
            if (shift < 64 and (byte & 0x40) != 0) {
                result |= @as(i64, -1) << shift;
            }
            return result;
        }

        if (shift > 63) return error.Overflow;
    }

    return error.UnexpectedEndOfData;
}

/// Read bytes from data.
fn readBytes(data: []const u8, pos: *usize, count: usize) ![]const u8 {
    if (pos.* + count > data.len) return error.UnexpectedEndOfData;
    const result = data[pos.* .. pos.* + count];
    pos.* += count;
    return result;
}

/// Read a u8.
fn readU8(data: []const u8, pos: *usize) !u8 {
    if (pos.* >= data.len) return error.UnexpectedEndOfData;
    const val = data[pos.*];
    pos.* += 1;
    return val;
}

/// Read a u16.
fn readU16(data: []const u8, pos: *usize) !u16 {
    const bytes = try readBytes(data, pos, 2);
    return std.mem.readInt(u16, bytes[0..2], .little);
}

/// Read a u32.
fn readU32(data: []const u8, pos: *usize) !u32 {
    const bytes = try readBytes(data, pos, 4);
    return std.mem.readInt(u32, bytes[0..4], .little);
}

/// Read a u64.
fn readU64(data: []const u8, pos: *usize) !u64 {
    const bytes = try readBytes(data, pos, 8);
    return std.mem.readInt(u64, bytes[0..8], .little);
}

/// Read null-terminated string.
fn readString(data: []const u8, pos: *usize) ![]const u8 {
    const start = pos.*;
    while (pos.* < data.len and data[pos.*] != 0) {
        pos.* += 1;
    }
    if (pos.* >= data.len) return error.UnexpectedEndOfData;
    const result = data[start..pos.*];
    pos.* += 1; // skip null terminator
    return result;
}

/// Parse compilation unit header.
pub fn parseCompUnitHeader(data: []const u8, pos: *usize) !CompUnitHeader {
    // Initial length (4 or 12 bytes for 64-bit)
    const initial_length = try readU32(data, pos);
    const is_64bit = initial_length == 0xffffffff;

    const unit_length: u64 = if (is_64bit)
        try readU64(data, pos)
    else
        initial_length;

    const version = try readU16(data, pos);

    // DWARF 5 has different header format
    var abbrev_offset: u64 = undefined;
    var address_size: u8 = undefined;

    if (version >= 5) {
        _ = try readU8(data, pos); // unit_type
        address_size = try readU8(data, pos);
        abbrev_offset = if (is_64bit)
            try readU64(data, pos)
        else
            try readU32(data, pos);
    } else {
        abbrev_offset = if (is_64bit)
            try readU64(data, pos)
        else
            try readU32(data, pos);
        address_size = try readU8(data, pos);
    }

    return CompUnitHeader{
        .unit_length = unit_length,
        .version = version,
        .abbrev_offset = abbrev_offset,
        .address_size = address_size,
        .is_64bit = is_64bit,
    };
}

/// Parse attribute value based on form.
fn parseAttrValue(
    data: []const u8,
    pos: *usize,
    form: u8,
    address_size: u8,
    is_64bit: bool,
    str_section: ?[]const u8,
) !AttrValue {
    return switch (form) {
        types.FORM.addr => .{ .address = if (address_size == 8)
            try readU64(data, pos)
        else
            try readU32(data, pos) },

        types.FORM.data1 => .{ .unsigned = try readU8(data, pos) },
        types.FORM.data2 => .{ .unsigned = try readU16(data, pos) },
        types.FORM.data4 => .{ .unsigned = try readU32(data, pos) },
        types.FORM.data8 => .{ .unsigned = try readU64(data, pos) },

        types.FORM.string => .{ .string = try readString(data, pos) },

        types.FORM.strp => blk: {
            const offset = if (is_64bit)
                try readU64(data, pos)
            else
                try readU32(data, pos);

            if (str_section) |str| {
                // Read null-terminated string from .debug_str
                var str_pos = @as(usize, @intCast(offset));
                const s = try readString(str, &str_pos);
                break :blk .{ .string = s };
            }
            break :blk .{ .unsigned = offset };
        },

        types.FORM.ref1 => .{ .reference = try readU8(data, pos) },
        types.FORM.ref2 => .{ .reference = try readU16(data, pos) },
        types.FORM.ref4 => .{ .reference = try readU32(data, pos) },
        types.FORM.ref8 => .{ .reference = try readU64(data, pos) },

        types.FORM.sec_offset => .{ .unsigned = if (is_64bit)
            try readU64(data, pos)
        else
            try readU32(data, pos) },

        types.FORM.exprloc => blk: {
            const length = try readUleb128(data, pos);
            break :blk .{ .block = try readBytes(data, pos, @intCast(length)) };
        },

        types.FORM.flag_present => .{ .flag = true },

        else => {
            // Skip unknown forms by reading as data4
            _ = try readU32(data, pos);
            return .{ .unsigned = 0 };
        },
    };
}

/// Parse a single DIE.
fn parseDie(
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: *usize,
    abbrev_table: *const abbrev.AbbrevTable,
    header: CompUnitHeader,
    str_section: ?[]const u8,
) !?*Die {
    const die_offset = pos.*;
    const abbrev_code = try readUleb128(data, pos);

    // Null DIE marks end of children
    if (abbrev_code == 0) {
        return null;
    }

    const abbr = abbrev_table.get(@intCast(abbrev_code)) orelse {
        return error.InvalidAbbrevCode;
    };

    const die = try allocator.create(Die);
    errdefer allocator.destroy(die);

    die.* = Die.init(allocator);
    die.offset = die_offset;
    die.tag = abbr.tag;
    die.has_children = abbr.has_children;

    // Parse attributes
    for (abbr.attrs) |attr_spec| {
        const value = try parseAttrValue(
            data,
            pos,
            attr_spec.form,
            header.address_size,
            header.is_64bit,
            str_section,
        );

        try die.attrs.append(allocator, Attr{
            .name = attr_spec.name,
            .value = value,
        });
    }

    // Parse children if any
    if (abbr.has_children) {
        while (true) {
            const child = try parseDie(
                allocator,
                data,
                pos,
                abbrev_table,
                header,
                str_section,
            ) orelse break;

            child.parent = die;
            try die.children.append(allocator, child);
        }
    }

    return die;
}

/// Parse a compilation unit.
pub fn parseCompUnit(
    allocator: std.mem.Allocator,
    info_data: []const u8,
    abbrev_data: []const u8,
    str_section: ?[]const u8,
) !CompUnit {
    var pos: usize = 0;
    const header = try parseCompUnitHeader(info_data, &pos);

    // Parse abbreviation table at the offset
    var abbrev_table = try abbrev.parseAbbrevSection(allocator, abbrev_data);
    defer abbrev_table.deinit();

    // Parse root DIE
    const root_die = try parseDie(
        allocator,
        info_data,
        &pos,
        &abbrev_table,
        header,
        str_section,
    ) orelse return error.EmptyCompilationUnit;

    return CompUnit{
        .header = header,
        .root_die = root_die,
        .allocator = allocator,
    };
}

// Tests

test "read leb128" {
    var pos: usize = 0;
    const data = [_]u8{ 0xe5, 0x8e, 0x26 };
    try std.testing.expectEqual(@as(u64, 624485), try readUleb128(&data, &pos));
}

test "read sleb128 positive" {
    var pos: usize = 0;
    const data = [_]u8{0x3f}; // 63
    try std.testing.expectEqual(@as(i64, 63), try readSleb128(&data, &pos));
}

test "read sleb128 negative" {
    var pos: usize = 0;
    const data = [_]u8{ 0xc1, 0x7f }; // -63
    try std.testing.expectEqual(@as(i64, -63), try readSleb128(&data, &pos));
}

test "parse comp unit header dwarf4" {
    // DWARF 4 header: length=11, version=4, abbrev=0, addr_size=8
    const data = [_]u8{
        0x0b, 0x00, 0x00, 0x00, // unit_length = 11
        0x04, 0x00, // version = 4
        0x00, 0x00, 0x00, 0x00, // abbrev_offset = 0
        0x08, // address_size = 8
    };

    var pos: usize = 0;
    const header = try parseCompUnitHeader(&data, &pos);

    try std.testing.expectEqual(@as(u64, 11), header.unit_length);
    try std.testing.expectEqual(@as(u16, 4), header.version);
    try std.testing.expectEqual(@as(u64, 0), header.abbrev_offset);
    try std.testing.expectEqual(@as(u8, 8), header.address_size);
    try std.testing.expect(!header.is_64bit);
}

test "die attribute access" {
    const allocator = std.testing.allocator;

    var die = Die.init(allocator);
    defer die.deinit(allocator);

    try die.attrs.append(allocator, Attr{
        .name = types.AT.name,
        .value = .{ .string = "main" },
    });

    try die.attrs.append(allocator, Attr{
        .name = types.AT.low_pc,
        .value = .{ .address = 0x1000 },
    });

    try std.testing.expectEqualStrings("main", die.getString(types.AT.name).?);
    try std.testing.expectEqual(@as(u64, 0x1000), die.getAddress(types.AT.low_pc).?);
    try std.testing.expect(die.getAttr(types.AT.high_pc) == null);
}
