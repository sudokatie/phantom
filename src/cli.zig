//! Command line interface
//!
//! Interactive debugger command loop.

const std = @import("std");
const Debugger = @import("debugger.zig").Debugger;
const eval = @import("eval.zig");

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
        } else if (std.mem.eql(u8, cmd, "next") or std.mem.eql(u8, cmd, "n")) {
            // Step over - for now same as step (proper step over needs call detection)
            try self.debugger.step();

            if (self.debugger.process) |*p| {
                _ = try p.wait();
                const pc = try self.debugger.getPC();
                try stdout.print("Stepped to 0x{x}\n", .{pc});
            }
        } else if (std.mem.eql(u8, cmd, "backtrace") or std.mem.eql(u8, cmd, "bt")) {
            try self.showBacktrace(stdout);
        } else if (std.mem.eql(u8, cmd, "frame") or std.mem.eql(u8, cmd, "f")) {
            const arg = it.next() orelse {
                try stdout.print("Current frame: {d}\n", .{self.debugger.current_frame});
                return;
            };
            const frame_num = std.fmt.parseInt(u32, arg, 10) catch {
                try stdout.print("Invalid frame number: {s}\n", .{arg});
                return;
            };
            self.debugger.current_frame = frame_num;
            try stdout.print("Selected frame {d}\n", .{frame_num});
        } else if (std.mem.eql(u8, cmd, "print") or std.mem.eql(u8, cmd, "p")) {
            const expr = it.rest();
            if (expr.len == 0) {
                try stdout.print("usage: print <expression>\n", .{});
                return;
            }
            try self.printExpression(stdout, expr);
        } else if (std.mem.eql(u8, cmd, "x")) {
            // Examine memory
            const arg = it.next() orelse {
                try stdout.print("usage: x <address>\n", .{});
                return;
            };
            const addr = std.fmt.parseInt(u64, arg, 0) catch {
                try stdout.print("Invalid address: {s}\n", .{arg});
                return;
            };
            try self.examineMemory(stdout, addr, 64);
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
            } else if (std.mem.eql(u8, subcmd, "locals")) {
                try stdout.print("(locals not yet implemented)\n", .{});
            } else {
                try stdout.print("Unknown info subcommand: {s}\n", .{subcmd});
            }
        } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h")) {
            try stdout.print(
                \\Commands:
                \\  run [args]        Start program
                \\  continue, c       Continue execution
                \\  step, s           Single step (into)
                \\  next, n           Step over
                \\  break <loc>       Set breakpoint (address or symbol)
                \\  delete <n>        Delete breakpoint
                \\  backtrace, bt     Show call stack
                \\  frame <n>         Select stack frame
                \\  print <expr>      Print expression/variable
                \\  x <addr>          Examine memory
                \\  info registers    Show registers
                \\  info breakpoints  List breakpoints
                \\  info locals       Show local variables
                \\  quit, q           Exit debugger
                \\
            , .{});
        } else {
            try stdout.print("Unknown command: {s}. Type 'help' for commands.\n", .{cmd});
        }
    }

    /// Show backtrace.
    fn showBacktrace(self: *Self, writer: anytype) !void {
        if (self.debugger.process == null) {
            try writer.print("No process.\n", .{});
            return;
        }

        // Get current PC and frame pointer
        const pc = try self.debugger.getPC();
        const regs = try self.debugger.process.?.getRegisters();

        try writer.print("#0  0x{x:0>16}", .{pc});

        // Try to get symbol name
        if (self.debugger.elf) |*elf| {
            if (elf.symbolAt(pc)) |sym| {
                try writer.print(" in {s}", .{sym.name});
            }
        }
        try writer.print("\n", .{});

        // Simple frame walking using rbp chain
        var frame_num: u32 = 1;
        var rbp = regs.rbp;

        while (rbp != 0 and frame_num < 20) {
            // Read return address and saved rbp
            if (self.debugger.process) |*p| {
                const saved_rbp = p.readMemory(rbp, @sizeOf(u64)) catch break;
                const ret_addr = p.readMemory(rbp + 8, @sizeOf(u64)) catch break;

                const next_rbp = std.mem.readInt(u64, saved_rbp[0..8], .little);
                const return_addr = std.mem.readInt(u64, ret_addr[0..8], .little);

                if (return_addr == 0) break;

                try writer.print("#{d}  0x{x:0>16}", .{ frame_num, return_addr });

                if (self.debugger.elf) |*elf| {
                    if (elf.symbolAt(return_addr)) |sym| {
                        try writer.print(" in {s}", .{sym.name});
                    }
                }
                try writer.print("\n", .{});

                rbp = next_rbp;
                frame_num += 1;
            } else break;
        }
    }

    /// Print expression value.
    fn printExpression(self: *Self, writer: anytype, expr: []const u8) !void {
        _ = self;
        // For now just print the expression - full evaluation needs DWARF integration
        try writer.print("${s} = (evaluation not yet implemented)\n", .{expr});
    }

    /// Examine memory at address.
    fn examineMemory(self: *Self, writer: anytype, addr: u64, size: usize) !void {
        if (self.debugger.process == null) {
            try writer.print("No process.\n", .{});
            return;
        }

        const data = self.debugger.process.?.readMemory(addr, size) catch |err| {
            try writer.print("Cannot read memory at 0x{x}: {}\n", .{ addr, err });
            return;
        };

        const formatted = try eval.formatMemory(self.allocator, data, addr);
        defer self.allocator.free(formatted);
        try writer.print("{s}", .{formatted});
    }
};

test "cli init" {
    // Just test that types compile
    _ = Cli;
}
