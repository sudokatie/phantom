//! Phantom - A native debugger
//!
//! A ptrace-based debugger for Linux supporting:
//! - Software breakpoints
//! - DWARF debug info parsing
//! - Stack unwinding
//! - Expression evaluation

const std = @import("std");
const builtin = @import("builtin");

pub const Debugger = @import("debugger.zig").Debugger;
pub const Process = @import("process.zig").Process;
pub const Breakpoint = @import("breakpoint.zig").Breakpoint;
pub const BreakpointManager = @import("breakpoint.zig").BreakpointManager;
pub const Elf = @import("elf.zig").Elf;
pub const Registers = @import("regs.zig").Registers;
pub const Cli = @import("cli.zig").Cli;
pub const Evaluator = @import("eval.zig").Evaluator;

const version = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("phantom {s}\n", .{version});
        return;
    }

    // Check if running on Linux
    if (builtin.os.tag != .linux) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("error: phantom requires Linux (ptrace support)\n", .{});
        std.process.exit(1);
    }

    // Initialize debugger
    var debugger = try Debugger.init(allocator);
    defer debugger.deinit();

    // Parse command
    if (std.mem.eql(u8, cmd, "run")) {
        if (args.len < 3) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("usage: phantom run <program> [args...]\n", .{});
            std.process.exit(1);
        }
        try debugger.loadProgram(args[2]);
        try debugger.run(args[3..]);
    } else if (std.mem.eql(u8, cmd, "attach")) {
        if (args.len < 3) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("usage: phantom attach <pid>\n", .{});
            std.process.exit(1);
        }
        const pid = std.fmt.parseInt(i32, args[2], 10) catch {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("error: invalid pid: {s}\n", .{args[2]});
            std.process.exit(1);
        };
        try debugger.attach(pid);
    } else {
        // Assume it's a program path for convenience
        try debugger.loadProgram(cmd);
        try debugger.run(args[2..]);
    }

    // Run CLI
    var cli = Cli.init(allocator, &debugger);
    try cli.run();
}

fn printUsage() void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(
        \\phantom - A native debugger
        \\
        \\Usage:
        \\  phantom <program> [args...]   Debug a program
        \\  phantom run <program> [args...] Explicit run command
        \\  phantom attach <pid>          Attach to running process
        \\
        \\Options:
        \\  -h, --help     Show this help
        \\  -v, --version  Show version
        \\
        \\Commands (in debugger):
        \\  run [args]      Start program
        \\  continue, c     Continue execution
        \\  step, s         Single step (into)
        \\  next, n         Step over
        \\  break <loc>     Set breakpoint
        \\  delete <n>      Delete breakpoint
        \\  backtrace, bt   Show call stack
        \\  print <expr>    Print expression
        \\  info regs       Show registers
        \\  quit, q         Exit debugger
        \\
    , .{}) catch {};
}

test "version string" {
    try std.testing.expect(version.len > 0);
}

test {
    _ = @import("eval.zig");
    _ = @import("dwarf/mod.zig");
}
