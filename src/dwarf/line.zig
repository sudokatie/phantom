//! DWARF line number program parser
//!
//! Parses .debug_line section to build address <-> source line mappings.

const std = @import("std");
const types = @import("types.zig");

/// A source location.
pub const SourceLocation = struct {
    file: u32,
    line: u32,
    column: u32,
    address: u64,
    is_stmt: bool,
    end_sequence: bool,
};

/// Line number program header.
pub const LineHeader = struct {
    unit_length: u64,
    version: u16,
    header_length: u64,
    min_instruction_length: u8,
    max_ops_per_instruction: u8,
    default_is_stmt: bool,
    line_base: i8,
    line_range: u8,
    opcode_base: u8,
    std_opcode_lengths: []const u8,
    include_directories: []const []const u8,
    file_names: []const FileName,
    is_64bit: bool,
};

/// File name entry.
pub const FileName = struct {
    name: []const u8,
    dir_index: u32,
    mod_time: u64,
    file_size: u64,
};

/// Line number table.
pub const LineTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(SourceLocation),
    files: std.ArrayList(FileName),
    directories: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .entries = .empty,
            .files = .empty,
            .directories = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit(self.allocator);
        self.files.deinit(self.allocator);
        self.directories.deinit(self.allocator);
    }

    /// Get source location for an address.
    pub fn locationForAddress(self: *const Self, address: u64) ?SourceLocation {
        var best: ?SourceLocation = null;

        for (self.entries.items) |entry| {
            if (entry.address <= address) {
                if (best == null or entry.address > best.?.address) {
                    best = entry;
                }
            }
        }

        return best;
    }

    /// Get address for a source line.
    pub fn addressForLine(self: *const Self, file: u32, line: u32) ?u64 {
        for (self.entries.items) |entry| {
            if (entry.file == file and entry.line == line) {
                return entry.address;
            }
        }
        return null;
    }

    /// Get file name.
    pub fn getFileName(self: *const Self, index: u32) ?[]const u8 {
        if (index == 0) return null;
        const idx = index - 1; // file indices are 1-based
        if (idx >= self.files.items.len) return null;
        return self.files.items[idx].name;
    }
};

// Helper functions

fn readUleb128(data: []const u8, pos: *usize) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;

    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift +%= 7;
        if (shift > 63) return error.Overflow;
    }
    return error.UnexpectedEndOfData;
}

fn readSleb128(data: []const u8, pos: *usize) !i64 {
    var result: i64 = 0;
    var shift: u6 = 0;

    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        result |= @as(i64, byte & 0x7f) << shift;
        shift +%= 7;
        if (byte & 0x80 == 0) {
            if (shift < 64 and (byte & 0x40) != 0) {
                result |= @as(i64, -1) << shift;
            }
            return result;
        }
        if (shift > 63) return error.Overflow;
    }
    return error.UnexpectedEndOfData;
}

fn readU8(data: []const u8, pos: *usize) !u8 {
    if (pos.* >= data.len) return error.UnexpectedEndOfData;
    const val = data[pos.*];
    pos.* += 1;
    return val;
}

fn readU16(data: []const u8, pos: *usize) !u16 {
    if (pos.* + 2 > data.len) return error.UnexpectedEndOfData;
    const val = std.mem.readInt(u16, data[pos.*..][0..2], .little);
    pos.* += 2;
    return val;
}

fn readU32(data: []const u8, pos: *usize) !u32 {
    if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
    const val = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return val;
}

fn readU64(data: []const u8, pos: *usize) !u64 {
    if (pos.* + 8 > data.len) return error.UnexpectedEndOfData;
    const val = std.mem.readInt(u64, data[pos.*..][0..8], .little);
    pos.* += 8;
    return val;
}

fn readString(data: []const u8, pos: *usize) ![]const u8 {
    const start = pos.*;
    while (pos.* < data.len and data[pos.*] != 0) {
        pos.* += 1;
    }
    if (pos.* >= data.len) return error.UnexpectedEndOfData;
    const result = data[start..pos.*];
    pos.* += 1;
    return result;
}

