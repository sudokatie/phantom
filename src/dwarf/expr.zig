//! DWARF location expression evaluator
//!
//! Implements a stack machine for evaluating DWARF location expressions
//! to determine where variables are stored (registers, memory, etc.).

const std = @import("std");
const types = @import("types.zig");

/// Result of evaluating a location expression.
pub const Location = union(enum) {
    /// Value is in a register.
    register: u8,
    /// Value is at a memory address.
    address: u64,
    /// Value is a constant.
    value: u64,
    /// Location is relative to frame base.
    frame_offset: i64,
};

/// Context for expression evaluation.
pub const EvalContext = struct {
    /// Register values (x86-64: 16 general purpose).
    registers: [16]u64 = [_]u64{0} ** 16,
    /// Frame base address.
    frame_base: u64 = 0,
    /// Memory read callback.
    read_memory: ?*const fn (u64, usize) ?[]const u8 = null,
};

/// DWARF expression evaluator.
pub const ExprEvaluator = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .stack = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit();
    }

    /// Evaluate a location expression.
    pub fn evaluate(self: *Self, expr: []const u8, ctx: EvalContext) !Location {
        self.stack.clearRetainingCapacity();
        var pos: usize = 0;

        while (pos < expr.len) {
            const op = expr[pos];
            pos += 1;

            // Register operations (DW_OP_reg0 - DW_OP_reg31)
            if (op >= types.OP.reg0 and op <= types.OP.reg0 + 31) {
                const reg = op - types.OP.reg0;
                return Location{ .register = reg };
            }

            // Register with offset (DW_OP_breg0 - DW_OP_breg31)
            if (op >= types.OP.breg0 and op <= types.OP.breg0 + 31) {
                const reg = op - types.OP.breg0;
                const offset = try readSleb128(expr, &pos);
                const base = ctx.registers[reg];
                const addr = if (offset >= 0)
                    base +% @as(u64, @intCast(offset))
                else
                    base -% @as(u64, @intCast(-offset));
                try self.stack.append(self.allocator, addr);
                continue;
            }

            switch (op) {
                types.OP.addr => {
                    const addr = try readU64(expr, &pos);
                    try self.stack.append(self.allocator, addr);
                },

                types.OP.const1u => {
                    const val = try readU8(expr, &pos);
                    try self.stack.append(self.allocator, val);
                },

                types.OP.const1s => {
                    const val = @as(i8, @bitCast(try readU8(expr, &pos)));
                    try self.stack.append(self.allocator, @as(u64, @bitCast(@as(i64, val))));
                },

                types.OP.const2u => {
                    const val = try readU16(expr, &pos);
                    try self.stack.append(self.allocator, val);
                },

                types.OP.const2s => {
                    const val = @as(i16, @bitCast(try readU16(expr, &pos)));
                    try self.stack.append(self.allocator, @as(u64, @bitCast(@as(i64, val))));
                },

                types.OP.const4u => {
                    const val = try readU32(expr, &pos);
                    try self.stack.append(self.allocator, val);
                },

                types.OP.const4s => {
                    const val = @as(i32, @bitCast(try readU32(expr, &pos)));
                    try self.stack.append(self.allocator, @as(u64, @bitCast(@as(i64, val))));
                },

                types.OP.const8u => {
                    const val = try readU64(expr, &pos);
                    try self.stack.append(self.allocator, val);
                },

                types.OP.const8s => {
                    const val = try readU64(expr, &pos);
                    try self.stack.append(self.allocator, val);
                },

                types.OP.fbreg => {
                    const offset = try readSleb128(expr, &pos);
                    // Return frame-relative location directly if stack is empty
                    if (self.stack.items.len == 0) {
                        return Location{ .frame_offset = offset };
                    }
                    const addr = if (offset >= 0)
                        ctx.frame_base +% @as(u64, @intCast(offset))
                    else
                        ctx.frame_base -% @as(u64, @intCast(-offset));
                    try self.stack.append(self.allocator, addr);
                },

                types.OP.regx => {
                    const reg = try readUleb128(expr, &pos);
                    return Location{ .register = @intCast(reg) };
                },

                types.OP.bregx => {
                    const reg = try readUleb128(expr, &pos);
                    const offset = try readSleb128(expr, &pos);
                    const base = ctx.registers[@intCast(reg)];
                    const addr = if (offset >= 0)
                        base +% @as(u64, @intCast(offset))
                    else
                        base -% @as(u64, @intCast(-offset));
                    try self.stack.append(self.allocator, addr);
                },

                types.OP.dup => {
                    if (self.stack.items.len == 0) return error.StackUnderflow;
                    const val = self.stack.items[self.stack.items.len - 1];
                    try self.stack.append(self.allocator, val);
                },

                types.OP.drop => {
                    if (self.stack.items.len == 0) return error.StackUnderflow;
                    _ = self.stack.pop();
                },

                types.OP.plus => {
                    if (self.stack.items.len < 2) return error.StackUnderflow;
                    const b = self.stack.pop();
                    const a = self.stack.pop();
                    try self.stack.append(self.allocator, a +% b);
                },

                types.OP.plus_uconst => {
                    if (self.stack.items.len == 0) return error.StackUnderflow;
                    const addend = try readUleb128(expr, &pos);
                    const val = self.stack.pop();
                    try self.stack.append(self.allocator, val +% addend);
                },

                types.OP.minus => {
                    if (self.stack.items.len < 2) return error.StackUnderflow;
                    const b = self.stack.pop();
                    const a = self.stack.pop();
                    try self.stack.append(self.allocator, a -% b);
                },

                types.OP.deref => {
                    if (self.stack.items.len == 0) return error.StackUnderflow;
                    const addr = self.stack.pop();
                    if (ctx.read_memory) |read_fn| {
                        if (read_fn(addr, 8)) |data| {
                            const val = std.mem.readInt(u64, data[0..8], .little);
                            try self.stack.append(self.allocator, val);
                        } else {
                            return error.MemoryReadFailed;
                        }
                    } else {
                        return error.NoMemoryAccess;
                    }
                },

                types.OP.call_frame_cfa => {
                    try self.stack.append(self.allocator, ctx.frame_base);
                },

                else => {
                    // Skip unknown opcodes
                },
            }
        }

        // Return top of stack as address
        if (self.stack.items.len > 0) {
            return Location{ .address = self.stack.items[self.stack.items.len - 1] };
        }

        return error.EmptyExpression;
    }
};

