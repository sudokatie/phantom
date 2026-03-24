//! Command line interface
//!
//! Interactive debugger command loop.

const std = @import("std");
const Debugger = @import("debugger.zig").Debugger;
const LocalVariable = @import("debugger.zig").LocalVariable;
const eval = @import("eval.zig");
const disasm = @import("disasm.zig");
const dwarf = @import("dwarf/mod.zig");

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
                try stdout.print("usage: break <address|function|file:line>\n", .{});
                return;
            };

            // Try parsing as file:line
            if (std.mem.indexOf(u8, arg, ":")) |colon_pos| {
                const filename = arg[0..colon_pos];
                const line_str = arg[colon_pos + 1 ..];
                const line_num = std.fmt.parseInt(u32, line_str, 10) catch {
                    try stdout.print("Invalid line number: {s}\n", .{line_str});
                    return;
                };

                // Find file index
                const file_idx = self.debugger.findFileIndex(filename) orelse {
                    try stdout.print("Source file not found: {s}\n", .{filename});
                    return;
                };

                // Get address for line
                const addr = self.debugger.getAddressForLine(file_idx, line_num) orelse {
                    try stdout.print("No code at {s}:{d}\n", .{ filename, line_num });
                    return;
                };

                const id = try self.debugger.setBreakpoint(addr);
                try stdout.print("Breakpoint {d} at {s}:{d} (0x{x})\n", .{ id, filename, line_num, addr });
                return;
            }

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
                try self.showLocals(stdout);
            } else {
                try stdout.print("Unknown info subcommand: {s}\n", .{subcmd});
            }
        } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "l")) {
            try self.showSource(stdout, it.next());
        } else if (std.mem.eql(u8, cmd, "disassemble") or std.mem.eql(u8, cmd, "disas")) {
            try self.showDisassembly(stdout, it.next());
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
                \\  break, b <loc>    Set breakpoint (address, function, or file:line)
                \\  delete, d <n>     Delete breakpoint by number
                \\  info breakpoints  List all breakpoints
                \\
                \\Source:
                \\  list, l [line]    Show source code around current line or specified line
                \\  disassemble       Show assembly at current location
                \\
                \\Inspection:
                \\  backtrace, bt     Show call stack
                \\  frame, f <n>      Select stack frame for inspection
                \\  print, p <expr>   Print variable or register ($rax)
                \\  x <addr>          Examine memory at address
                \\  info registers    Show CPU registers
                \\  info locals       Show local variables
                \\
                \\Tips:
                \\  - Press Enter to repeat the last command
                \\  - Ctrl+C interrupts a running program (not the debugger)
                \\  - Addresses can be hex (0x400000) or decimal
                \\  - Breakpoints: 'b main', 'b 0x401000', 'b main.c:42'
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
        const trimmed = std.mem.trim(u8, expr, " \t");

        if (self.debugger.process == null) {
            try writer.print("No process.\n", .{});
            return;
        }

        // Handle register references ($rax, $rbp, etc.)
        if (trimmed.len > 1 and trimmed[0] == '$') {
            const reg_name = trimmed[1..];
            const regs = self.debugger.process.?.getRegisters() catch {
                try writer.print("Cannot read registers.\n", .{});
                return;
            };

            if (regs.get(reg_name)) |value| {
                try writer.print("${s} = 0x{x} ({d})\n", .{ reg_name, value, value });
            } else {
                try writer.print("Unknown register: {s}\n", .{reg_name});
            }
            return;
        }

        // Handle hex address dereference (*0x...)
        if (trimmed.len > 1 and trimmed[0] == '*') {
            const addr_str = trimmed[1..];
            const addr = std.fmt.parseInt(u64, addr_str, 0) catch {
                try writer.print("Invalid address: {s}\n", .{addr_str});
                return;
            };

            var buf: [8]u8 = undefined;
            self.debugger.process.?.readMemory(addr, &buf) catch {
                try writer.print("Cannot read memory at 0x{x}\n", .{addr});
                return;
            };

            const value = std.mem.readInt(u64, &buf, .little);
            try writer.print("*0x{x} = 0x{x} ({d})\n", .{ addr, value, value });
            return;
        }

        // Try looking up as a variable name
        if (self.debugger.getLocalVariables()) |locals| {
            defer self.allocator.free(locals);

            for (locals) |local| {
                if (std.mem.eql(u8, local.name, trimmed)) {
                    if (local.location) |loc| {
                        switch (loc) {
                            .register => |reg| {
                                const regs = self.debugger.process.?.getRegisters() catch {
                                    try writer.print("{s} = (cannot read register)\n", .{local.name});
                                    return;
                                };
                                if (regs.getByDwarfNum(reg)) |value| {
                                    try writer.print("{s} = 0x{x} ({d})\n", .{ local.name, value, value });
                                } else {
                                    try writer.print("{s} = (unknown register {d})\n", .{ local.name, reg });
                                }
                            },
                            .address => |addr| {
                                var buf: [8]u8 = undefined;
                                self.debugger.process.?.readMemory(addr, &buf) catch {
                                    try writer.print("{s} = (cannot read memory)\n", .{local.name});
                                    return;
                                };
                                const value = std.mem.readInt(u64, &buf, .little);
                                try writer.print("{s} = 0x{x} ({d})\n", .{ local.name, value, value });
                            },
                            .frame_offset => |offset| {
                                const regs = self.debugger.process.?.getRegisters() catch {
                                    try writer.print("{s} = (cannot read registers)\n", .{local.name});
                                    return;
                                };
                                const addr = if (offset >= 0)
                                    regs.rbp +% @as(u64, @intCast(offset))
                                else
                                    regs.rbp -% @as(u64, @intCast(-offset));

                                var buf: [8]u8 = undefined;
                                self.debugger.process.?.readMemory(addr, &buf) catch {
                                    try writer.print("{s} = (cannot read memory)\n", .{local.name});
                                    return;
                                };
                                const value = std.mem.readInt(u64, &buf, .little);
                                try writer.print("{s} = 0x{x} ({d})\n", .{ local.name, value, value });
                            },
                            .value => |v| {
                                try writer.print("{s} = 0x{x} ({d})\n", .{ local.name, v, v });
                            },
                        }
                    } else {
                        try writer.print("{s} = (location unavailable)\n", .{local.name});
                    }
                    return;
                }
            }
        }

        try writer.print("Variable not found: {s}\n", .{trimmed});
    }

    /// Examine memory at address.
    fn examineMemory(self: *Self, writer: anytype, addr: u64, size: usize) !void {
        if (self.debugger.process == null) {
            try writer.print("No process.\n", .{});
            return;
        }

        var buf: [256]u8 = undefined;
        const read_size = @min(size, buf.len);
        self.debugger.process.?.readMemory(addr, buf[0..read_size]) catch |err| {
            try writer.print("Cannot read memory at 0x{x}: {}\n", .{ addr, err });
            return;
        };

        const formatted = try eval.formatMemory(self.allocator, buf[0..read_size], addr);
        defer self.allocator.free(formatted);
        try writer.print("{s}", .{formatted});
    }

    /// Show local variables.
    fn showLocals(self: *Self, writer: anytype) !void {
        if (self.debugger.process == null) {
            try writer.print("No process.\n", .{});
            return;
        }

        if (self.debugger.getLocalVariables()) |locals| {
            defer self.allocator.free(locals);

            if (locals.len == 0) {
                try writer.print("No locals found.\n", .{});
                return;
            }

            for (locals) |local| {
                try writer.print("{s}", .{local.name});
                if (local.type_name) |t| {
                    try writer.print(" : {s}", .{t});
                }
                if (local.location) |loc| {
                    switch (loc) {
                        .register => |reg| try writer.print(" (reg{d})", .{reg}),
                        .address => |addr| try writer.print(" (0x{x})", .{addr}),
                        .frame_offset => |off| try writer.print(" (rbp{d:+})", .{off}),
                        .value => |v| try writer.print(" = {d}", .{v}),
                    }
                }
                try writer.print("\n", .{});
            }
        } else {
            try writer.print("No debug info available.\n", .{});
        }
    }

    /// Show source code around current location.
    fn showSource(self: *Self, writer: anytype, line_arg: ?[]const u8) !void {
        if (self.debugger.process == null) {
            try writer.print("No process.\n", .{});
            return;
        }

        const pc = self.debugger.getPC() catch {
            try writer.print("Cannot get current location.\n", .{});
            return;
        };

        // Get source location for current PC
        const loc = self.debugger.getSourceLocation(pc) orelse {
            try writer.print("No source info for 0x{x}\n", .{pc});
            return;
        };

        // Get filename
        const filename = self.debugger.getFileName(loc.file) orelse {
            try writer.print("Unknown source file.\n", .{});
            return;
        };

        // Determine which line to show
        const target_line = if (line_arg) |arg|
            std.fmt.parseInt(u32, arg, 10) catch loc.line
        else
            loc.line;

        // Get source lines (5 before and after)
        const context: u32 = 5;
        const start_line = if (target_line > context) target_line - context else 1;

        try writer.print("{s}:\n", .{filename});

        // Read and display source
        const content = self.debugger.getSourceContent(filename) orelse {
            try writer.print("(source file not found)\n", .{});
            return;
        };

        var line_num: u32 = 1;
        var line_start: usize = 0;

        for (content, 0..) |c, i| {
            if (c == '\n') {
                if (line_num >= start_line and line_num <= target_line + context) {
                    const marker: []const u8 = if (line_num == loc.line) ">" else " ";
                    try writer.print("{s} {d:>4} | {s}\n", .{ marker, line_num, content[line_start..i] });
                }
                line_start = i + 1;
                line_num += 1;
                if (line_num > target_line + context) break;
            }
        }

        // Handle last line without newline
        if (line_num >= start_line and line_num <= target_line + context and line_start < content.len) {
            const marker: []const u8 = if (line_num == loc.line) ">" else " ";
            try writer.print("{s} {d:>4} | {s}\n", .{ marker, line_num, content[line_start..] });
        }
    }

    /// Show disassembly at current location.
    fn showDisassembly(self: *Self, writer: anytype, count_arg: ?[]const u8) !void {
        if (self.debugger.process == null) {
            try writer.print("No process.\n", .{});
            return;
        }

        const pc = self.debugger.getPC() catch {
            try writer.print("Cannot get current location.\n", .{});
            return;
        };

        const count = if (count_arg) |arg|
            std.fmt.parseInt(usize, arg, 10) catch 10
        else
            10;

        // Read code bytes
        var code: [256]u8 = undefined;
        self.debugger.process.?.readMemory(pc, &code) catch {
            try writer.print("Cannot read memory at 0x{x}\n", .{pc});
            return;
        };

        // Disassemble
        const insns = disasm.disassembleN(self.allocator, &code, pc, count) catch {
            try writer.print("Disassembly failed.\n", .{});
            return;
        };
        defer {
            for (insns) |insn| {
                self.allocator.free(insn.bytes);
                // Only free operands if it was allocated (not a static string)
                if (insn.operands.len > 0) {
                    const static_ops = [_][]const u8{ "rbp", "rsp", "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "" };
                    var is_static = false;
                    for (static_ops) |s| {
                        if (insn.operands.ptr == s.ptr) {
                            is_static = true;
                            break;
                        }
                    }
                    if (!is_static) {
                        self.allocator.free(insn.operands);
                    }
                }
            }
            self.allocator.free(insns);
        }

        // Get symbol name if available
        if (self.debugger.elf) |*elf| {
            if (elf.symbolAt(pc)) |sym| {
                try writer.print("Dump of assembler code for function {s}:\n", .{sym.name});
            }
        }

        for (insns) |insn| {
            const formatted = disasm.formatInstruction(self.allocator, insn) catch continue;
            defer self.allocator.free(formatted);

            const marker: []const u8 = if (insn.address == pc) "=> " else "   ";
            try writer.print("{s}{s}\n", .{ marker, formatted });
        }
    }
};

test "cli init" {
    // Just test that types compile
    _ = Cli;
}
