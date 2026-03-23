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
        const stdin = std.fs.File.stdin().deprecatedReader();
        const stdout = std.fs.File.stdout().deprecatedWriter();

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
        const stdout = std.fs.File.stdout().deprecatedWriter();

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
        } else if (std.mem.eql(u8, cmd, "attach")) {
            const arg = it.next() orelse {
                try stdout.print("usage: attach <pid>\n", .{});
                return;
            };
            const pid = std.fmt.parseInt(i32, arg, 10) catch {
                try stdout.print("Invalid pid: {s}\n", .{arg});
                return;
            };
            try self.debugger.attach(pid);
            try stdout.print("Attached to process {d}.\n", .{pid});
        } else if (std.mem.eql(u8, cmd, "detach")) {
            if (self.debugger.process == null) {
                try stdout.print("No process to detach from.\n", .{});
                return;
            }
            const pid = self.debugger.process.?.pid;
            try self.debugger.detach();
            try stdout.print("Detached from process {d}.\n", .{pid});
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
        } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "l")) {
            try self.showSourceListing(stdout);
        } else if (std.mem.eql(u8, cmd, "disassemble") or std.mem.eql(u8, cmd, "disas")) {
            const count: usize = blk: {
                if (it.next()) |arg| {
                    break :blk std.fmt.parseInt(usize, arg, 10) catch 10;
                }
                break :blk 10;
            };
            try self.disassemble(stdout, count);
        } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h")) {
            try stdout.print(
                \\Phantom Debugger Commands
                \\
                \\Running:
                \\  run, r [args]     Start/restart program with optional arguments
                \\  attach <pid>      Attach to a running process
                \\  detach            Detach from current process
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
                \\  info locals       Show local variables
                \\  list, l           Show source code around current location
                \\  disassemble, disas [n]  Disassemble n instructions (default: 10)
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

    /// Show source listing around current location.
    fn showSourceListing(self: *Self, writer: anytype) !void {
        if (self.debugger.process == null) {
            try writer.print("No process.\n", .{});
            return;
        }

        const pc = try self.debugger.getPC();

        // Try to get source location from DWARF
        if (self.debugger.dwarf) |*dwarf| {
            if (dwarf.getSourceLocation(pc)) |loc| {
                // Get file name
                const filename = if (loc.file < dwarf.files.items.len)
                    dwarf.files.items[loc.file].name
                else
                    "(unknown)";

                try writer.print("Location: {s}:{d}\n", .{ filename, loc.line });

                // Try to read and display source file
                const file = std.fs.cwd().openFile(filename, .{}) catch {
                    try writer.print("(source file not found)\n", .{});
                    return;
                };
                defer file.close();

                const reader = file.reader();
                var line_num: u32 = 1;
                const start_line = if (loc.line > 5) loc.line - 5 else 1;
                const end_line = loc.line + 5;

                var line_buf: [1024]u8 = undefined;
                while (reader.readUntilDelimiterOrEof(&line_buf, '\n') catch null) |line| {
                    if (line_num >= start_line and line_num <= end_line) {
                        const marker: []const u8 = if (line_num == loc.line) "=>" else "  ";
                        try writer.print("{s} {d:>4}: {s}\n", .{ marker, line_num, line });
                    }
                    line_num += 1;
                    if (line_num > end_line) break;
                }
                return;
            }
        }

        // Fall back to showing address with symbol
        try writer.print("0x{x:0>16}", .{pc});
        if (self.debugger.elf) |*elf| {
            if (elf.symbolAt(pc)) |sym| {
                try writer.print(" in {s}", .{sym.name});
            }
        }
        try writer.print("\n(no source information available)\n", .{});
    }

    /// Disassemble instructions at current PC.
    fn disassemble(self: *Self, writer: anytype, count: usize) !void {
        if (self.debugger.process == null) {
            try writer.print("No process.\n", .{});
            return;
        }

        const pc = try self.debugger.getPC();

        // Read memory at PC
        const bytes_needed = count * 15; // Max x86-64 instruction is 15 bytes
        const data = self.debugger.process.?.readMemory(pc, bytes_needed) catch |err| {
            try writer.print("Cannot read memory at 0x{x}: {}\n", .{ pc, err });
            return;
        };

        try writer.print("Dump of assembler code:\n", .{});

        var offset: usize = 0;
        var insn_count: usize = 0;

        while (offset < data.len and insn_count < count) {
            const addr = pc + offset;

            // Show current instruction marker
            const marker: []const u8 = if (offset == 0) "=> " else "   ";

            // Get symbol info for this address
            var sym_info: []const u8 = "";
            if (self.debugger.elf) |*elf| {
                if (offset == 0) {
                    if (elf.symbolAt(addr)) |sym| {
                        sym_info = sym.name;
                    }
                }
            }

            if (sym_info.len > 0 and offset == 0) {
                try writer.print("<{s}>:\n", .{sym_info});
            }

            // Simple x86-64 instruction decoding (just show hex bytes)
            // Real disassembly would need a full decoder
            const insn_len = decodeInstructionLength(data[offset..]);

            try writer.print("{s}0x{x:0>16}:  ", .{ marker, addr });

            // Print instruction bytes
            var i: usize = 0;
            while (i < insn_len and offset + i < data.len) : (i += 1) {
                try writer.print("{x:0>2} ", .{data[offset + i]});
            }

            // Pad to align mnemonics
            var pad: usize = (7 - @min(insn_len, 7)) * 3;
            while (pad > 0) : (pad -= 1) {
                try writer.print(" ", .{});
            }

            // Decode common instructions
            const mnemonic = decodeInstruction(data[offset..][0..@min(insn_len, data.len - offset)]);
            try writer.print("  {s}\n", .{mnemonic});

            offset += insn_len;
            insn_count += 1;
        }

        try writer.print("End of assembler dump.\n", .{});
    }
};

