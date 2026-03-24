//! Simple x86-64 disassembler
//!
//! Decodes common x86-64 instructions for debugger display.

const std = @import("std");

/// Disassembled instruction.
pub const Instruction = struct {
    address: u64,
    bytes: []const u8,
    mnemonic: []const u8,
    operands: []const u8,
    length: u8,
};

/// Disassemble a single instruction.
pub fn disassemble(allocator: std.mem.Allocator, code: []const u8, address: u64) !Instruction {
    if (code.len == 0) return error.NoCode;

    var len: u8 = 1;
    var mnemonic: []const u8 = "???";
    var operands: []const u8 = "";

    // REX prefix
    var rex: u8 = 0;
    var pos: usize = 0;

    if (code[pos] >= 0x40 and code[pos] <= 0x4f) {
        rex = code[pos];
        pos += 1;
        len += 1;
        if (pos >= code.len) return makeInstruction(allocator, address, code[0..len], "???", "");
    }

    if (pos >= code.len) return makeInstruction(allocator, address, code[0..len], "???", "");

    const opcode = code[pos];

    // Two-byte opcodes (0F prefix)
    if (opcode == 0x0f and pos + 1 < code.len) {
        const opcode2 = code[pos + 1];
        len = @intCast(pos + 2);

        switch (opcode2) {
            0x05 => {
                mnemonic = "syscall";
            },
            0x1f => {
                mnemonic = "nop";
                // Multi-byte NOP with ModR/M
                if (pos + 2 < code.len) len += 1;
            },
            0x84 => {
                mnemonic = "je";
                if (pos + 6 <= code.len) {
                    len = @intCast(pos + 6);
                    const rel = std.mem.readInt(i32, code[pos + 2 ..][0..4], .little);
                    const target = @as(i64, @intCast(address)) + len + rel;
                    operands = try std.fmt.allocPrint(allocator, "0x{x}", .{@as(u64, @intCast(target))});
                }
            },
            0x85 => {
                mnemonic = "jne";
                if (pos + 6 <= code.len) {
                    len = @intCast(pos + 6);
                    const rel = std.mem.readInt(i32, code[pos + 2 ..][0..4], .little);
                    const target = @as(i64, @intCast(address)) + len + rel;
                    operands = try std.fmt.allocPrint(allocator, "0x{x}", .{@as(u64, @intCast(target))});
                }
            },
            0xaf => {
                mnemonic = "imul";
                len += 1;
            },
            else => {
                mnemonic = "???";
            },
        }

        return makeInstruction(allocator, address, code[0..len], mnemonic, operands);
    }

    // Single-byte opcodes
    switch (opcode) {
        0x50...0x57 => {
            mnemonic = "push";
            const reg = regName64(opcode - 0x50, rex);
            operands = reg;
        },
        0x58...0x5f => {
            mnemonic = "pop";
            const reg = regName64(opcode - 0x58, rex);
            operands = reg;
        },
        0x89 => {
            mnemonic = "mov";
            len = @intCast(pos + 2);
            if (pos + 1 < code.len) {
                const modrm = code[pos + 1];
                const rm = modrm & 0x07;
                const reg = (modrm >> 3) & 0x07;
                operands = try std.fmt.allocPrint(allocator, "{s}, {s}", .{ regName64(rm, rex), regName64(reg, rex) });
            }
        },
        0x8b => {
            mnemonic = "mov";
            len = @intCast(pos + 2);
            if (pos + 1 < code.len) {
                const modrm = code[pos + 1];
                const rm = modrm & 0x07;
                const reg = (modrm >> 3) & 0x07;
                operands = try std.fmt.allocPrint(allocator, "{s}, {s}", .{ regName64(reg, rex), regName64(rm, rex) });
            }
        },
        0x90 => {
            mnemonic = "nop";
        },
        0xb8...0xbf => {
            mnemonic = "mov";
            const reg = regName64(opcode - 0xb8, rex);
            if (rex & 0x08 != 0 and pos + 9 <= code.len) {
                // 64-bit immediate
                len = @intCast(pos + 9);
                const imm = std.mem.readInt(u64, code[pos + 1 ..][0..8], .little);
                operands = try std.fmt.allocPrint(allocator, "{s}, 0x{x}", .{ reg, imm });
            } else if (pos + 5 <= code.len) {
                // 32-bit immediate
                len = @intCast(pos + 5);
                const imm = std.mem.readInt(u32, code[pos + 1 ..][0..4], .little);
                operands = try std.fmt.allocPrint(allocator, "{s}, 0x{x}", .{ reg, imm });
            }
        },
        0xc3 => {
            mnemonic = "ret";
        },
        0xc9 => {
            mnemonic = "leave";
        },
        0xcc => {
            mnemonic = "int3";
        },
        0xe8 => {
            mnemonic = "call";
            if (pos + 5 <= code.len) {
                len = @intCast(pos + 5);
                const rel = std.mem.readInt(i32, code[pos + 1 ..][0..4], .little);
                const target = @as(i64, @intCast(address)) + len + rel;
                operands = try std.fmt.allocPrint(allocator, "0x{x}", .{@as(u64, @intCast(target))});
            }
        },
        0xe9 => {
            mnemonic = "jmp";
            if (pos + 5 <= code.len) {
                len = @intCast(pos + 5);
                const rel = std.mem.readInt(i32, code[pos + 1 ..][0..4], .little);
                const target = @as(i64, @intCast(address)) + len + rel;
                operands = try std.fmt.allocPrint(allocator, "0x{x}", .{@as(u64, @intCast(target))});
            }
        },
        0xeb => {
            mnemonic = "jmp";
            if (pos + 2 <= code.len) {
                len = @intCast(pos + 2);
                const rel = @as(i8, @bitCast(code[pos + 1]));
                const target = @as(i64, @intCast(address)) + len + rel;
                operands = try std.fmt.allocPrint(allocator, "0x{x}", .{@as(u64, @intCast(target))});
            }
        },
        0x74 => {
            mnemonic = "je";
            if (pos + 2 <= code.len) {
                len = @intCast(pos + 2);
                const rel = @as(i8, @bitCast(code[pos + 1]));
                const target = @as(i64, @intCast(address)) + len + rel;
                operands = try std.fmt.allocPrint(allocator, "0x{x}", .{@as(u64, @intCast(target))});
            }
        },
        0x75 => {
            mnemonic = "jne";
            if (pos + 2 <= code.len) {
                len = @intCast(pos + 2);
                const rel = @as(i8, @bitCast(code[pos + 1]));
                const target = @as(i64, @intCast(address)) + len + rel;
                operands = try std.fmt.allocPrint(allocator, "0x{x}", .{@as(u64, @intCast(target))});
            }
        },
        0x31 => {
            mnemonic = "xor";
            len = @intCast(pos + 2);
            if (pos + 1 < code.len) {
                const modrm = code[pos + 1];
                const rm = modrm & 0x07;
                const reg = (modrm >> 3) & 0x07;
                operands = try std.fmt.allocPrint(allocator, "{s}, {s}", .{ regName64(rm, rex), regName64(reg, rex) });
            }
        },
        0x83 => {
            // sub/add/cmp r/m, imm8
            len = @intCast(pos + 3);
            if (pos + 2 < code.len) {
                const modrm = code[pos + 1];
                const rm = modrm & 0x07;
                const op = (modrm >> 3) & 0x07;
                const imm = @as(i8, @bitCast(code[pos + 2]));
                mnemonic = switch (op) {
                    0 => "add",
                    5 => "sub",
                    7 => "cmp",
                    else => "???",
                };
                operands = try std.fmt.allocPrint(allocator, "{s}, {d}", .{ regName64(rm, rex), imm });
            }
        },
        else => {
            mnemonic = "???";
        },
    }

    return makeInstruction(allocator, address, code[0..len], mnemonic, operands);
}

