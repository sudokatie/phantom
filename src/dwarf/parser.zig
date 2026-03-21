//! DWARF .debug_info parser

const std = @import("std");
const types = @import("types.zig");

/// A parsed compile unit.
pub const CompileUnit = struct {
    name: ?[]const u8,
    comp_dir: ?[]const u8,
    low_pc: u64,
    high_pc: u64,
};

/// A parsed function/subprogram.
pub const Function = struct {
    name: []const u8,
    low_pc: u64,
    high_pc: u64,
    frame_base: ?[]const u8,
};

/// A parsed variable.
pub const Variable = struct {
    name: []const u8,
    type_offset: u64,
    location: ?[]const u8,
};

/// Parse .debug_info section.
pub fn parseDebugInfo(allocator: std.mem.Allocator, data: []const u8) !void {
    _ = allocator;
    _ = data;
    // TODO: Implement DWARF parsing
}

test "parser types" {
    _ = CompileUnit;
    _ = Function;
    _ = Variable;
}