/// Line number state machine state.
const LineState = struct {
    address: u64 = 0,
    op_index: u32 = 0,
    file: u32 = 1,
    line: u32 = 1,
    column: u32 = 0,
    is_stmt: bool = true,
    basic_block: bool = false,
    end_sequence: bool = false,
    prologue_end: bool = false,
    epilogue_begin: bool = false,
    isa: u32 = 0,
    discriminator: u32 = 0,

    fn reset(self: *LineState, default_is_stmt: bool) void {
        self.* = LineState{
            .is_stmt = default_is_stmt,
        };
    }
};

/// Parse line number program and build table.
pub fn parseLineProgram(allocator: std.mem.Allocator, data: []const u8) !LineTable {
    var table = LineTable.init(allocator);
    errdefer table.deinit();

    var pos: usize = 0;

    // Parse header
    const initial_length = try readU32(data, &pos);
    const is_64bit = initial_length == 0xffffffff;
    const unit_length: u64 = if (is_64bit) try readU64(data, &pos) else initial_length;

    const program_end = pos + @as(usize, @intCast(unit_length));

    const version = try readU16(data, &pos);
    _ = version;

    const header_length: u64 = if (is_64bit) try readU64(data, &pos) else try readU32(data, &pos);
    const program_start = pos + @as(usize, @intCast(header_length));

    const min_instruction_length = try readU8(data, &pos);
    const max_ops_per_instruction = try readU8(data, &pos);
    _ = max_ops_per_instruction;
    const default_is_stmt = (try readU8(data, &pos)) != 0;
    const line_base = @as(i8, @bitCast(try readU8(data, &pos)));
    const line_range = try readU8(data, &pos);
    const opcode_base = try readU8(data, &pos);

    // Standard opcode lengths
    pos += opcode_base - 1;

    // Include directories
    while (pos < data.len and data[pos] != 0) {
        const dir = try readString(data, &pos);
        try table.directories.append(allocator, dir);
    }
    pos += 1; // skip null terminator

    // File names
    while (pos < data.len and data[pos] != 0) {
        const name = try readString(data, &pos);
        const dir_index = try readUleb128(data, &pos);
        const mod_time = try readUleb128(data, &pos);
        const file_size = try readUleb128(data, &pos);

        try table.files.append(allocator, FileName{
            .name = name,
            .dir_index = @intCast(dir_index),
            .mod_time = mod_time,
            .file_size = file_size,
        });
    }
    pos += 1; // skip null terminator

    // Execute line number program
    pos = program_start;
    var state = LineState{};
    state.is_stmt = default_is_stmt;

    while (pos < program_end) {
        const opcode = try readU8(data, &pos);

        if (opcode == 0) {
            // Extended opcode
            const ext_len = try readUleb128(data, &pos);
            const ext_end = pos + @as(usize, @intCast(ext_len));
            const ext_opcode = try readU8(data, &pos);

            switch (ext_opcode) {
                types.LNE.end_sequence => {
                    state.end_sequence = true;
                    try table.entries.append(allocator, SourceLocation{
                        .file = state.file,
                        .line = state.line,
                        .column = state.column,
                        .address = state.address,
                        .is_stmt = state.is_stmt,
                        .end_sequence = true,
                    });
                    state.reset(default_is_stmt);
                },
                types.LNE.set_address => {
                    state.address = if (is_64bit or ext_len > 5)
                        try readU64(data, &pos)
                    else
                        try readU32(data, &pos);
                },
                types.LNE.set_discriminator => {
                    state.discriminator = @intCast(try readUleb128(data, &pos));
                },
                else => {
                    pos = ext_end;
                },
            }
        } else if (opcode < opcode_base) {
            // Standard opcode
            switch (opcode) {
                types.LNS.copy => {
                    try table.entries.append(allocator, SourceLocation{
                        .file = state.file,
                        .line = state.line,
                        .column = state.column,
                        .address = state.address,
                        .is_stmt = state.is_stmt,
                        .end_sequence = false,
                    });
                    state.discriminator = 0;
                },
                types.LNS.advance_pc => {
                    const advance = try readUleb128(data, &pos);
                    state.address += advance * min_instruction_length;
                },
                types.LNS.advance_line => {
                    const advance = try readSleb128(data, &pos);
                    state.line = @intCast(@as(i64, @intCast(state.line)) + advance);
                },
                types.LNS.set_file => {
                    state.file = @intCast(try readUleb128(data, &pos));
                },
                types.LNS.set_column => {
                    state.column = @intCast(try readUleb128(data, &pos));
                },
                types.LNS.negate_stmt => {
                    state.is_stmt = !state.is_stmt;
                },
                types.LNS.set_basic_block => {
                    state.basic_block = true;
                },
                types.LNS.const_add_pc => {
                    const adjusted = (255 - opcode_base) / line_range;
                    state.address += adjusted * min_instruction_length;
                },
                types.LNS.fixed_advance_pc => {
                    state.address += try readU16(data, &pos);
                },
                types.LNS.set_prologue_end => {
                    state.prologue_end = true;
                },
                types.LNS.set_epilogue_begin => {
                    state.epilogue_begin = true;
                },
                types.LNS.set_isa => {
                    state.isa = @intCast(try readUleb128(data, &pos));
                },
                else => {},
            }
        } else {
            // Special opcode
            const adjusted_opcode = opcode - opcode_base;
            const address_increment = (adjusted_opcode / line_range) * min_instruction_length;
            const line_increment = line_base + @as(i8, @intCast(adjusted_opcode % line_range));

            state.address += address_increment;
            state.line = @intCast(@as(i64, @intCast(state.line)) + line_increment);

            try table.entries.append(allocator, SourceLocation{
                .file = state.file,
                .line = state.line,
                .column = state.column,
                .address = state.address,
                .is_stmt = state.is_stmt,
                .end_sequence = false,
            });

            state.basic_block = false;
            state.prologue_end = false;
            state.epilogue_begin = false;
            state.discriminator = 0;
        }
    }

    return table;
}

