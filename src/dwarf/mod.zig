//! DWARF debug information parser
//!
//! Parses DWARF debug sections to provide source-level debugging.

const std = @import("std");

pub const types = @import("types.zig");
pub const parser = @import("parser.zig");
pub const abbrev = @import("abbrev.zig");
pub const info = @import("info.zig");
pub const line = @import("line.zig");
pub const expr = @import("expr.zig");
pub const frame = @import("frame.zig");

// Re-export key types
pub const AbbrevTable = abbrev.AbbrevTable;
pub const Abbrev = abbrev.Abbrev;
pub const AttrSpec = abbrev.AttrSpec;
pub const parseAbbrevSection = abbrev.parseAbbrevSection;

pub const Die = info.Die;
pub const CompUnit = info.CompUnit;
pub const CompUnitHeader = info.CompUnitHeader;
pub const parseCompUnit = info.parseCompUnit;

pub const LineTable = line.LineTable;
pub const SourceLocation = line.SourceLocation;
pub const parseLineProgram = line.parseLineProgram;

pub const ExprEvaluator = expr.ExprEvaluator;
pub const Location = expr.Location;
pub const EvalContext = expr.EvalContext;

pub const FrameTable = frame.FrameTable;
pub const FrameState = frame.FrameState;
pub const Cie = frame.Cie;
pub const Fde = frame.Fde;
pub const parseDebugFrame = frame.parseDebugFrame;
pub const evaluateCfa = frame.evaluateCfa;

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

test {
    _ = types;
    _ = parser;
    _ = abbrev;
    _ = info;
    _ = line;
    _ = expr;
    _ = frame;
}