fn makeInstruction(allocator: std.mem.Allocator, address: u64, bytes: []const u8, mnemonic: []const u8, operands: []const u8) !Instruction {
    return Instruction{
        .address = address,
        .bytes = try allocator.dupe(u8, bytes),
        .mnemonic = mnemonic,
        .operands = operands,
        .length = @intCast(bytes.len),
    };
}

fn regName64(reg: u8, rex: u8) []const u8 {
    const extended = (rex & 0x01) != 0;
    const idx = if (extended) reg + 8 else reg;
    const names = [_][]const u8{
        "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
        "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15",
    };
    if (idx < names.len) return names[idx];
    return "???";
}

/// Disassemble multiple instructions.
pub fn disassembleN(allocator: std.mem.Allocator, code: []const u8, address: u64, count: usize) ![]Instruction {
    var instructions: std.ArrayListUnmanaged(Instruction) = .empty;
    errdefer instructions.deinit(allocator);

    var offset: usize = 0;
    var addr = address;

    while (instructions.items.len < count and offset < code.len) {
        const insn = disassemble(allocator, code[offset..], addr) catch break;
        try instructions.append(allocator, insn);
        offset += insn.length;
        addr += insn.length;
    }

    return instructions.toOwnedSlice(allocator);
}

/// Format instruction for display.
pub fn formatInstruction(allocator: std.mem.Allocator, insn: Instruction) ![]const u8 {
    var hex_buf: [32]u8 = undefined;
    var hex_len: usize = 0;

    for (insn.bytes) |b| {
        const hex = std.fmt.bufPrint(hex_buf[hex_len..], "{x:0>2} ", .{b}) catch break;
        hex_len += hex.len;
    }

    if (insn.operands.len > 0) {
        return std.fmt.allocPrint(allocator, "0x{x:0>16}:  {s:<24} {s:<8} {s}", .{
            insn.address,
            hex_buf[0..hex_len],
            insn.mnemonic,
            insn.operands,
        });
    } else {
        return std.fmt.allocPrint(allocator, "0x{x:0>16}:  {s:<24} {s}", .{
            insn.address,
            hex_buf[0..hex_len],
            insn.mnemonic,
        });
    }
}