/// Decode x86-64 instruction length (simplified).
fn decodeInstructionLength(data: []const u8) usize {
    if (data.len == 0) return 1;

    var i: usize = 0;

    // Skip prefixes
    while (i < data.len) {
        const b = data[i];
        if (b == 0x66 or b == 0x67 or b == 0xF0 or b == 0xF2 or b == 0xF3 or
            (b >= 0x40 and b <= 0x4F))
        { // REX prefixes
            i += 1;
        } else {
            break;
        }
    }

    if (i >= data.len) return i;

    const opcode = data[i];
    i += 1;

    // Simple length estimation based on opcode
    return switch (opcode) {
        0x00...0x03, 0x08...0x0B, 0x10...0x13, 0x18...0x1B,
        0x20...0x23, 0x28...0x2B, 0x30...0x33, 0x38...0x3B,
        0x88...0x8B,
        => i + 1, // ModR/M byte
        0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C => i + 1, // imm8
        0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D => i + 4, // imm32
        0x50...0x5F => i, // push/pop reg
        0x70...0x7F => i + 1, // Jcc short
        0x90 => i, // NOP
        0xB0...0xB7 => i + 1, // mov r8, imm8
        0xB8...0xBF => i + 4, // mov r32, imm32 (or 8 with REX.W)
        0xC3 => i, // ret
        0xC9 => i, // leave
        0xCC => i, // int3
        0xCD => i + 1, // int imm8
        0xE8 => i + 4, // call rel32
        0xE9 => i + 4, // jmp rel32
        0xEB => i + 1, // jmp short
        0xFF => i + 1, // call/jmp r/m (simplified)
        0x0F => blk: { // Two-byte opcode
            if (i >= data.len) break :blk i;
            const op2 = data[i];
            i += 1;
            break :blk switch (op2) {
                0x80...0x8F => i + 4, // Jcc near
                0x1F => i + 1, // NOP with ModR/M
                else => i + 1,
            };
        },
        else => i + 1, // Default: assume 1 more byte
    };
}

/// Decode x86-64 instruction to mnemonic (simplified).
fn decodeInstruction(data: []const u8) []const u8 {
    if (data.len == 0) return "(bad)";

    var i: usize = 0;
    var has_rex_w = false;

    // Skip prefixes
    while (i < data.len) {
        const b = data[i];
        if (b >= 0x48 and b <= 0x4F) {
            has_rex_w = true;
            i += 1;
        } else if (b == 0x66 or b == 0x67 or b == 0xF0 or b == 0xF2 or b == 0xF3 or
            (b >= 0x40 and b <= 0x47))
        {
            i += 1;
        } else {
            break;
        }
    }

    if (i >= data.len) return "(bad)";

    const opcode = data[i];

    return switch (opcode) {
        0x50...0x57 => "push",
        0x58...0x5F => "pop",
        0x89 => if (has_rex_w) "mov (r64)" else "mov (r32)",
        0x8B => if (has_rex_w) "mov (r64)" else "mov (r32)",
        0x31 => "xor",
        0x29 => "sub",
        0x01 => "add",
        0x39 => "cmp",
        0x83 => "add/sub/cmp (imm8)",
        0x90 => "nop",
        0xC3 => "ret",
        0xC9 => "leave",
        0xCC => "int3",
        0xE8 => "call",
        0xE9 => "jmp",
        0xEB => "jmp (short)",
        0x74 => "je (short)",
        0x75 => "jne (short)",
        0x7E => "jle (short)",
        0x7F => "jg (short)",
        0x0F => blk: {
            if (i + 1 >= data.len) break :blk "(bad)";
            const op2 = data[i + 1];
            break :blk switch (op2) {
                0x84 => "je",
                0x85 => "jne",
                0x8E => "jle",
                0x8F => "jg",
                0x1F => "nop",
                0xAF => "imul",
                else => "(two-byte)",
            };
        },
        0xFF => "call/jmp (indirect)",
        else => "(unknown)",
    };
}

test "cli init" {
    // Just test that types compile
    _ = Cli;
}
