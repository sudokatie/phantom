//! x86-64 register definitions
//!
//! Maps to the Linux ptrace user_regs_struct.

const std = @import("std");

/// x86-64 registers as returned by PTRACE_GETREGS.
/// Must match Linux's user_regs_struct exactly.
pub const Registers = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rax: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    orig_rax: u64,
    rip: u64,
    cs: u64,
    eflags: u64,
    rsp: u64,
    ss: u64,
    fs_base: u64,
    gs_base: u64,
    ds: u64,
    es: u64,
    fs: u64,
    gs: u64,

    const Self = @This();

    /// Get register by name.
    pub fn get(self: *const Self, name: []const u8) ?u64 {
        if (std.mem.eql(u8, name, "rax")) return self.rax;
        if (std.mem.eql(u8, name, "rbx")) return self.rbx;
        if (std.mem.eql(u8, name, "rcx")) return self.rcx;
        if (std.mem.eql(u8, name, "rdx")) return self.rdx;
        if (std.mem.eql(u8, name, "rsi")) return self.rsi;
        if (std.mem.eql(u8, name, "rdi")) return self.rdi;
        if (std.mem.eql(u8, name, "rbp")) return self.rbp;
        if (std.mem.eql(u8, name, "rsp")) return self.rsp;
        if (std.mem.eql(u8, name, "r8")) return self.r8;
        if (std.mem.eql(u8, name, "r9")) return self.r9;
        if (std.mem.eql(u8, name, "r10")) return self.r10;
        if (std.mem.eql(u8, name, "r11")) return self.r11;
        if (std.mem.eql(u8, name, "r12")) return self.r12;
        if (std.mem.eql(u8, name, "r13")) return self.r13;
        if (std.mem.eql(u8, name, "r14")) return self.r14;
        if (std.mem.eql(u8, name, "r15")) return self.r15;
        if (std.mem.eql(u8, name, "rip")) return self.rip;
        if (std.mem.eql(u8, name, "eflags")) return self.eflags;
        return null;
    }

    /// Set register by name.
    pub fn set(self: *Self, name: []const u8, value: u64) !void {
        if (std.mem.eql(u8, name, "rax")) {
            self.rax = value;
        } else if (std.mem.eql(u8, name, "rbx")) {
            self.rbx = value;
        } else if (std.mem.eql(u8, name, "rcx")) {
            self.rcx = value;
        } else if (std.mem.eql(u8, name, "rdx")) {
            self.rdx = value;
        } else if (std.mem.eql(u8, name, "rsi")) {
            self.rsi = value;
        } else if (std.mem.eql(u8, name, "rdi")) {
            self.rdi = value;
        } else if (std.mem.eql(u8, name, "rbp")) {
            self.rbp = value;
        } else if (std.mem.eql(u8, name, "rsp")) {
            self.rsp = value;
        } else if (std.mem.eql(u8, name, "rip")) {
            self.rip = value;
        } else {
            return error.UnknownRegister;
        }
    }

    /// Get register by DWARF register number.
    pub fn getByDwarfNum(self: *const Self, num: u8) ?u64 {
        return switch (num) {
            0 => self.rax,
            1 => self.rdx,
            2 => self.rcx,
            3 => self.rbx,
            4 => self.rsi,
            5 => self.rdi,
            6 => self.rbp,
            7 => self.rsp,
            8 => self.r8,
            9 => self.r9,
            10 => self.r10,
            11 => self.r11,
            12 => self.r12,
            13 => self.r13,
            14 => self.r14,
            15 => self.r15,
            16 => self.rip,
            else => null,
        };
    }

    /// Format registers for display.
    pub fn format(self: *const Self, writer: anytype) !void {
        try writer.print("rax: 0x{x:0>16}  rbx: 0x{x:0>16}\n", .{ self.rax, self.rbx });
        try writer.print("rcx: 0x{x:0>16}  rdx: 0x{x:0>16}\n", .{ self.rcx, self.rdx });
        try writer.print("rsi: 0x{x:0>16}  rdi: 0x{x:0>16}\n", .{ self.rsi, self.rdi });
        try writer.print("rbp: 0x{x:0>16}  rsp: 0x{x:0>16}\n", .{ self.rbp, self.rsp });
        try writer.print("r8:  0x{x:0>16}  r9:  0x{x:0>16}\n", .{ self.r8, self.r9 });
        try writer.print("r10: 0x{x:0>16}  r11: 0x{x:0>16}\n", .{ self.r10, self.r11 });
        try writer.print("r12: 0x{x:0>16}  r13: 0x{x:0>16}\n", .{ self.r12, self.r13 });
        try writer.print("r14: 0x{x:0>16}  r15: 0x{x:0>16}\n", .{ self.r14, self.r15 });
        try writer.print("rip: 0x{x:0>16}  eflags: 0x{x:0>16}\n", .{ self.rip, self.eflags });
    }
};

/// DWARF register number to name mapping.
pub const dwarf_reg_names = [_][]const u8{
    "rax", "rdx", "rcx", "rbx", "rsi", "rdi", "rbp", "rsp",
    "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15",
    "rip",
};

test "registers get" {
    var regs = std.mem.zeroes(Registers);
    regs.rax = 0x1234;
    try std.testing.expect(regs.get("rax").? == 0x1234);
    try std.testing.expect(regs.get("invalid") == null);
}

test "registers DWARF mapping" {
    var regs = std.mem.zeroes(Registers);
    regs.rax = 42;
    try std.testing.expect(regs.getByDwarfNum(0).? == 42);
}

test "registers set" {
    var regs = std.mem.zeroes(Registers);
    try regs.set("rax", 0x1234);
    try std.testing.expect(regs.rax == 0x1234);
}

test "registers set invalid" {
    var regs = std.mem.zeroes(Registers);
    try std.testing.expectError(error.UnknownRegister, regs.set("invalid", 0));
}

test "dwarf register names" {
    try std.testing.expect(std.mem.eql(u8, dwarf_reg_names[0], "rax"));
    try std.testing.expect(std.mem.eql(u8, dwarf_reg_names[16], "rip"));
}