// Helper functions

fn readUleb128(data: []const u8, pos: *usize) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift +%= 7;
        if (shift > 63) return error.Overflow;
    }
    return error.UnexpectedEndOfData;
}

fn readSleb128(data: []const u8, pos: *usize) !i64 {
    var result: i64 = 0;
    var shift: u6 = 0;
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        result |= @as(i64, byte & 0x7f) << shift;
        shift +%= 7;
        if (byte & 0x80 == 0) {
            if (shift < 64 and (byte & 0x40) != 0) {
                result |= @as(i64, -1) << shift;
            }
            return result;
        }
        if (shift > 63) return error.Overflow;
    }
    return error.UnexpectedEndOfData;
}

fn readU8(data: []const u8, pos: *usize) !u8 {
    if (pos.* >= data.len) return error.UnexpectedEndOfData;
    const val = data[pos.*];
    pos.* += 1;
    return val;
}

fn readU16(data: []const u8, pos: *usize) !u16 {
    if (pos.* + 2 > data.len) return error.UnexpectedEndOfData;
    const val = std.mem.readInt(u16, data[pos.*..][0..2], .little);
    pos.* += 2;
    return val;
}

fn readU32(data: []const u8, pos: *usize) !u32 {
    if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
    const val = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return val;
}

fn readU64(data: []const u8, pos: *usize) !u64 {
    if (pos.* + 8 > data.len) return error.UnexpectedEndOfData;
    const val = std.mem.readInt(u64, data[pos.*..][0..8], .little);
    pos.* += 8;
    return val;
}

