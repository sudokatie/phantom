//! Breakpoint management
//!
//! Handles software breakpoints using int3 (0xCC) on x86-64.

const std = @import("std");
const Process = @import("process.zig").Process;

/// A software breakpoint.
pub const Breakpoint = struct {
    id: u32,
    address: u64,
    original_byte: u8,
    enabled: bool,
    hit_count: u32,
    one_shot: bool,

    const Self = @This();

    pub fn init(id: u32, address: u64, original_byte: u8) Self {
        return Self{
            .id = id,
            .address = address,
            .original_byte = original_byte,
            .enabled = true,
            .hit_count = 0,
            .one_shot = false,
        };
    }

    pub fn initOneShot(id: u32, address: u64, original_byte: u8) Self {
        return Self{
            .id = id,
            .address = address,
            .original_byte = original_byte,
            .enabled = true,
            .hit_count = 0,
            .one_shot = true,
        };
    }
};

/// Manages breakpoints for a debugged process.
pub const BreakpointManager = struct {
    allocator: std.mem.Allocator,
    breakpoints: std.AutoHashMap(u64, Breakpoint),
    by_id: std.AutoHashMap(u32, u64),
    next_id: u32,

    const Self = @This();
    const INT3: u8 = 0xCC;

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .breakpoints = std.AutoHashMap(u64, Breakpoint).init(allocator),
            .by_id = std.AutoHashMap(u32, u64).init(allocator),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *Self) void {
        self.breakpoints.deinit();
        self.by_id.deinit();
    }

    /// Set a breakpoint at the given address.
    pub fn set(self: *Self, process: *Process, addr: u64) !u32 {
        return self.setInternal(process, addr, false);
    }

    /// Set a one-shot breakpoint (disables after first hit).
    pub fn setOneShot(self: *Self, process: *Process, addr: u64) !u32 {
        return self.setInternal(process, addr, true);
    }

    fn setInternal(self: *Self, process: *Process, addr: u64, one_shot: bool) !u32 {
        // Check if breakpoint already exists
        if (self.breakpoints.contains(addr)) {
            return error.BreakpointExists;
        }

        // Read original byte
        var buf: [1]u8 = undefined;
        try process.readMemory(addr, &buf);

        // Write int3
        try process.writeMemory(addr, &[_]u8{INT3});

        // Store breakpoint
        const id = self.next_id;
        self.next_id += 1;

        const bp = if (one_shot)
            Breakpoint.initOneShot(id, addr, buf[0])
        else
            Breakpoint.init(id, addr, buf[0]);
        try self.breakpoints.put(addr, bp);
        try self.by_id.put(id, addr);

        return id;
    }

    /// Remove a breakpoint by ID.
    pub fn remove(self: *Self, process: *Process, id: u32) !void {
        const addr = self.by_id.get(id) orelse return error.BreakpointNotFound;
        const bp = self.breakpoints.get(addr) orelse return error.BreakpointNotFound;

        // Restore original byte
        try process.writeMemory(addr, &[_]u8{bp.original_byte});

        // Remove from maps
        _ = self.breakpoints.remove(addr);
        _ = self.by_id.remove(id);
    }

    /// Enable a breakpoint.
    pub fn enable(self: *Self, process: *Process, id: u32) !void {
        const addr = self.by_id.get(id) orelse return error.BreakpointNotFound;
        var bp = self.breakpoints.getPtr(addr) orelse return error.BreakpointNotFound;

        if (!bp.enabled) {
            try process.writeMemory(addr, &[_]u8{INT3});
            bp.enabled = true;
        }
    }

    /// Disable a breakpoint.
    pub fn disable(self: *Self, process: *Process, id: u32) !void {
        const addr = self.by_id.get(id) orelse return error.BreakpointNotFound;
        var bp = self.breakpoints.getPtr(addr) orelse return error.BreakpointNotFound;

        if (bp.enabled) {
            try process.writeMemory(addr, &[_]u8{bp.original_byte});
            bp.enabled = false;
        }
    }

    /// Check if an address has a breakpoint.
    pub fn isBreakpoint(self: *Self, addr: u64) bool {
        return self.breakpoints.contains(addr);
    }

    /// Handle a breakpoint hit.
    /// Returns true if it was our breakpoint.
    pub fn handleHit(self: *Self, process: *Process, addr: u64) !bool {
        // Breakpoint address is one past the int3
        const bp_addr = addr - 1;

        var bp = self.breakpoints.getPtr(bp_addr) orelse return false;
        bp.hit_count += 1;

        // Restore original byte
        try process.writeMemory(bp_addr, &[_]u8{bp.original_byte});

        // Adjust RIP back to breakpoint
        var regs = try process.getRegisters();
        regs.rip = bp_addr;
        try process.setRegisters(&regs);

        // Disable one-shot breakpoints after first hit
        if (bp.one_shot) {
            bp.enabled = false;
        }

        return true;
    }

    /// Re-enable breakpoint after single step.
    pub fn reEnable(self: *Self, process: *Process, addr: u64) !void {
        const bp = self.breakpoints.get(addr) orelse return;
        if (bp.enabled) {
            try process.writeMemory(addr, &[_]u8{INT3});
        }
    }

    /// Get all breakpoints.
    pub fn list(self: *Self) []const Breakpoint {
        var result = std.ArrayList(Breakpoint).init(self.allocator);
        var it = self.breakpoints.valueIterator();
        while (it.next()) |bp| {
            result.append(bp.*) catch {};
        }
        return result.toOwnedSlice() catch &[_]Breakpoint{};
    }
};

test "breakpoint init" {
    const bp = Breakpoint.init(1, 0x401000, 0x55);
    try std.testing.expect(bp.id == 1);
    try std.testing.expect(bp.address == 0x401000);
    try std.testing.expect(bp.enabled);
    try std.testing.expect(!bp.one_shot);
}

test "breakpoint one-shot init" {
    const bp = Breakpoint.initOneShot(1, 0x401000, 0x55);
    try std.testing.expect(bp.id == 1);
    try std.testing.expect(bp.enabled);
    try std.testing.expect(bp.one_shot);
}

test "breakpoint manager init" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expect(mgr.next_id == 1);
}
