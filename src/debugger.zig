//! Debugger state machine
//!
//! Coordinates process control, breakpoints, and symbol information.

const std = @import("std");
const Process = @import("process.zig").Process;
const BreakpointManager = @import("breakpoint.zig").BreakpointManager;
const Elf = @import("elf.zig").Elf;

/// Main debugger state.
pub const Debugger = struct {
    allocator: std.mem.Allocator,
    process: ?Process,
    breakpoints: BreakpointManager,
    elf: ?Elf,
    program_path: ?[]const u8,
    current_frame: u32,

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
    }

    /// Load a program for debugging.
    pub fn loadProgram(self: *Self, path: []const u8) !void {
        // Parse ELF for symbols and debug info
        self.elf = try Elf.parse(self.allocator, path);
        self.program_path = try self.allocator.dupe(u8, path);
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
};

test "debugger init" {
    var debugger = try Debugger.init(std.testing.allocator);
    defer debugger.deinit();

    try std.testing.expect(debugger.process == null);
    try std.testing.expect(debugger.elf == null);
}
