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
        var last_cmd: []const u8 = "";
        var last_cmd_buf: [1024]u8 = undefined;

        while (self.running) {
            // Show process state in prompt if stopped
            if (self.debugger.process) |p| {
                switch (p.state) {
                    .stopped => try stdout.print("(phantom) ", .{}),
                    .running => try stdout.print("(phantom:running) ", .{}),
                    .exited => try stdout.print("(phantom:exited) ", .{}),
                    .signaled => try stdout.print("(phantom:killed) ", .{}),
                }
            } else {
                try stdout.print("(phantom) ", .{});
            }

            const line = stdin.readUntilDelimiter(&buf, '\n') catch |err| {
                if (err == error.EndOfStream) {
                    try stdout.print("\n", .{});
                    break;
                }
                return err;
            };

            const trimmed = std.mem.trim(u8, line, " \t\r\n");

            // Empty line repeats last command (like gdb)
            const cmd_to_run = if (trimmed.len == 0) last_cmd else blk: {
                @memcpy(last_cmd_buf[0..trimmed.len], trimmed);
                last_cmd = last_cmd_buf[0..trimmed.len];
                break :blk trimmed;
            };

            if (cmd_to_run.len == 0) continue;

            self.executeCommand(cmd_to_run) catch |err| {
                self.printError(stdout, err);
            };
        }
    }

    /// Print a human-readable error message.
    fn printError(self: *Self, writer: anytype, err: anyerror) void {
        _ = self;
        const msg = switch (err) {
            error.NoProcess => "no process - use 'run' or 'attach' first",
            error.AttachFailed => "attach failed - check permissions (may need root or CAP_SYS_PTRACE)",
            error.DetachFailed => "detach failed - process may have already exited",
            error.ContinueFailed => "continue failed - process may have already exited",
            error.SingleStepFailed => "single step failed - process may have already exited",
            error.GetRegsFailed => "cannot read registers - process may have already exited",
            error.SetRegsFailed => "cannot write registers - permission denied",
            error.WriteMemoryFailed => "cannot write memory - permission denied or invalid address",
            error.WaitFailed => "wait failed - process may have already exited",
            error.NoProgramLoaded => "no program loaded - specify a program to debug",
            error.UnsupportedOS => "unsupported OS - phantom requires Linux",
            else => {
                writer.print("error: {}\n", .{err}) catch {};
                return;
            },
        };
        writer.print("error: {s}\n", .{msg}) catch {};
    }

    /// Execute a single command.
    pub fn executeCommand(self: *Self, line: []const u8) !void {
        const stdout = std.io.getStdOut().writer();

        var it = std.mem.splitScalar(u8, line, ' ');
        const cmd = it.next() orelse return;

        if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q")) {
            // Clean up the process before exiting
            if (self.debugger.process) |*p| {
                if (p.state == .running or p.state == .stopped) {
                    self.debugger.detach() catch {
                        // If detach fails, the process might have already exited
                    };
                    try stdout.print("Detached from process {d}.\n", .{p.pid});
                }
            }
            self.running = false;
            try stdout.print("Goodbye.\n", .{});
        } else if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "r")) {
            // Run/restart the program from the CLI
            if (self.debugger.program_path == null) {
                try stdout.print("No program loaded. Use 'phantom <program>' to start.\n", .{});
                return;
            }
            // If already running, ask to restart
            if (self.debugger.process) |*p| {
                if (p.state == .running or p.state == .stopped) {
                    try stdout.print("Program is already running. Use 'continue' or 'quit' first.\n", .{});
                    return;
                }
            }
            // Collect args from rest of command line
            var args_list = std.ArrayList([]const u8).init(self.allocator);
            defer args_list.deinit();
            while (it.next()) |arg| {
                try args_list.append(arg);
            }
            try self.debugger.run(args_list.items);
        } else if (std.mem.eql(u8, cmd, "continue") or std.mem.eql(u8, cmd, "c")) {
            try self.debugger.continue_();
            try stdout.print("Continuing.\n", .{});

            // Wait for stop
            if (self.debugger.process) |*p| {
                const result = try p.wait();
                switch (result.state) {
                    .stopped => {
                        const sig = result.signal orelse 0;
                        if (sig == 5) {
                            // SIGTRAP - likely breakpoint
                            const pc = self.debugger.getPC() catch 0;
                            try stdout.print("Breakpoint hit at 0x{x}\n", .{pc});
                        } else if (sig == 19 or sig == 17 or sig == 23) {
                            // SIGSTOP/SIGTSTP/SIGCONT - user interrupt
                            try stdout.print("Interrupted.\n", .{});
                        } else {
                            try stdout.print("Stopped (signal {d})\n", .{sig});
                        }
                    },
                    .exited => {
                        const code = result.exit_code orelse 0;
                        if (code == 0) {
                            try stdout.print("Program exited normally.\n", .{});
                        } else {
                            try stdout.print("Program exited with code {d}.\n", .{code});
                        }
                    },
                    .signaled => {
                        const sig = result.signal orelse 0;
                        const signame = switch (sig) {
                            6 => "SIGABRT",
                            8 => "SIGFPE",
                            9 => "SIGKILL",
                            11 => "SIGSEGV",
                            15 => "SIGTERM",
                            else => "signal",
                        };
                        try stdout.print("Program terminated by {s} ({d}).\n", .{ signame, sig });
                    },
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
                \\Phantom Debugger Commands
                \\
                \\Running:
                \\  run, r [args]     Start/restart program with optional arguments
                \\  continue, c       Continue execution until breakpoint or exit
                \\  step, s           Single step one instruction (into calls)
                \\  next, n           Step over (currently same as step)
                \\  quit, q           Detach and exit debugger
                \\
                \\Breakpoints:
                \\  break, b <loc>    Set breakpoint at address (0x...) or function name
                \\  delete, d <n>     Delete breakpoint by number
                \\  info breakpoints  List all breakpoints
                \\
                \\Inspection:
                \\  backtrace, bt     Show call stack
                \\  frame, f <n>      Select stack frame for inspection
                \\  print, p <expr>   Print variable or expression
                \\  x <addr>          Examine memory at address
                \\  info registers    Show CPU registers
                \\  info locals       Show local variables (partial)
                \\
                \\Tips:
                \\  - Press Enter to repeat the last command
                \\  - Ctrl+C interrupts a running program (not the debugger)
                \\  - Addresses can be hex (0x400000) or decimal
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
