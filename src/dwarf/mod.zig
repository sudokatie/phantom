//! DWARF debug information parser
//!
//! Parses DWARF debug sections to provide source-level debugging.

const std = @import("std");

pub const types = @import("types.zig");
pub const parser = @import("parser.zig");

/// DWARF debug information.
pub const DwarfInfo = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

test "dwarf info init" {
    var info = DwarfInfo.init(std.testing.allocator);
    defer info.deinit();
}
