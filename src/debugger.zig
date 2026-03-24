//! Debugger state machine
//!
//! Coordinates process control, breakpoints, and symbol information.

const std = @import("std");
const Process = @import("process.zig").Process;
const BreakpointManager = @import("breakpoint.zig").BreakpointManager;
const Elf = @import("elf.zig").Elf;
const dwarf = @import("dwarf/mod.zig");

/// Main debugger state.
pub const Debugger = struct {
    allocator: std.mem.Allocator,
    process: ?Process,
    breakpoints: BreakpointManager,
    elf: ?Elf,
    program_path: ?[]const u8,
    current_frame: u32,
    line_table: ?dwarf.LineTable,
    comp_unit: ?dwarf.CompUnit,
    source_files: std.StringHashMap([]const u8),

    const Self = @This();

    /// Initialize the debugger.
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .process = null,
            .breakpoints = BreakpointManager.init(allocator),
            .elf = null,
            .program_path = null,
            .current_frame = 0,
            .line_table = null,
            .comp_unit = null,
            .source_files = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Clean up debugger resources.
    pub fn deinit(self: *Self) void {
        if (self.process) |*p| {
            p.detach() catch {};
        }
        self.breakpoints.deinit();
        if (self.elf) |*e| {
            e.deinit();
        }
        if (self.program_path) |path| {
            self.allocator.free(path);
        }
        if (self.line_table) |*lt| {
            lt.deinit();
        }
        if (self.comp_unit) |*cu| {
            cu.deinit();
        }
        var it = self.source_files.valueIterator();
        while (it.next()) |content| {
            self.allocator.free(content.*);
        }
        self.source_files.deinit();
    }

    /// Load a program for debugging.
    pub fn loadProgram(self: *Self, path: []const u8) !void {
        // Parse ELF for symbols and debug info
        self.elf = try Elf.parse(self.allocator, path);
        self.program_path = try self.allocator.dupe(u8, path);

        // Try to parse DWARF debug info
        if (self.elf) |*elf| {
            // Parse line number info
            if (elf.sectionData(".debug_line")) |line_data| {
                self.line_table = dwarf.parseLineProgram(self.allocator, line_data) catch null;
            }

            // Parse compilation unit
            if (elf.sectionData(".debug_info")) |info_data| {
                if (elf.sectionData(".debug_abbrev")) |abbrev_data| {
                    const str_section = elf.sectionData(".debug_str");
                    self.comp_unit = dwarf.parseCompUnit(self.allocator, info_data, abbrev_data, str_section) catch null;
                }
            }
        }
    }

    /// Start the loaded program.
    pub fn run(self: *Self, args: []const []const u8) !void {
        const path = self.program_path orelse return error.NoProgramLoaded;
        self.process = try Process.spawn(self.allocator, path, args);

        const stdout = std.io.getStdOut().writer();
        try stdout.print("Starting program: {s}\n", .{path});
    }

    /// Attach to a running process.
    pub fn attach(self: *Self, pid: i32) !void {
        self.process = try Process.attach(pid);

        const stdout = std.io.getStdOut().writer();
        try stdout.print("Attached to process {d}\n", .{pid});
    }

    /// Detach from the current process.
    pub fn detach(self: *Self) !void {
        if (self.process) |*p| {
            try p.detach();
            self.process = null;
        }
    }

    /// Continue execution.
    pub fn continue_(self: *Self) !void {
        if (self.process) |*p| {
            try p.continue_(null);
        } else {
            return error.NoProcess;
        }
    }

    /// Single step one instruction.
    pub fn step(self: *Self) !void {
        if (self.process) |*p| {
            try p.singleStep();
        } else {
            return error.NoProcess;
        }
    }

    /// Check if a process is loaded and running.
    pub fn isRunning(self: *Self) bool {
        if (self.process) |p| {
            return p.state == .running or p.state == .stopped;
        }
        return false;
    }

    /// Get the current instruction pointer.
    pub fn getPC(self: *Self) !u64 {
        if (self.process) |*p| {
            const regs = try p.getRegisters();
            return regs.rip;
        }
        return error.NoProcess;
    }

    /// Set a breakpoint at the given address.
    pub fn setBreakpoint(self: *Self, addr: u64) !u32 {
        if (self.process) |*p| {
            return try self.breakpoints.set(p, addr);
        }
        return error.NoProcess;
    }

    /// Remove a breakpoint.
    pub fn removeBreakpoint(self: *Self, id: u32) !void {
        if (self.process) |*p| {
            try self.breakpoints.remove(p, id);
        } else {
            return error.NoProcess;
        }
    }

    /// Get source location for an address.
    pub fn getSourceLocation(self: *Self, addr: u64) ?dwarf.SourceLocation {
        if (self.line_table) |*lt| {
            return lt.locationForAddress(addr);
        }
        return null;
    }

    /// Get address for a source location (file:line).
    pub fn getAddressForLine(self: *Self, file_idx: u32, line: u32) ?u64 {
        if (self.line_table) |*lt| {
            return lt.addressForLine(file_idx, line);
        }
        return null;
    }

    /// Find file index by name.
    pub fn findFileIndex(self: *Self, filename: []const u8) ?u32 {
        if (self.line_table) |*lt| {
            for (lt.files.items, 0..) |file, i| {
                if (std.mem.endsWith(u8, file.name, filename)) {
                    return @intCast(i + 1); // file indices are 1-based
                }
            }
        }
        return null;
    }

    /// Get source file content.
    pub fn getSourceContent(self: *Self, filename: []const u8) ?[]const u8 {
        // Check cache
        if (self.source_files.get(filename)) |content| {
            return content;
        }

        // Try to read file
        const file = std.fs.cwd().openFile(filename, .{}) catch return null;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return null;
        self.source_files.put(filename, content) catch {
            self.allocator.free(content);
            return null;
        };

        return content;
    }

    /// Get source lines around a location.
    pub fn getSourceLines(self: *Self, filename: []const u8, line: u32, context: u32) ?[]const []const u8 {
        const content = self.getSourceContent(filename) orelse return null;

        var lines = std.ArrayList([]const u8).init(self.allocator);
        var line_num: u32 = 1;
        var start: usize = 0;

        const start_line = if (line > context) line - context else 1;
        const end_line = line + context;

        for (content, 0..) |c, i| {
            if (c == '\n') {
                if (line_num >= start_line and line_num <= end_line) {
                    lines.append(content[start..i]) catch {};
                }
                start = i + 1;
                line_num += 1;
                if (line_num > end_line) break;
            }
        }

        // Handle last line without newline
        if (line_num >= start_line and line_num <= end_line and start < content.len) {
            lines.append(content[start..]) catch {};
        }

        return lines.toOwnedSlice() catch null;
    }

    /// Get filename from line table.
    pub fn getFileName(self: *Self, file_idx: u32) ?[]const u8 {
        if (self.line_table) |*lt| {
            return lt.getFileName(file_idx);
        }
        return null;
    }

    /// Find local variables at current PC.
    pub fn getLocalVariables(self: *Self) ?[]const LocalVariable {
        const pc = self.getPC() catch return null;

        if (self.comp_unit) |*cu| {
            var locals = std.ArrayList(LocalVariable).init(self.allocator);

            // Find the function containing this PC
            const func = findFunctionContaining(cu.root_die, pc) orelse return null;

            // Collect variables from this function
            collectVariables(func, &locals, self.allocator) catch return null;

            return locals.toOwnedSlice() catch null;
        }
        return null;
    }
};