// Tests

test "line table init" {
    const allocator = std.testing.allocator;
    var table = LineTable.init(allocator);
    defer table.deinit();

    try table.entries.append(allocator, SourceLocation{
        .file = 1,
        .line = 10,
        .column = 0,
        .address = 0x1000,
        .is_stmt = true,
        .end_sequence = false,
    });

    const loc = table.locationForAddress(0x1010);
    try std.testing.expect(loc != null);
    try std.testing.expectEqual(@as(u32, 10), loc.?.line);
}

test "address lookup before any entry returns null" {
    const allocator = std.testing.allocator;
    var table = LineTable.init(allocator);
    defer table.deinit();

    try table.entries.append(allocator, SourceLocation{
        .file = 1,
        .line = 10,
        .column = 0,
        .address = 0x1000,
        .is_stmt = true,
        .end_sequence = false,
    });

    try std.testing.expect(table.locationForAddress(0x100) == null);
}

test "line to address lookup" {
    const allocator = std.testing.allocator;
    var table = LineTable.init(allocator);
    defer table.deinit();

    try table.entries.append(allocator, SourceLocation{
        .file = 1,
        .line = 10,
        .column = 0,
        .address = 0x1000,
        .is_stmt = true,
        .end_sequence = false,
    });

    try std.testing.expectEqual(@as(u64, 0x1000), table.addressForLine(1, 10).?);
    try std.testing.expect(table.addressForLine(1, 20) == null);
}

test "file name lookup" {
    const allocator = std.testing.allocator;
    var table = LineTable.init(allocator);
    defer table.deinit();

    try table.files.append(allocator, FileName{
        .name = "main.c",
        .dir_index = 0,
        .mod_time = 0,
        .file_size = 0,
    });

    try std.testing.expectEqualStrings("main.c", table.getFileName(1).?);
    try std.testing.expect(table.getFileName(0) == null);
    try std.testing.expect(table.getFileName(99) == null);
}