// Tests

test "disassemble nop" {
    const allocator = std.testing.allocator;
    const code = [_]u8{0x90};
    const insn = try disassemble(allocator, &code, 0x1000);
    defer allocator.free(insn.bytes);

    try std.testing.expectEqualStrings("nop", insn.mnemonic);
    try std.testing.expectEqual(@as(u8, 1), insn.length);
}

test "disassemble ret" {
    const allocator = std.testing.allocator;
    const code = [_]u8{0xc3};
    const insn = try disassemble(allocator, &code, 0x1000);
    defer allocator.free(insn.bytes);

    try std.testing.expectEqualStrings("ret", insn.mnemonic);
}

test "disassemble int3" {
    const allocator = std.testing.allocator;
    const code = [_]u8{0xcc};
    const insn = try disassemble(allocator, &code, 0x1000);
    defer allocator.free(insn.bytes);

    try std.testing.expectEqualStrings("int3", insn.mnemonic);
}

test "disassemble push rbp" {
    const allocator = std.testing.allocator;
    const code = [_]u8{0x55}; // push rbp
    const insn = try disassemble(allocator, &code, 0x1000);
    defer allocator.free(insn.bytes);

    try std.testing.expectEqualStrings("push", insn.mnemonic);
    try std.testing.expectEqualStrings("rbp", insn.operands);
}

test "disassemble call" {
    const allocator = std.testing.allocator;
    // call rel32 (call 0x1010)
    const code = [_]u8{ 0xe8, 0x0b, 0x00, 0x00, 0x00 };
    const insn = try disassemble(allocator, &code, 0x1000);
    defer allocator.free(insn.bytes);
    defer allocator.free(insn.operands);

    try std.testing.expectEqualStrings("call", insn.mnemonic);
    try std.testing.expectEqual(@as(u8, 5), insn.length);
}

test "disassemble multiple" {
    const allocator = std.testing.allocator;
    // push rbp; mov rbp, rsp; nop; ret
    const code = [_]u8{ 0x55, 0x48, 0x89, 0xe5, 0x90, 0xc3 };
    const insns = try disassembleN(allocator, &code, 0x1000, 10);
    defer {
        for (insns) |insn| {
            allocator.free(insn.bytes);
            if (insn.operands.len > 0 and insn.operands.ptr != "rbp".ptr and
                insn.operands.ptr != "rsp".ptr and insn.operands.ptr != "".ptr)
            {
                allocator.free(insn.operands);
            }
        }
        allocator.free(insns);
    }

    try std.testing.expect(insns.len >= 3);
    try std.testing.expectEqualStrings("push", insns[0].mnemonic);
}

test "format instruction" {
    const allocator = std.testing.allocator;
    const insn = Instruction{
        .address = 0x401000,
        .bytes = &[_]u8{ 0x55 },
        .mnemonic = "push",
        .operands = "rbp",
        .length = 1,
    };

    const formatted = try formatInstruction(allocator, insn);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "push") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "rbp") != null);
}