// Tests

test "evaluate register location" {
    const allocator = std.testing.allocator;
    var eval = ExprEvaluator.init(allocator);
    defer eval.deinit();

    // DW_OP_reg0 (RAX)
    const expr = [_]u8{types.OP.reg0};
    const loc = try eval.evaluate(&expr, .{});

    try std.testing.expect(loc == .register);
    try std.testing.expectEqual(@as(u8, 0), loc.register);
}

test "evaluate frame-relative location" {
    const allocator = std.testing.allocator;
    var eval = ExprEvaluator.init(allocator);
    defer eval.deinit();

    // DW_OP_fbreg -8 (SLEB128)
    const expr = [_]u8{ types.OP.fbreg, 0x78 }; // -8 in SLEB128
    const loc = try eval.evaluate(&expr, .{});

    try std.testing.expect(loc == .frame_offset);
    try std.testing.expectEqual(@as(i64, -8), loc.frame_offset);
}

test "evaluate address" {
    const allocator = std.testing.allocator;
    var eval = ExprEvaluator.init(allocator);
    defer eval.deinit();

    // DW_OP_addr 0x1000
    const expr = [_]u8{ types.OP.addr, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const loc = try eval.evaluate(&expr, .{});

    try std.testing.expect(loc == .address);
    try std.testing.expectEqual(@as(u64, 0x1000), loc.address);
}

test "evaluate breg with offset" {
    const allocator = std.testing.allocator;
    var eval = ExprEvaluator.init(allocator);
    defer eval.deinit();

    // DW_OP_breg7 8 (RDI + 8)
    const expr = [_]u8{ types.OP.breg0 + 7, 0x08 };
    var ctx = EvalContext{};
    ctx.registers[7] = 0x1000;

    const loc = try eval.evaluate(&expr, ctx);

    try std.testing.expect(loc == .address);
    try std.testing.expectEqual(@as(u64, 0x1008), loc.address);
}

test "evaluate plus operation" {
    const allocator = std.testing.allocator;
    var eval = ExprEvaluator.init(allocator);
    defer eval.deinit();

    // Push 0x1000, push 0x10, plus -> 0x1010
    const expr = [_]u8{
        types.OP.const2u,
        0x00,
        0x10, // 0x1000
        types.OP.const1u,
        0x10, // 0x10
        types.OP.plus,
    };

    const loc = try eval.evaluate(&expr, .{});

    try std.testing.expect(loc == .address);
    try std.testing.expectEqual(@as(u64, 0x1010), loc.address);
}

test "evaluate plus_uconst" {
    const allocator = std.testing.allocator;
    var eval = ExprEvaluator.init(allocator);
    defer eval.deinit();

    // Push 0x1000, plus_uconst 8 -> 0x1008
    const expr = [_]u8{
        types.OP.const2u,
        0x00,
        0x10, // 0x1000
        types.OP.plus_uconst,
        0x08, // +8
    };

    const loc = try eval.evaluate(&expr, .{});

    try std.testing.expect(loc == .address);
    try std.testing.expectEqual(@as(u64, 0x1008), loc.address);
}

test "evaluate call_frame_cfa" {
    const allocator = std.testing.allocator;
    var eval = ExprEvaluator.init(allocator);
    defer eval.deinit();

    const expr = [_]u8{types.OP.call_frame_cfa};
    var ctx = EvalContext{};
    ctx.frame_base = 0x7fff0000;

    const loc = try eval.evaluate(&expr, ctx);

    try std.testing.expect(loc == .address);
    try std.testing.expectEqual(@as(u64, 0x7fff0000), loc.address);
}
