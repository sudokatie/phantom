//! Expression evaluator for variable inspection
//!
//! Parses simple expressions, looks up variables, and formats output.

const std = @import("std");
const dwarf = @import("dwarf/mod.zig");

/// Type information for formatting.
pub const TypeInfo = union(enum) {
    void_type: void,
    int_type: struct { size: u8, signed: bool },
    float_type: u8, // size
    pointer_type: *const TypeInfo,
    array_type: struct { element: *const TypeInfo, length: u64 },
    struct_type: struct { name: []const u8, size: u64 },
    unknown: void,
};

/// A resolved variable.
pub const Variable = struct {
    name: []const u8,
    location: dwarf.Location,
    type_info: TypeInfo,
};

/// Expression evaluation context.
pub const EvalContext = struct {
    /// Read memory from target process.
    read_memory: ?*const fn (addr: u64, size: usize) ?[]const u8 = null,
    /// Register values.
    registers: [16]u64 = [_]u64{0} ** 16,
    /// Frame base address.
    frame_base: u64 = 0,
};

/// Expression evaluator.
pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    variables: std.StringHashMap(Variable),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .variables = std.StringHashMap(Variable).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.variables.deinit();
    }

    /// Register a variable.
    pub fn addVariable(self: *Self, variable: Variable) !void {
        try self.variables.put(variable.name, variable);
    }

    /// Look up variable by name.
    pub fn lookupVariable(self: *const Self, name: []const u8) ?Variable {
        return self.variables.get(name);
    }

    /// Evaluate expression and return formatted result.
    pub fn evaluate(self: *Self, expr: []const u8, ctx: EvalContext) ![]const u8 {
        // Parse expression
        const parsed = try self.parseExpression(expr);

        // Get variable value
        const value = try self.getValue(parsed, ctx);

        // Format output
        return self.formatValue(value, parsed.type_info);
    }

    /// Parse a simple expression.
    fn parseExpression(self: *const Self, expr: []const u8) !Variable {
        // For now, just look up variable name directly
        // TODO: handle member access (foo.bar) and dereference (*ptr)
        const trimmed = std.mem.trim(u8, expr, " \t\n");

        if (self.lookupVariable(trimmed)) |variable| {
            return variable;
        }

        return error.UnknownVariable;
    }

    /// Get the value of a variable.
    fn getValue(self: *const Self, variable: Variable, ctx: EvalContext) !u64 {
        _ = self;

        switch (variable.location) {
            .register => |reg| {
                return ctx.registers[reg];
            },
            .address => |addr| {
                if (ctx.read_memory) |read_fn| {
                    if (read_fn(addr, 8)) |data| {
                        return std.mem.readInt(u64, data[0..8], .little);
                    }
                }
                return error.MemoryReadFailed;
            },
            .frame_offset => |offset| {
                const addr = if (offset >= 0)
                    ctx.frame_base +% @as(u64, @intCast(offset))
                else
                    ctx.frame_base -% @as(u64, @intCast(-offset));

                if (ctx.read_memory) |read_fn| {
                    if (read_fn(addr, 8)) |data| {
                        return std.mem.readInt(u64, data[0..8], .little);
                    }
                }
                return error.MemoryReadFailed;
            },
            .value => |val| {
                return val;
            },
        }
    }

    /// Format a value based on type.
    fn formatValue(self: *Self, value: u64, type_info: TypeInfo) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        switch (type_info) {
            .int_type => |int| {
                if (int.signed) {
                    const signed_val: i64 = switch (int.size) {
                        1 => @as(i8, @bitCast(@as(u8, @truncate(value)))),
                        2 => @as(i16, @bitCast(@as(u16, @truncate(value)))),
                        4 => @as(i32, @bitCast(@as(u32, @truncate(value)))),
                        else => @bitCast(value),
                    };
                    try buf.writer(self.allocator).print("{d}", .{signed_val});
                } else {
                    try buf.writer(self.allocator).print("{d}", .{value});
                }
            },
            .float_type => |size| {
                if (size == 4) {
                    const f: f32 = @bitCast(@as(u32, @truncate(value)));
                    try buf.writer(self.allocator).print("{d:.6}", .{f});
                } else {
                    const f: f64 = @bitCast(value);
                    try buf.writer(self.allocator).print("{d:.6}", .{f});
                }
            },
            .pointer_type => {
                try buf.writer(self.allocator).print("0x{x}", .{value});
            },
            .struct_type => |s| {
                try buf.writer(self.allocator).print("({s}) {{ ... }}", .{s.name});
            },
            .void_type => {
                try buf.appendSlice(self.allocator, "void");
            },
            .array_type => |arr| {
                _ = arr;
                try buf.writer(self.allocator).print("[0x{x}]", .{value});
            },
            .unknown => {
                try buf.writer(self.allocator).print("0x{x}", .{value});
            },
        }

        return buf.toOwnedSlice(self.allocator);
    }
};