/// A local variable descriptor.
pub const LocalVariable = struct {
    name: []const u8,
    type_name: ?[]const u8,
    location: ?dwarf.Location,
};

fn findFunctionContaining(die: *dwarf.Die, pc: u64) ?*dwarf.Die {
    if (die.tag == dwarf.types.TAG.subprogram) {
        const low_pc = die.getAddress(dwarf.types.AT.low_pc) orelse 0;
        const high_pc = die.getUnsigned(dwarf.types.AT.high_pc) orelse 0;

        // high_pc can be an offset or absolute address
        const end_pc = if (high_pc < low_pc) low_pc + high_pc else high_pc;

        if (pc >= low_pc and pc < end_pc) {
            return die;
        }
    }

    for (die.children.items) |child| {
        if (findFunctionContaining(child, pc)) |found| {
            return found;
        }
    }

    return null;
}

fn collectVariables(die: *dwarf.Die, list: *std.ArrayList(LocalVariable), allocator: std.mem.Allocator) !void {
    if (die.tag == dwarf.types.TAG.variable or die.tag == dwarf.types.TAG.formal_parameter) {
        const name = die.getString(dwarf.types.AT.name) orelse "???";

        var location: ?dwarf.Location = null;
        if (die.getAttr(dwarf.types.AT.location)) |loc_attr| {
            if (loc_attr == .block) {
                var eval = dwarf.ExprEvaluator.init(allocator);
                defer eval.deinit();
                location = eval.evaluate(loc_attr.block, .{}) catch null;
            }
        }

        try list.append(LocalVariable{
            .name = name,
            .type_name = null, // Would need to resolve type DIE
            .location = location,
        });
    }

    for (die.children.items) |child| {
        try collectVariables(child, list, allocator);
    }
}

test "debugger init" {
    var debugger = try Debugger.init(std.testing.allocator);
    defer debugger.deinit();

    try std.testing.expect(debugger.process == null);
    try std.testing.expect(debugger.elf == null);
}
