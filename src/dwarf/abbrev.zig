//! DWARF abbreviation table parser
//!
//! Parses .debug_abbrev section to build a table mapping abbreviation
//! codes to their tag and attribute definitions.

const std = @import("std");
const types = @import("types.zig");

/// An attribute specification in an abbreviation.
pub const AttrSpec = struct {
    name: u16,
    form: u8,
};

/// An abbreviation entry.
pub const Abbrev = struct {
    code: u32,
    tag: u16,
    has_children: bool,
    attrs: []const AttrSpec,
};

/// Abbreviation table - maps codes to abbreviation entries.
pub const AbbrevTable = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(u32, Abbrev),
    attr_storage: std.ArrayList(AttrSpec),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .entries = std.AutoHashMap(u32, Abbrev).init(allocator),
            .attr_storage = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
        self.attr_storage.deinit(self.allocator);
    }

    /// Look up abbreviation by code.
    pub fn get(self: *const Self, code: u32) ?Abbrev {
        return self.entries.get(code);
    }

    /// Get the number of entries.
    pub fn count(self: *const Self) usize {
        return self.entries.count();
    }
};

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

/// Parse .debug_abbrev section into an abbreviation table.
pub fn parseAbbrevSection(allocator: std.mem.Allocator, data: []const u8) !AbbrevTable {
    var table = AbbrevTable.init(allocator);
    errdefer table.deinit();

    var pos: usize = 0;

    while (pos < data.len) {
        // Read abbreviation code
        const code = try readUleb128(data, &pos);
        if (code == 0) {
            // End of abbreviation set (could be multiple sets, we just parse first)
            break;
        }

        // Read tag
        const tag_raw = try readUleb128(data, &pos);
        const tag: u16 = @intCast(tag_raw);

        // Read children flag
        if (pos >= data.len) return error.UnexpectedEndOfData;
        const has_children = data[pos] != 0;
        pos += 1;

        // Read attribute specifications
        const attr_start = table.attr_storage.items.len;

        while (pos < data.len) {
            const attr_name = try readUleb128(data, &pos);
            const attr_form = try readUleb128(data, &pos);

            // (0, 0) terminates attribute list
            if (attr_name == 0 and attr_form == 0) {
                break;
            }

            try table.attr_storage.append(allocator, AttrSpec{
                .name = @intCast(attr_name),
                .form = @intCast(attr_form),
            });
        }

        const attr_end = table.attr_storage.items.len;

        // Add entry to table
        try table.entries.put(@intCast(code), Abbrev{
            .code = @intCast(code),
            .tag = tag,
            .has_children = has_children,
            .attrs = table.attr_storage.items[attr_start..attr_end],
        });
    }

    return table;
}

// Tests

test "read uleb128" {
    // 0x00 = 0
    var pos: usize = 0;
    const data1 = [_]u8{0x00};
    try std.testing.expectEqual(@as(u64, 0), try readUleb128(&data1, &pos));

    // 0x7f = 127
    pos = 0;
    const data2 = [_]u8{0x7f};
    try std.testing.expectEqual(@as(u64, 127), try readUleb128(&data2, &pos));

    // 0x80 0x01 = 128
    pos = 0;
    const data3 = [_]u8{ 0x80, 0x01 };
    try std.testing.expectEqual(@as(u64, 128), try readUleb128(&data3, &pos));

    // 0xe5 0x8e 0x26 = 624485
    pos = 0;
    const data4 = [_]u8{ 0xe5, 0x8e, 0x26 };
    try std.testing.expectEqual(@as(u64, 624485), try readUleb128(&data4, &pos));
}

test "parse empty abbrev section" {
    const allocator = std.testing.allocator;

    // Single null byte terminates
    const data = [_]u8{0x00};
    var table = try parseAbbrevSection(allocator, &data);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 0), table.count());
}

test "parse simple abbrev" {
    const allocator = std.testing.allocator;

    // Abbreviation 1: compile_unit with name attribute
    // Code: 1 (0x01)
    // Tag: compile_unit (0x11)
    // Children: yes (0x01)
    // Attr: name (0x03), strp (0x0e)
    // Attr: end (0x00, 0x00)
    // End of set (0x00)
    const data = [_]u8{
        0x01, // code = 1
        0x11, // tag = compile_unit
        0x01, // has_children = true
        0x03, // attr name = DW_AT_name
        0x0e, // attr form = DW_FORM_strp
        0x00, 0x00, // end of attrs
        0x00, // end of abbrev set
    };

    var table = try parseAbbrevSection(allocator, &data);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 1), table.count());

    const abbrev = table.get(1).?;
    try std.testing.expectEqual(@as(u32, 1), abbrev.code);
    try std.testing.expectEqual(@as(u16, types.TAG.compile_unit), abbrev.tag);
    try std.testing.expect(abbrev.has_children);
    try std.testing.expectEqual(@as(usize, 1), abbrev.attrs.len);
    try std.testing.expectEqual(@as(u16, types.AT.name), abbrev.attrs[0].name);
    try std.testing.expectEqual(@as(u8, types.FORM.strp), abbrev.attrs[0].form);
}

test "parse multiple abbrevs" {
    const allocator = std.testing.allocator;

    // Two abbreviations
    const data = [_]u8{
        // Abbrev 1: compile_unit, no children, one attr
        0x01, 0x11, 0x00, 0x03, 0x08, 0x00, 0x00,
        // Abbrev 2: subprogram, has children, two attrs
        0x02, 0x2e, 0x01, 0x03, 0x08, 0x11, 0x01, 0x00, 0x00,
        // End
        0x00,
    };

    var table = try parseAbbrevSection(allocator, &data);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 2), table.count());

    // Check abbrev 1
    const a1 = table.get(1).?;
    try std.testing.expectEqual(@as(u16, types.TAG.compile_unit), a1.tag);
    try std.testing.expect(!a1.has_children);
    try std.testing.expectEqual(@as(usize, 1), a1.attrs.len);

    // Check abbrev 2
    const a2 = table.get(2).?;
    try std.testing.expectEqual(@as(u16, types.TAG.subprogram), a2.tag);
    try std.testing.expect(a2.has_children);
    try std.testing.expectEqual(@as(usize, 2), a2.attrs.len);
}

test "abbrev lookup miss returns null" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0x01, 0x11, 0x00, 0x00, 0x00, 0x00 };

    var table = try parseAbbrevSection(allocator, &data);
    defer table.deinit();

    try std.testing.expect(table.get(1) != null);
    try std.testing.expect(table.get(99) == null);
}
