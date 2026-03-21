//! Command line interface
//!
//! Interactive debugger command loop.

const std = @import("std");
const Debugger = @import("debugger.zig").Debugger;

/// Command line interface for the debugger.
pub const Cli = struct {
    allocator: std.mem.Allocator,
    debugger: *Debugger,
    running: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, debugger: *Debugger) Self {
        return Self{
            .allocator = allocator,
            .debugger = debugger,
            .running = true,
        };
    }

    /// Run the CLI loop.
    pub fn run(self: *Self) !void {
        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();

        var buf: [1024]u8 = undefined;

        while (self.running) {
            try stdout.print("(phantom) ", .{});

            const line = stdin.readUntilDelimiter(&buf, '\n') catch |err| {
                if (err == error.EndOfStream) {
                    try stdout.print("\n", .{});
                    break;
                }
                return err;
            };

            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;

            self.executeCommand(trimmed) catch |err| {
                try stdout.print("error: {}\n", .{err});
            };
        }
    }

    /// Execute a single command.
    pub fn executeCommand(self: *Self, line: []const u8) !void {
        const stdout = std.io.getStdOut().writer();

        var it = std.mem.splitScalar(u8, line, ' ');
        const cmd = it.next() orelse return;

        if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q")) {
            self.running = false;
            try stdout.print("Quitting.\n", .{});
        } else if (std.mem.eql(u8, cmd, "continue") or std.mem.eql(u8, cmd, "c")) {
            try self.debugger.continue_();
            try stdout.print("Continuing.\n", .{});

            // Wait for stop
            if (self.debugger.process) |*p| {
                const result = try p.wait();
                switch (result.state) {
                    .stopped => try stdout.print("Stopped (signal {?})\n", .{result.signal}),
                    .exited => try stdout.print("Exited with code {?}\n", .{result.exit_code}),
                    .signaled => try stdout.print("Killed by signal {?}\n", .{result.signal}),
                    .running => {},
                }
            }
        } else if (std.mem.eql(u8, cmd, "step") or std.mem.eql(u8, cmd, "s")) {
            try self.debugger.step();

            // Wait for stop
            if (self.debugger.process) |*p| {
                _ = try p.wait();
                const pc = try self.debugger.getPC();
                try stdout.print("Stepped to 0x{x}\n", .{pc});
            }
        } else if (std.mem.eql(u8, cmd, "break") or std.mem.eql(u8, cmd, "b")) {
            const arg = it.next() orelse {
                try stdout.print("usage: break <address|function>\n", .{});
                return;
            };

            // Try parsing as hex address
            const addr = std.fmt.parseInt(u64, arg, 0) catch blk: {
                // Try as symbol name
                if (self.debugger.elf) |*elf| {
                    if (elf.findSymbol(arg)) |sym| {
                        break :blk sym.value;
                    }
                }
                try stdout.print("Symbol not found: {s}\n", .{arg});
                return;
            };

            const id = try self.debugger.setBreakpoint(addr);
            try stdout.print("Breakpoint {d} at 0x{x}\n", .{ id, addr });
        } else if (std.mem.eql(u8, cmd, "delete") or std.mem.eql(u8, cmd, "d")) {
            const arg = it.next() orelse {
                try stdout.print("usage: delete <breakpoint-id>\n", .{});
                return;
            };

            const id = std.fmt.parseInt(u32, arg, 10) catch {
                try stdout.print("Invalid breakpoint id: {s}\n", .{arg});
                return;
            };

            try self.debugger.removeBreakpoint(id);
            try stdout.print("Deleted breakpoint {d}\n", .{id});
        } else if (std.mem.eql(u8, cmd, "info")) {
            const subcmd = it.next() orelse {
                try stdout.print("usage: info <registers|breakpoints>\n", .{});
                return;
            };

            if (std.mem.eql(u8, subcmd, "registers") or std.mem.eql(u8, subcmd, "regs")) {
                if (self.debugger.process) |*p| {
                    const regs = try p.getRegisters();
                    try regs.format(stdout);
                } else {
                    try stdout.print("No process.\n", .{});
                }
            } else if (std.mem.eql(u8, subcmd, "breakpoints") or std.mem.eql(u8, subcmd, "break")) {
                const bps = self.debugger.breakpoints.list();
                if (bps.len == 0) {
                    try stdout.print("No breakpoints.\n", .{});
                } else {
                    try stdout.print("Num  Address          Enabled  Hits\n", .{});
                    for (bps) |bp| {
                        try stdout.print("{d:<4} 0x{x:0>16} {s:<8} {d}\n", .{
                            bp.id,
                            bp.address,
                            if (bp.enabled) "yes" else "no",
                            bp.hit_count,
                        });
                    }
                }
            }
        } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h")) {
            try stdout.print(
                \\Commands:
                \\  continue, c       Continue execution
                \\  step, s           Single step
                \\  break <loc>       Set breakpoint
                \\  delete <n>        Delete breakpoint
                \\  info registers    Show registers
                \\  info breakpoints  List breakpoints
                \\  quit, q           Exit debugger
                \\
            , .{});
        } else {
            try stdout.print("Unknown command: {s}. Type 'help' for commands.\n", .{cmd});
        }
    }
};

test "cli init" {
    // Just test that types compile
    _ = Cli;
}