/// Format a memory dump.
pub fn formatMemory(allocator: std.mem.Allocator, data: []const u8, addr: u64) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var offset: usize = 0;
    while (offset < data.len) {
        // Address
        try buf.writer(allocator).print("0x{x:0>16}: ", .{addr + offset});

        // Hex bytes
        var i: usize = 0;
        while (i < 16 and offset + i < data.len) : (i += 1) {
            try buf.writer(allocator).print("{x:0>2} ", .{data[offset + i]});
        }

        // Padding
        while (i < 16) : (i += 1) {
            try buf.appendSlice(allocator, "   ");
        }

        // ASCII
        try buf.appendSlice(allocator, " |");
        i = 0;
        while (i < 16 and offset + i < data.len) : (i += 1) {
            const c = data[offset + i];
            if (c >= 0x20 and c < 0x7f) {
                try buf.append(allocator, c);
            } else {
                try buf.append(allocator, '.');
            }
        }
        try buf.appendSlice(allocator, "|\n");

        offset += 16;
    }

    return buf.toOwnedSlice(allocator);
}

/// Format register values.
pub fn formatRegisters(allocator: std.mem.Allocator, regs: []const u64) ![]const u8 {
    const reg_names = [_][]const u8{
        "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp",
        "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15",
    };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (reg_names, 0..) |name, i| {
        if (i < regs.len) {
            try buf.writer(allocator).print("{s:>4} = 0x{x:0>16}\n", .{ name, regs[i] });
        }
    }

    return buf.toOwnedSlice(allocator);
}

// Tests

test "evaluator init" {
    const allocator = std.testing.allocator;
    var eval = Evaluator.init(allocator);
    defer eval.deinit();

    try std.testing.expectEqual(@as(usize, 0), eval.variables.count());
}

test "add and lookup variable" {
    const allocator = std.testing.allocator;
    var eval = Evaluator.init(allocator);
    defer eval.deinit();

    try eval.addVariable(Variable{
        .name = "x",
        .location = .{ .register = 0 },
        .type_info = .{ .int_type = .{ .size = 4, .signed = true } },
    });

    const v = eval.lookupVariable("x");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("x", v.?.name);
}

test "format integer" {
    const allocator = std.testing.allocator;
    var eval = Evaluator.init(allocator);
    defer eval.deinit();

    const result = try eval.formatValue(42, .{ .int_type = .{ .size = 4, .signed = true } });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("42", result);
}

test "format negative integer" {
    const allocator = std.testing.allocator;
    var eval = Evaluator.init(allocator);
    defer eval.deinit();

    const result = try eval.formatValue(@as(u64, @bitCast(@as(i64, -42))), .{ .int_type = .{ .size = 8, .signed = true } });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("-42", result);
}

test "format pointer" {
    const allocator = std.testing.allocator;
    var eval = Evaluator.init(allocator);
    defer eval.deinit();

    const result = try eval.formatValue(0x7fff1234, .{ .pointer_type = undefined });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("0x7fff1234", result);
}

test "format memory" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    const result = try formatMemory(allocator, &data, 0x1000);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "0x0000000000001000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "48 65 6c 6c 6f") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
}

test "format registers" {
    const allocator = std.testing.allocator;
    var regs = [_]u64{0} ** 16;
    regs[0] = 0x1234; // rax
    regs[7] = 0x7fff0000; // rsp

    const result = try formatRegisters(allocator, &regs);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "rax") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "rsp") != null);
}
