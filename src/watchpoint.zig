//! Hardware watchpoint support using x86-64 debug registers
//!
//! Uses DR0-DR3 for addresses and DR7 for control.
//! Supports read, write, and read/write watchpoints.

const std = @import("std");
const builtin = @import("builtin");

/// Watchpoint trigger condition.
pub const WatchCondition = enum(u2) {
    /// Break on execution (like hardware breakpoint)
    execute = 0b00,
    /// Break on write only
    write = 0b01,
    /// Break on I/O read/write (not typically used)
    io = 0b10,
    /// Break on read or write
    read_write = 0b11,
};

/// Watchpoint size (must match actual memory access size for best results).
pub const WatchSize = enum(u2) {
    /// 1 byte
    byte = 0b00,
    /// 2 bytes
    word = 0b01,
    /// 8 bytes (only on 64-bit)
    qword = 0b10,
    /// 4 bytes
    dword = 0b11,
};

/// A single watchpoint.
pub const Watchpoint = struct {
    /// Debug register index (0-3)
    index: u2,
    /// Address being watched
    address: u64,
    /// Trigger condition
    condition: WatchCondition,
    /// Size of watched region
    size: WatchSize,
    /// Whether the watchpoint is enabled
    enabled: bool,

    const Self = @This();

    /// Get the byte size of the watched region.
    pub fn byteSize(self: Self) usize {
        return switch (self.size) {
            .byte => 1,
            .word => 2,
            .dword => 4,
            .qword => 8,
        };
    }

    /// Format watchpoint for display.
    pub fn format(self: Self, writer: anytype) !void {
        const cond_str = switch (self.condition) {
            .execute => "exec",
            .write => "write",
            .io => "io",
            .read_write => "rw",
        };
        const status = if (self.enabled) "enabled" else "disabled";
        try writer.print("wp{d}: 0x{x:0>16} ({s}, {d} bytes) [{s}]", .{
            self.index,
            self.address,
            cond_str,
            self.byteSize(),
            status,
        });
    }
};

