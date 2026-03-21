//! Process controller using ptrace
//!
//! Wraps Linux ptrace system calls for process control.

const std = @import("std");
const builtin = @import("builtin");
const Registers = @import("regs.zig").Registers;

/// Process state.
pub const ProcessState = enum {
    stopped,
    running,
    exited,
    signaled,
};

/// Wait result from waitpid.
pub const WaitResult = struct {
    state: ProcessState,
    signal: ?u8,
    exit_code: ?u8,
};

/// Process controller.
pub const Process = struct {
    pid: i32,
    state: ProcessState,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Spawn a new process for debugging.
    pub fn spawn(allocator: std.mem.Allocator, path: []const u8, args: []const []const u8) !Self {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }

        // Fork and exec with PTRACE_TRACEME
        const pid = try std.posix.fork();

        if (pid == 0) {
            // Child process
            // Request to be traced
            _ = std.os.linux.ptrace(.TRACEME, 0, 0, 0);

            // Build argv
            var argv_buf: [256][*:0]const u8 = undefined;
            var argc: usize = 0;

            // Add program name
            argv_buf[argc] = @ptrCast(path.ptr);
            argc += 1;

            // Add arguments
            for (args) |arg| {
                if (argc >= argv_buf.len - 1) break;
                argv_buf[argc] = @ptrCast(arg.ptr);
                argc += 1;
            }
            argv_buf[argc] = null;

            // Execute
            const argv: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_buf);
            const result = std.os.linux.execve(
                @ptrCast(path.ptr),
                argv,
                @ptrCast(std.os.environ.ptr),
            );
            _ = result;

            // If we get here, exec failed
            std.process.exit(127);
        }

        // Parent process
        var self = Self{
            .pid = @intCast(pid),
            .state = .stopped,
            .allocator = allocator,
        };

        // Wait for child to stop
        _ = try self.wait();

        return self;
    }

    /// Attach to a running process.
    pub fn attach(pid: i32) !Self {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }

        const result = std.os.linux.ptrace(.ATTACH, @intCast(pid), 0, 0);
        if (result != 0) {
            return error.AttachFailed;
        }

        var self = Self{
            .pid = pid,
            .state = .stopped,
            .allocator = undefined,
        };

        // Wait for process to stop
        _ = try self.wait();

        return self;
    }

    /// Detach from the process.
    pub fn detach(self: *Self) !void {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }

        const result = std.os.linux.ptrace(.DETACH, @intCast(self.pid), 0, 0);
        if (result != 0) {
            return error.DetachFailed;
        }
        self.state = .exited;
    }

    /// Continue execution.
    pub fn continue_(self: *Self, signal: ?u32) !void {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }

        const sig: usize = signal orelse 0;
        const result = std.os.linux.ptrace(.CONT, @intCast(self.pid), 0, sig);
        if (result != 0) {
            return error.ContinueFailed;
        }
        self.state = .running;
    }

    /// Single step one instruction.
    pub fn singleStep(self: *Self) !void {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }

        const result = std.os.linux.ptrace(.SINGLESTEP, @intCast(self.pid), 0, 0);
        if (result != 0) {
            return error.SingleStepFailed;
        }
        self.state = .running;
    }

    /// Get registers.
    pub fn getRegisters(self: *Self) !Registers {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }

        var regs: Registers = std.mem.zeroes(Registers);
        const result = std.os.linux.ptrace(.GETREGS, @intCast(self.pid), 0, @intFromPtr(&regs));
        if (result != 0) {
            return error.GetRegsFailed;
        }
        return regs;
    }

    /// Set registers.
    pub fn setRegisters(self: *Self, regs: *Registers) !void {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }

        const result = std.os.linux.ptrace(.SETREGS, @intCast(self.pid), 0, @intFromPtr(regs));
        if (result != 0) {
            return error.SetRegsFailed;
        }
    }

    /// Read memory from the process.
    pub fn readMemory(self: *Self, addr: u64, buf: []u8) !void {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }

        var offset: usize = 0;
        while (offset < buf.len) {
            const result = std.os.linux.ptrace(.PEEKDATA, @intCast(self.pid), addr + offset, 0);
            const word: u64 = @bitCast(result);

            const remaining = buf.len - offset;
            const to_copy = @min(remaining, @sizeOf(u64));

            const bytes: *const [8]u8 = @ptrCast(&word);
            @memcpy(buf[offset..][0..to_copy], bytes[0..to_copy]);

            offset += @sizeOf(u64);
        }
    }

    /// Write memory to the process.
    pub fn writeMemory(self: *Self, addr: u64, data: []const u8) !void {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }

        var offset: usize = 0;
        while (offset < data.len) {
            var word: u64 = 0;

            // Read existing data for partial writes
            if (offset + @sizeOf(u64) > data.len) {
                const result = std.os.linux.ptrace(.PEEKDATA, @intCast(self.pid), addr + offset, 0);
                word = @bitCast(result);
            }

            // Copy new data
            const remaining = data.len - offset;
            const to_copy = @min(remaining, @sizeOf(u64));

            const bytes: *[8]u8 = @ptrCast(&word);
            @memcpy(bytes[0..to_copy], data[offset..][0..to_copy]);

            // Write word
            const result = std.os.linux.ptrace(.POKEDATA, @intCast(self.pid), addr + offset, word);
            if (result != 0) {
                return error.WriteMemoryFailed;
            }

            offset += @sizeOf(u64);
        }
    }

    /// Wait for process state change.
    pub fn wait(self: *Self) !WaitResult {
        var status: u32 = 0;
        const result = std.os.linux.waitpid(self.pid, &status, 0);
        if (result < 0) {
            return error.WaitFailed;
        }

        // Parse status
        if (std.os.linux.W.IFEXITED(status)) {
            self.state = .exited;
            return WaitResult{
                .state = .exited,
                .signal = null,
                .exit_code = @truncate(std.os.linux.W.EXITSTATUS(status)),
            };
        } else if (std.os.linux.W.IFSIGNALED(status)) {
            self.state = .signaled;
            return WaitResult{
                .state = .signaled,
                .signal = @truncate(std.os.linux.W.TERMSIG(status)),
                .exit_code = null,
            };
        } else if (std.os.linux.W.IFSTOPPED(status)) {
            self.state = .stopped;
            return WaitResult{
                .state = .stopped,
                .signal = @truncate(std.os.linux.W.STOPSIG(status)),
                .exit_code = null,
            };
        }

        return WaitResult{
            .state = .stopped,
            .signal = null,
            .exit_code = null,
        };
    }
};

test "process state enum" {
    const state = ProcessState.stopped;
    try std.testing.expect(state == .stopped);
}
