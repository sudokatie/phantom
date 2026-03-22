//! DWARF call frame information parser
//!
//! Parses .debug_frame section to build stack unwinding tables.

const std = @import("std");
const types = @import("types.zig");

/// Common Information Entry (CIE).
pub const Cie = struct {
    length: u64,
    id: u64,
    version: u8,
    augmentation: []const u8,
    code_alignment_factor: u64,
    data_alignment_factor: i64,
    return_address_register: u64,
    initial_instructions: []const u8,
};

/// Frame Description Entry (FDE).
pub const Fde = struct {
    length: u64,
    cie_offset: u64,
    initial_location: u64,
    address_range: u64,
    instructions: []const u8,
};

/// CFA rule type.
pub const CfaRule = union(enum) {
    undefined: void,
    same_value: void,
    offset: struct { reg: u8, offset: i64 },
    register: u8,
    expression: []const u8,
};

/// Register rule for unwinding.
pub const RegisterRule = union(enum) {
    undefined: void,
    same_value: void,
    offset: i64,
    val_offset: i64,
    register: u8,
    expression: []const u8,
    val_expression: []const u8,
};

/// Frame state at a particular address.
pub const FrameState = struct {
    cfa_register: u8 = 0,
    cfa_offset: i64 = 0,
    register_rules: [32]RegisterRule = [_]RegisterRule{.undefined} ** 32,

    /// Get the CFA value given register values.
    pub fn getCfa(self: *const FrameState, registers: []const u64) u64 {
        const base = registers[self.cfa_register];
        if (self.cfa_offset >= 0) {
            return base +% @as(u64, @intCast(self.cfa_offset));
        } else {
            return base -% @as(u64, @intCast(-self.cfa_offset));
        }
    }
};

/// Frame information table.
pub const FrameTable = struct {
    allocator: std.mem.Allocator,
    cies: std.ArrayList(Cie),
    fdes: std.ArrayList(Fde),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .cies = .empty,
            .fdes = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cies.deinit(self.allocator);
        self.fdes.deinit(self.allocator);
    }

    /// Find FDE containing address.
    pub fn findFde(self: *const Self, address: u64) ?Fde {
        for (self.fdes.items) |fde| {
            if (address >= fde.initial_location and
                address < fde.initial_location + fde.address_range)
            {
                return fde;
            }
        }
        return null;
    }

    /// Get CIE for an FDE.
    pub fn getCie(self: *const Self, fde: Fde) ?Cie {
        for (self.cies.items) |cie| {
            // CIE offset in FDE points to the CIE
            _ = fde;
            return cie; // For now return first CIE
        }
        return null;
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

/// Parse .debug_frame section.
pub fn parseDebugFrame(allocator: std.mem.Allocator, data: []const u8) !FrameTable {
    var table = FrameTable.init(allocator);
    errdefer table.deinit();

    var pos: usize = 0;

    while (pos < data.len) {
        const entry_start = pos;

        // Read length
        const initial_length = try readU32(data, &pos);
        if (initial_length == 0) break;

        const is_64bit = initial_length == 0xffffffff;
        const length: u64 = if (is_64bit) try readU64(data, &pos) else initial_length;
        const entry_end = pos + @as(usize, @intCast(length));

        // Read CIE ID / CIE pointer
        const id = if (is_64bit) try readU64(data, &pos) else try readU32(data, &pos);

        if (id == 0xffffffff or (is_64bit and id == 0xffffffffffffffff)) {
            // This is a CIE
            const version = try readU8(data, &pos);
            const augmentation = try readString(data, &pos);
            const code_alignment = try readUleb128(data, &pos);
            const data_alignment = try readSleb128(data, &pos);
            const return_reg = try readUleb128(data, &pos);

            const instructions = data[pos..entry_end];

            try table.cies.append(allocator, Cie{
                .length = length,
                .id = id,
                .version = version,
                .augmentation = augmentation,
                .code_alignment_factor = code_alignment,
                .data_alignment_factor = data_alignment,
                .return_address_register = return_reg,
                .initial_instructions = instructions,
            });
        } else {
            // This is an FDE
            const initial_location = if (is_64bit) try readU64(data, &pos) else try readU32(data, &pos);
            const address_range = if (is_64bit) try readU64(data, &pos) else try readU32(data, &pos);

            const instructions = data[pos..entry_end];

            try table.fdes.append(allocator, Fde{
                .length = length,
                .cie_offset = entry_start - @as(usize, @intCast(id)),
                .initial_location = initial_location,
                .address_range = address_range,
                .instructions = instructions,
            });
        }

        pos = entry_end;
    }

    return table;
}

/// Execute CFA instructions to build frame state at address.
pub fn evaluateCfa(
    initial_state: FrameState,
    instructions: []const u8,
    target_address: u64,
    code_alignment: u64,
) !FrameState {
    var state = initial_state;
    var pos: usize = 0;
    var current_address: u64 = 0;

    while (pos < instructions.len and current_address <= target_address) {
        const opcode = instructions[pos];
        pos += 1;

        // High 2 bits determine opcode class
        const hi = opcode & 0xc0;
        const lo = opcode & 0x3f;

        if (hi == types.CFA.advance_loc) {
            // DW_CFA_advance_loc
            current_address += lo * code_alignment;
        } else if (hi == types.CFA.offset) {
            // DW_CFA_offset
            const offset = try readUleb128(instructions, &pos);
            state.register_rules[lo] = .{ .offset = @intCast(offset) };
        } else if (hi == types.CFA.restore) {
            // DW_CFA_restore
            state.register_rules[lo] = .undefined;
        } else {
            switch (opcode) {
                types.CFA.nop => {},

                types.CFA.set_loc => {
                    current_address = try readU64(instructions, &pos);
                },

                types.CFA.advance_loc1 => {
                    const delta = try readU8(instructions, &pos);
                    current_address += delta * code_alignment;
                },

                types.CFA.advance_loc2 => {
                    if (pos + 2 > instructions.len) return error.UnexpectedEndOfData;
                    const delta = std.mem.readInt(u16, instructions[pos..][0..2], .little);
                    pos += 2;
                    current_address += delta * code_alignment;
                },

                types.CFA.advance_loc4 => {
                    const delta = try readU32(instructions, &pos);
                    current_address += delta * code_alignment;
                },

                types.CFA.def_cfa => {
                    state.cfa_register = @intCast(try readUleb128(instructions, &pos));
                    state.cfa_offset = @intCast(try readUleb128(instructions, &pos));
                },

                types.CFA.def_cfa_register => {
                    state.cfa_register = @intCast(try readUleb128(instructions, &pos));
                },

                types.CFA.def_cfa_offset => {
                    state.cfa_offset = @intCast(try readUleb128(instructions, &pos));
                },

                types.CFA.offset_extended => {
                    const reg = try readUleb128(instructions, &pos);
                    const offset = try readUleb128(instructions, &pos);
                    state.register_rules[@intCast(reg)] = .{ .offset = @intCast(offset) };
                },

                types.CFA.same_value => {
                    const reg = try readUleb128(instructions, &pos);
                    state.register_rules[@intCast(reg)] = .same_value;
                },

                types.CFA.undef => {
                    const reg = try readUleb128(instructions, &pos);
                    state.register_rules[@intCast(reg)] = .undefined;
                },

                types.CFA.register => {
                    const reg = try readUleb128(instructions, &pos);
                    const target = try readUleb128(instructions, &pos);
                    state.register_rules[@intCast(reg)] = .{ .register = @intCast(target) };
                },

                else => {
                    // Skip unknown opcodes
                },
            }
        }
    }

    return state;
}

// Tests

test "frame table init" {
    const allocator = std.testing.allocator;
    var table = FrameTable.init(allocator);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 0), table.cies.items.len);
    try std.testing.expectEqual(@as(usize, 0), table.fdes.items.len);
}