/// Watchpoint manager.
pub const WatchpointManager = struct {
    /// Active watchpoints (max 4 on x86-64)
    watchpoints: [4]?Watchpoint,
    /// Process ID for ptrace calls
    pid: i32,

    const Self = @This();

    /// Debug register offsets in user struct (Linux x86-64).
    /// These are the byte offsets to u_debugreg[0..7] in struct user.
    const DR_OFFSET_BASE: usize = 848;

    /// Initialize watchpoint manager for a process.
    pub fn init(pid: i32) Self {
        return Self{
            .watchpoints = .{ null, null, null, null },
            .pid = pid,
        };
    }

    /// Set a watchpoint.
    pub fn set(self: *Self, address: u64, condition: WatchCondition, size: WatchSize) !u2 {
        // Find free slot
        var slot: ?u2 = null;
        for (0..4) |i| {
            if (self.watchpoints[i] == null) {
                slot = @intCast(i);
                break;
            }
        }

        const index = slot orelse return error.NoFreeWatchpoint;

        // Create watchpoint
        const wp = Watchpoint{
            .index = index,
            .address = address,
            .condition = condition,
            .size = size,
            .enabled = true,
        };

        // Write to debug registers
        try self.writeDebugRegs(wp);

        self.watchpoints[index] = wp;
        return index;
    }

    /// Remove a watchpoint.
    pub fn remove(self: *Self, index: u2) !void {
        if (self.watchpoints[index] == null) {
            return error.WatchpointNotSet;
        }

        // Disable in DR7
        try self.disableInDr7(index);

        self.watchpoints[index] = null;
    }

    /// Enable a watchpoint.
    pub fn enable(self: *Self, index: u2) !void {
        var wp = self.watchpoints[index] orelse return error.WatchpointNotSet;
        wp.enabled = true;
        self.watchpoints[index] = wp;
        try self.writeDebugRegs(wp);
    }

    /// Disable a watchpoint.
    pub fn disable(self: *Self, index: u2) !void {
        var wp = self.watchpoints[index] orelse return error.WatchpointNotSet;
        wp.enabled = false;
        self.watchpoints[index] = wp;
        try self.disableInDr7(index);
    }

    /// List all watchpoints.
    pub fn list(self: *const Self, writer: anytype) !void {
        var active: usize = 0;
        for (self.watchpoints, 0..) |maybe_wp, i| {
            if (maybe_wp) |wp| {
                try wp.format(writer);
                try writer.print("\n", .{});
                active += 1;
            }
            _ = i;
        }
        if (active == 0) {
            try writer.print("No watchpoints set.\n", .{});
        }
    }

    /// Get watchpoint at index.
    pub fn get(self: *const Self, index: u2) ?Watchpoint {
        return self.watchpoints[index];
    }

    /// Check which watchpoint triggered (reads DR6).
    pub fn checkTriggered(self: *const Self) !?u2 {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }

        // Read DR6 (index 6)
        const dr6 = try self.readDebugReg(6);

        // Bits 0-3 indicate which DR triggered
        for (0..4) |i| {
            if ((dr6 & (@as(u64, 1) << @intCast(i))) != 0) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Clear triggered status (write to DR6).
    pub fn clearTriggered(self: *Self) !void {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }
        // Clear the breakpoint detection bits (0-3)
        try self.writeDebugReg(6, 0);
    }

    /// Get count of active watchpoints.
    pub fn count(self: *const Self) usize {
        var n: usize = 0;
        for (self.watchpoints) |wp| {
            if (wp != null) n += 1;
        }
        return n;
    }

    // Internal: Write watchpoint to debug registers.
    fn writeDebugRegs(self: *Self, wp: Watchpoint) !void {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }

        // Write address to DR0-DR3
        try self.writeDebugReg(wp.index, wp.address);

        // Update DR7
        var dr7 = try self.readDebugReg(7);

        // Clear existing settings for this watchpoint
        const clear_mask = ~((@as(u64, 0b11) << (@as(u6, wp.index) * 2)) | // local/global enable
            (@as(u64, 0b1111) << (16 + @as(u6, wp.index) * 4))); // condition/length
        dr7 &= clear_mask;

        if (wp.enabled) {
            // Set local enable bit (bit 2*index)
            dr7 |= @as(u64, 1) << (@as(u6, wp.index) * 2);

            // Set condition (bits 16+index*4 to 17+index*4)
            dr7 |= @as(u64, @intFromEnum(wp.condition)) << (16 + @as(u6, wp.index) * 4);

            // Set length (bits 18+index*4 to 19+index*4)
            dr7 |= @as(u64, @intFromEnum(wp.size)) << (18 + @as(u6, wp.index) * 4);
        }

        try self.writeDebugReg(7, dr7);
    }

    // Internal: Disable watchpoint in DR7.
    fn disableInDr7(self: *Self, index: u2) !void {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }

        var dr7 = try self.readDebugReg(7);

        // Clear local and global enable bits
        dr7 &= ~(@as(u64, 0b11) << (@as(u6, index) * 2));

        try self.writeDebugReg(7, dr7);
    }

    // Internal: Read debug register via ptrace.
    fn readDebugReg(self: *const Self, index: usize) !u64 {
        const offset = DR_OFFSET_BASE + index * 8;
        const result = std.os.linux.ptrace(
            .PEEKUSER,
            @intCast(self.pid),
            offset,
            0,
        );
        if (result < 0) {
            return error.PtraceError;
        }
        return @bitCast(result);
    }

    // Internal: Write debug register via ptrace.
    fn writeDebugReg(self: *Self, index: usize, value: u64) !void {
        const offset = DR_OFFSET_BASE + index * 8;
        const result = std.os.linux.ptrace(
            .POKEUSER,
            @intCast(self.pid),
            offset,
            @bitCast(value),
        );
        if (result < 0) {
            return error.PtraceError;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "watchpoint condition enum" {
    try std.testing.expect(@intFromEnum(WatchCondition.execute) == 0);
    try std.testing.expect(@intFromEnum(WatchCondition.write) == 1);
    try std.testing.expect(@intFromEnum(WatchCondition.read_write) == 3);
}

test "watchpoint size enum" {
    try std.testing.expect(@intFromEnum(WatchSize.byte) == 0);
    try std.testing.expect(@intFromEnum(WatchSize.word) == 1);
    try std.testing.expect(@intFromEnum(WatchSize.dword) == 3);
    try std.testing.expect(@intFromEnum(WatchSize.qword) == 2);
}

test "watchpoint byte size" {
    const wp_byte = Watchpoint{
        .index = 0,
        .address = 0x1000,
        .condition = .write,
        .size = .byte,
        .enabled = true,
    };
    try std.testing.expect(wp_byte.byteSize() == 1);

    const wp_qword = Watchpoint{
        .index = 1,
        .address = 0x2000,
        .condition = .read_write,
        .size = .qword,
        .enabled = true,
    };
    try std.testing.expect(wp_qword.byteSize() == 8);
}

test "watchpoint manager init" {
    const mgr = WatchpointManager.init(1234);
    try std.testing.expect(mgr.pid == 1234);
    try std.testing.expect(mgr.count() == 0);
}

test "watchpoint manager slot tracking" {
    var mgr = WatchpointManager.init(1234);

    // Manually add watchpoints (bypassing ptrace for test)
    mgr.watchpoints[0] = Watchpoint{
        .index = 0,
        .address = 0x1000,
        .condition = .write,
        .size = .dword,
        .enabled = true,
    };
    try std.testing.expect(mgr.count() == 1);
    try std.testing.expect(mgr.get(0) != null);
    try std.testing.expect(mgr.get(1) == null);

    mgr.watchpoints[2] = Watchpoint{
        .index = 2,
        .address = 0x2000,
        .condition = .read_write,
        .size = .byte,
        .enabled = true,
    };
    try std.testing.expect(mgr.count() == 2);

    // Clear
    mgr.watchpoints[0] = null;
    try std.testing.expect(mgr.count() == 1);
}

test "watchpoint format" {
    const wp = Watchpoint{
        .index = 0,
        .address = 0x7fff12345678,
        .condition = .write,
        .size = .dword,
        .enabled = true,
    };

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try wp.format(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "wp0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "write") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "enabled") != null);
}

test "dr7 bit calculations" {
    // Test that our bit shifts work correctly
    const index: u2 = 2;

    // Local enable should be at bit 4 (index * 2)
    const enable_bit = @as(u64, 1) << (@as(u6, index) * 2);
    try std.testing.expect(enable_bit == 0b10000);

    // Condition should be at bits 24-25 (16 + index * 4)
    const cond_shift = 16 + @as(u6, index) * 4;
    try std.testing.expect(cond_shift == 24);

    // Size should be at bits 26-27 (18 + index * 4)
    const size_shift = 18 + @as(u6, index) * 4;
    try std.testing.expect(size_shift == 26);
}

test "watchpoint disabled format" {
    const wp = Watchpoint{
        .index = 1,
        .address = 0x1000,
        .condition = .read_write,
        .size = .byte,
        .enabled = false,
    };

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try wp.format(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rw") != null);
}
