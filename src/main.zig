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

/// Global debugger reference for signal handler.
var global_debugger: ?*Debugger = null;

/// SIGINT handler - interrupts the inferior process.
fn sigintHandler(_: c_int) callconv(.C) void {
    if (global_debugger) |dbg| {
        if (dbg.process) |*p| {
            if (p.state == .running) {
                // Send SIGSTOP to the inferior
                _ = std.os.linux.kill(p.pid, std.os.linux.SIG.STOP);
            }
        }
    }
}

/// Install signal handlers.
fn installSignalHandlers() void {
    if (builtin.os.tag != .linux) return;

    var sa: std.os.linux.Sigaction = .{
        .handler = .{ .handler = sigintHandler },
        .mask = std.os.linux.empty_sigset,
        .flags = std.os.linux.SA.RESTART,
    };

    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &sa, null);
}

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
        const stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("phantom {s}\n", .{version});
        return;
    }

    // Check if running on Linux
    if (builtin.os.tag != .linux) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("error: phantom requires Linux (ptrace support)\n", .{});
        try stderr.print("hint: phantom uses ptrace, which is only available on Linux\n", .{});
        std.process.exit(1);
    }

    // Initialize debugger
    var debugger = try Debugger.init(allocator);
    defer debugger.deinit();

    // Install signal handlers and set global reference
    global_debugger = &debugger;
    installSignalHandlers();
    defer global_debugger = null;

    // Parse command
    if (std.mem.eql(u8, cmd, "run")) {
        if (args.len < 3) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("usage: phantom run <program> [args...]\n", .{});
            std.process.exit(1);
        }
        debugger.loadProgram(args[2]) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("error: cannot load program '{s}': {}\n", .{ args[2], err });
            std.process.exit(1);
        };
        debugger.run(args[3..]) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("error: cannot run program: {}\n", .{err});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, cmd, "attach")) {
        if (args.len < 3) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("usage: phantom attach <pid>\n", .{});
            std.process.exit(1);
        }
        const pid = std.fmt.parseInt(i32, args[2], 10) catch {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("error: invalid pid '{s}' - must be a number\n", .{args[2]});
            std.process.exit(1);
        };
        debugger.attach(pid) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("error: cannot attach to pid {d}: {}\n", .{ pid, err });
            try stderr.print("hint: you may need root privileges or CAP_SYS_PTRACE\n", .{});
            std.process.exit(1);
        };
    } else {
        // Assume it's a program path for convenience
        debugger.loadProgram(cmd) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("error: cannot load program '{s}': {}\n", .{ cmd, err });
            std.process.exit(1);
        };
        debugger.run(args[2..]) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("error: cannot run program: {}\n", .{err});
            std.process.exit(1);
        };
    }

    // Run CLI
    var cli = Cli.init(allocator, &debugger);
    try cli.run();
}

fn printUsage() void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.print(
        \\phantom - A native debugger for Linux
        \\
        \\Usage:
        \\  phantom <program> [args...]     Debug a program (shorthand)
        \\  phantom run <program> [args...] Debug a program (explicit)
        \\  phantom attach <pid>            Attach to a running process
        \\
        \\Options:
        \\  -h, --help     Show this help message
        \\  -v, --version  Show version
        \\
        \\Examples:
        \\  phantom ./myprogram           Debug myprogram
        \\  phantom ./myprogram arg1 arg2 Debug with arguments
        \\  phantom attach 1234           Attach to process 1234
        \\
        \\Debugger Commands (once inside):
        \\  run, r          Start/restart program
        \\  continue, c     Continue execution
        \\  step, s         Single step instruction
        \\  next, n         Step over
        \\  break, b <loc>  Set breakpoint (address or symbol)
        \\  delete, d <n>   Delete breakpoint
        \\  backtrace, bt   Show call stack
        \\  print, p <expr> Print variable/expression
        \\  info regs       Show registers
        \\  quit, q         Exit debugger
        \\  help, h         Show all commands
        \\
        \\Note: Requires Linux with ptrace support. May need root or CAP_SYS_PTRACE.
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