test "frame state cfa calculation" {
    var state = FrameState{};
    state.cfa_register = 7; // RSP
    state.cfa_offset = 8;

    var registers = [_]u64{0} ** 16;
    registers[7] = 0x7fff0000;

    try std.testing.expectEqual(@as(u64, 0x7fff0008), state.getCfa(&registers));
}

test "evaluate simple cfa instructions" {
    // DW_CFA_def_cfa r7, 8
    const instructions = [_]u8{
        types.CFA.def_cfa,
        0x07, // reg 7
        0x08, // offset 8
    };

    const state = try evaluateCfa(FrameState{}, &instructions, 0, 1);

    try std.testing.expectEqual(@as(u8, 7), state.cfa_register);
    try std.testing.expectEqual(@as(i64, 8), state.cfa_offset);
}

test "evaluate cfa with advance_loc" {
    // DW_CFA_def_cfa r7, 8 then advance_loc 4, def_cfa_offset 16
    const instructions = [_]u8{
        types.CFA.def_cfa,
        0x07, // reg 7
        0x08, // offset 8
        types.CFA.advance_loc | 4, // advance 4
        types.CFA.def_cfa_offset,
        0x10, // offset 16
    };

    // Before advance
    const state1 = try evaluateCfa(FrameState{}, &instructions, 2, 1);
    try std.testing.expectEqual(@as(i64, 8), state1.cfa_offset);

    // After advance
    const state2 = try evaluateCfa(FrameState{}, &instructions, 10, 1);
    try std.testing.expectEqual(@as(i64, 16), state2.cfa_offset);
}

test "fde lookup" {
    const allocator = std.testing.allocator;
    var table = FrameTable.init(allocator);
    defer table.deinit();

    try table.fdes.append(allocator, Fde{
        .length = 0,
        .cie_offset = 0,
        .initial_location = 0x1000,
        .address_range = 0x100,
        .instructions = &[_]u8{},
    });

    try std.testing.expect(table.findFde(0x1050) != null);
    try std.testing.expect(table.findFde(0x2000) == null);
}
