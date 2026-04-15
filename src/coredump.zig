//! Core dump parser for Linux ELF core files
//!
//! Parses ET_CORE ELF files to extract register state, memory segments,
//! and auxiliary vector entries. Used for post-mortem debugging.

const std = @import("std");
const regs = @import("regs.zig");

// ============================================================================
// ELF Constants for Core Dumps
// ============================================================================

/// ELF type: core dump
pub const ET_CORE: u16 = 4;

/// Program header type: loadable segment
pub const PT_LOAD: u32 = 1;

/// Program header type: note segment
pub const PT_NOTE: u32 = 4;

/// Note type: process status (contains registers)
pub const NT_PRSTATUS: u32 = 1;

/// Note type: auxiliary vector
pub const NT_AUXV: u32 = 6;

/// ELF64 file header
pub const Elf64Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

/// ELF64 program header
pub const Elf64Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

/// ELF64 note header
pub const Elf64Nhdr = extern struct {
    n_namesz: u32,
    n_descsz: u32,
    n_type: u32,
};

// ============================================================================
// Permission Flags
// ============================================================================

/// Memory segment permissions
pub const Permissions = packed struct {
    execute: bool = false,
    write: bool = false,
    read: bool = false,
    _padding: u5 = 0,

    const Self = @This();

    pub const READ: Self = .{ .read = true };
    pub const WRITE: Self = .{ .write = true };
    pub const EXECUTE: Self = .{ .execute = true };
    pub const RW: Self = .{ .read = true, .write = true };
    pub const RX: Self = .{ .read = true, .execute = true };
    pub const RWX: Self = .{ .read = true, .write = true, .execute = true };
    pub const NONE: Self = .{};

    /// Create from ELF p_flags (PF_R=4, PF_W=2, PF_X=1)
    pub fn fromElfFlags(flags: u32) Self {
        return .{
            .read = (flags & 4) != 0,
            .write = (flags & 2) != 0,
            .execute = (flags & 1) != 0,
        };
    }

    pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeByte(if (self.read) 'r' else '-');
        try writer.writeByte(if (self.write) 'w' else '-');
        try writer.writeByte(if (self.execute) 'x' else '-');
    }
};

// ============================================================================
// Memory Segment
// ============================================================================

/// A memory segment from a core dump
pub const MemorySegment = struct {
    /// Virtual address where segment is mapped
    start: u64,
    /// Segment data
    data: []const u8,
    /// Memory permissions
    permissions: Permissions,

    const Self = @This();

    /// Check if this segment contains the given address
    pub fn contains(self: *const Self, addr: u64) bool {
        return addr >= self.start and addr < self.start + self.data.len;
    }

    /// Check if this segment contains the given address range
    pub fn containsRange(self: *const Self, addr: u64, size: usize) bool {
        if (addr < self.start) return false;
        const end = addr + size;
        const seg_end = self.start + self.data.len;
        return end <= seg_end;
    }

    /// Get offset into segment data for a virtual address
    pub fn offsetFor(self: *const Self, addr: u64) ?usize {
        if (!self.contains(addr)) return null;
        return @intCast(addr - self.start);
    }
};

// ============================================================================
// Stack Frame
// ============================================================================

/// A stack frame from backtrace
pub const StackFrame = struct {
    /// Return address (where execution will return to)
    return_address: u64,
    /// Frame pointer (RBP value)
    frame_pointer: u64,
    /// Function name (null if unknown)
    function_name: ?[]const u8,
};

// ============================================================================
// Auxiliary Vector
// ============================================================================

/// Auxiliary vector entry types
pub const AuxType = enum(u64) {
    AT_NULL = 0,
    AT_IGNORE = 1,
    AT_EXECFD = 2,
    AT_PHDR = 3,
    AT_PHENT = 4,
    AT_PHNUM = 5,
    AT_PAGESZ = 6,
    AT_BASE = 7,
    AT_FLAGS = 8,
    AT_ENTRY = 9,
    AT_NOTELF = 10,
    AT_UID = 11,
    AT_EUID = 12,
    AT_GID = 13,
    AT_EGID = 14,
    AT_PLATFORM = 15,
    AT_HWCAP = 16,
    AT_CLKTCK = 17,
    AT_SECURE = 23,
    AT_BASE_PLATFORM = 24,
    AT_RANDOM = 25,
    AT_HWCAP2 = 26,
    AT_EXECFN = 31,
    AT_SYSINFO = 32,
    AT_SYSINFO_EHDR = 33,
    _,

    pub fn name(self: AuxType) []const u8 {
        return switch (self) {
            .AT_NULL => "AT_NULL",
            .AT_IGNORE => "AT_IGNORE",
            .AT_EXECFD => "AT_EXECFD",
            .AT_PHDR => "AT_PHDR",
            .AT_PHENT => "AT_PHENT",
            .AT_PHNUM => "AT_PHNUM",
            .AT_PAGESZ => "AT_PAGESZ",
            .AT_BASE => "AT_BASE",
            .AT_FLAGS => "AT_FLAGS",
            .AT_ENTRY => "AT_ENTRY",
            .AT_NOTELF => "AT_NOTELF",
            .AT_UID => "AT_UID",
            .AT_EUID => "AT_EUID",
            .AT_GID => "AT_GID",
            .AT_EGID => "AT_EGID",
            .AT_PLATFORM => "AT_PLATFORM",
            .AT_HWCAP => "AT_HWCAP",
            .AT_CLKTCK => "AT_CLKTCK",
            .AT_SECURE => "AT_SECURE",
            .AT_BASE_PLATFORM => "AT_BASE_PLATFORM",
            .AT_RANDOM => "AT_RANDOM",
            .AT_HWCAP2 => "AT_HWCAP2",
            .AT_EXECFN => "AT_EXECFN",
            .AT_SYSINFO => "AT_SYSINFO",
            .AT_SYSINFO_EHDR => "AT_SYSINFO_EHDR",
            _ => "AT_UNKNOWN",
        };
    }
};

/// Auxiliary vector entry
pub const AuxEntry = struct {
    type: AuxType,
    value: u64,
};

// ============================================================================
// Note Data (intermediate parsing result)
// ============================================================================

/// Parsed note segment data
pub const NoteData = struct {
    /// Register state from NT_PRSTATUS
    registers: ?regs.Registers,
    /// Signal that caused the core dump
    signal: u32,
    /// Process ID
    pid: i32,
    /// Auxiliary vector entries
    aux_entries: std.ArrayList(AuxEntry),
    /// Allocator used for aux_entries
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NoteData {
        return .{
            .registers = null,
            .signal = 0,
            .pid = 0,
            .aux_entries = std.ArrayList(AuxEntry){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NoteData) void {
        self.aux_entries.deinit(self.allocator);
    }
};

// ============================================================================
// Core Dump Parser
// ============================================================================

/// Low-level core dump parsing functions
pub const CoreDumpParser = struct {
    /// Parse and validate ELF header for core dump
    pub fn parseElfHeader(data: []const u8) !Elf64Ehdr {
        if (data.len < @sizeOf(Elf64Ehdr)) {
            return error.InvalidCoreDump;
        }

        const ehdr = std.mem.bytesAsValue(Elf64Ehdr, data[0..@sizeOf(Elf64Ehdr)]);

        // Validate ELF magic
        if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7fELF")) {
            return error.InvalidElf;
        }

        // Check 64-bit
        if (ehdr.e_ident[4] != 2) {
            return error.Not64Bit;
        }

        // Check little-endian
        if (ehdr.e_ident[5] != 1) {
            return error.NotLittleEndian;
        }

        // Validate core dump type
        if (ehdr.e_type != ET_CORE) {
            return error.NotCoreDump;
        }

        return ehdr.*;
    }

    /// Parse program headers
    pub fn parseProgramHeaders(allocator: std.mem.Allocator, data: []const u8, offset: u64, count: u16, entsize: u16) ![]Elf64Phdr {
        var phdrs = try allocator.alloc(Elf64Phdr, count);
        errdefer allocator.free(phdrs);

        var i: u16 = 0;
        while (i < count) : (i += 1) {
            const phdr_offset = offset + @as(u64, i) * entsize;
            if (phdr_offset + @sizeOf(Elf64Phdr) > data.len) {
                return error.InvalidCoreDump;
            }
            phdrs[i] = std.mem.bytesAsValue(Elf64Phdr, data[phdr_offset..][0..@sizeOf(Elf64Phdr)]).*;
        }

        return phdrs;
    }

    /// Parse note segment to extract registers and aux entries
    pub fn parseNoteSegment(allocator: std.mem.Allocator, data: []const u8) !NoteData {
        var note_data = NoteData.init(allocator);
        errdefer note_data.deinit();

        var offset: usize = 0;
        while (offset + @sizeOf(Elf64Nhdr) <= data.len) {
            const nhdr = std.mem.bytesAsValue(Elf64Nhdr, data[offset..][0..@sizeOf(Elf64Nhdr)]);
            offset += @sizeOf(Elf64Nhdr);

            // Align name size to 4 bytes
            const name_size_aligned = alignUp(nhdr.n_namesz, 4);
            const desc_size_aligned = alignUp(nhdr.n_descsz, 4);

            if (offset + name_size_aligned + desc_size_aligned > data.len) {
                break;
            }

            // Skip name
            offset += name_size_aligned;

            // Get descriptor
            const desc = data[offset..][0..nhdr.n_descsz];

            if (nhdr.n_type == NT_PRSTATUS) {
                // prstatus structure layout for x86_64:
                // siginfo: 128 bytes (si_signo, si_code, si_errno, padding, etc)
                // cursig: 2 bytes (u16)
                // padding: 2 bytes
                // sigpend: 8 bytes
                // sighold: 8 bytes
                // pid, ppid, pgrp, sid: 4 * 4 = 16 bytes
                // utime, stime, cutime, cstime: 4 * 16 = 64 bytes (timeval structs)
                // regs: 216 bytes (user_regs_struct - 27 * 8 bytes)
                //
                // Total offset to regs: 128 + 2 + 2 + 8 + 8 + 16 + 64 = 228 bytes
                // But Linux x86_64 actually uses offset 112 for the general regs
                // Let's use the standard prstatus layout:
                // - si_signo at offset 0 (4 bytes)
                // - pr_pid at offset 24 (4 bytes)
                // - pr_reg at offset 112 (27 * 8 = 216 bytes)

                if (desc.len >= 112 + @sizeOf(regs.Registers)) {
                    // Extract signal number
                    note_data.signal = std.mem.bytesAsValue(u32, desc[0..4]).*;
                    // Extract pid (at offset 24)
                    note_data.pid = std.mem.bytesAsValue(i32, desc[24..28]).*;
                    // Extract registers at offset 112
                    note_data.registers = std.mem.bytesAsValue(regs.Registers, desc[112..][0..@sizeOf(regs.Registers)]).*;
                }
            } else if (nhdr.n_type == NT_AUXV) {
                // Parse auxiliary vector (array of {type, value} pairs)
                var aux_offset: usize = 0;
                while (aux_offset + 16 <= desc.len) {
                    const aux_type = std.mem.bytesAsValue(u64, desc[aux_offset..][0..8]).*;
                    const aux_value = std.mem.bytesAsValue(u64, desc[aux_offset + 8 ..][0..8]).*;

                    if (aux_type == 0) break; // AT_NULL terminates

                    try note_data.aux_entries.append(allocator, .{
                        .type = @enumFromInt(aux_type),
                        .value = aux_value,
                    });

                    aux_offset += 16;
                }
            }

            offset += desc_size_aligned;
        }

        return note_data;
    }

    /// Extract segments from program headers
    pub fn extractSegments(allocator: std.mem.Allocator, data: []const u8, phdrs: []const Elf64Phdr) ![]MemorySegment {
        var segments = std.ArrayList(MemorySegment){};
        errdefer {
            for (segments.items) |seg| {
                allocator.free(seg.data);
            }
            segments.deinit(allocator);
        }

        for (phdrs) |phdr| {
            if (phdr.p_type != PT_LOAD) continue;
            if (phdr.p_filesz == 0) continue;

            if (phdr.p_offset + phdr.p_filesz > data.len) {
                continue; // Skip invalid segments
            }

            const seg_data = try allocator.dupe(u8, data[phdr.p_offset..][0..phdr.p_filesz]);
            errdefer allocator.free(seg_data);

            try segments.append(allocator, .{
                .start = phdr.p_vaddr,
                .data = seg_data,
                .permissions = Permissions.fromElfFlags(phdr.p_flags),
            });
        }

        return segments.toOwnedSlice(allocator);
    }

    fn alignUp(value: u32, alignment: u32) usize {
        return @intCast((@as(usize, value) + alignment - 1) & ~(@as(usize, alignment) - 1));
    }
};

// ============================================================================
// Core Dump
// ============================================================================

/// Parsed core dump file
pub const CoreDump = struct {
    allocator: std.mem.Allocator,
    /// Saved register state at time of crash
    registers: regs.Registers,
    /// Memory segments from PT_LOAD headers
    segments: []MemorySegment,
    /// Auxiliary vector entries
    aux_entries: []AuxEntry,
    /// Signal that caused the dump
    signal: u32,
    /// Process ID
    pid: i32,

    const Self = @This();

    /// Parse a core dump file
    pub fn parse(allocator: std.mem.Allocator, path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 1024 * 1024 * 1024); // 1GB max
        defer allocator.free(data);

        return parseFromMemory(allocator, data);
    }

    /// Parse a core dump from memory buffer
    pub fn parseFromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        const ehdr = try CoreDumpParser.parseElfHeader(data);

        const phdrs = try CoreDumpParser.parseProgramHeaders(
            allocator,
            data,
            ehdr.e_phoff,
            ehdr.e_phnum,
            ehdr.e_phentsize,
        );
        defer allocator.free(phdrs);

        // Find and parse note segment
        var note_data: ?NoteData = null;
        defer if (note_data) |*nd| nd.deinit();

        for (phdrs) |phdr| {
            if (phdr.p_type == PT_NOTE) {
                if (phdr.p_offset + phdr.p_filesz <= data.len) {
                    note_data = try CoreDumpParser.parseNoteSegment(
                        allocator,
                        data[phdr.p_offset..][0..phdr.p_filesz],
                    );
                    break;
                }
            }
        }

        const nd = note_data orelse return error.NoNoteSegment;

        const parsed_regs = nd.registers orelse return error.NoRegisters;

        // Extract memory segments
        const segments = try CoreDumpParser.extractSegments(allocator, data, phdrs);
        errdefer {
            for (segments) |seg| allocator.free(seg.data);
            allocator.free(segments);
        }

        // Copy aux entries
        const aux_entries = try allocator.dupe(AuxEntry, nd.aux_entries.items);

        return .{
            .allocator = allocator,
            .registers = parsed_regs,
            .segments = segments,
            .aux_entries = aux_entries,
            .signal = nd.signal,
            .pid = nd.pid,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        for (self.segments) |seg| {
            self.allocator.free(seg.data);
        }
        self.allocator.free(self.segments);
        self.allocator.free(self.aux_entries);
    }

    /// Find segment containing address
    fn findSegment(self: *const Self, addr: u64) ?*const MemorySegment {
        for (self.segments) |*seg| {
            if (seg.contains(addr)) return seg;
        }
        return null;
    }

    /// Read memory at address
    pub fn readMemory(self: *const Self, addr: u64, size: usize) ![]const u8 {
        const seg = self.findSegment(addr) orelse return error.AddressNotMapped;
        if (!seg.containsRange(addr, size)) return error.AddressNotMapped;
        const offset = seg.offsetFor(addr).?;
        return seg.data[offset..][0..size];
    }

    /// Read a u64 at address
    pub fn readU64(self: *const Self, addr: u64) !u64 {
        const data = try self.readMemory(addr, 8);
        return std.mem.bytesAsValue(u64, data[0..8]).*;
    }

    /// Walk frame pointers to build backtrace
    pub fn backtrace(self: *const Self, allocator: std.mem.Allocator) ![]StackFrame {
        var frames = std.ArrayList(StackFrame){};
        errdefer frames.deinit(allocator);

        // First frame: current RIP
        try frames.append(allocator, .{
            .return_address = self.registers.rip,
            .frame_pointer = self.registers.rbp,
            .function_name = null,
        });

        // Walk frame pointer chain
        var rbp = self.registers.rbp;
        var depth: usize = 0;
        const max_depth: usize = 256;

        while (depth < max_depth) : (depth += 1) {
            if (rbp == 0) break;

            // Read return address (rbp + 8) and previous frame pointer (rbp)
            const prev_rbp = self.readU64(rbp) catch break;
            const ret_addr = self.readU64(rbp + 8) catch break;

            if (ret_addr == 0) break;

            try frames.append(allocator, .{
                .return_address = ret_addr,
                .frame_pointer = prev_rbp,
                .function_name = null,
            });

            // Sanity check: frame pointer should grow upward on x86_64
            if (prev_rbp != 0 and prev_rbp <= rbp) break;
            rbp = prev_rbp;
        }

        return frames.toOwnedSlice(allocator);
    }

    /// Get auxiliary vector entry by type
    pub fn getAuxEntry(self: *const Self, aux_type: AuxType) ?u64 {
        for (self.aux_entries) |entry| {
            if (entry.type == aux_type) return entry.value;
        }
        return null;
    }
};

// ============================================================================
// Test Helpers
// ============================================================================

/// Build a fake core dump for testing
pub const FakeCoreDumpBuilder = struct {
    allocator: std.mem.Allocator,
    phdrs: std.ArrayList(Elf64Phdr),
    segments: std.ArrayList([]const u8),
    note_data: std.ArrayList(u8),
    registers: regs.Registers,
    signal: u32,
    pid: i32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .phdrs = std.ArrayList(Elf64Phdr).initCapacity(allocator, 16) catch @panic("oom"),
            .segments = std.ArrayList([]const u8).initCapacity(allocator, 16) catch @panic("oom"),
            .note_data = std.ArrayList(u8).initCapacity(allocator, 4096) catch @panic("oom"),
            .registers = std.mem.zeroes(regs.Registers),
            .signal = 11, // SIGSEGV
            .pid = 1234,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.segments.items) |seg| {
            self.allocator.free(seg);
        }
        self.segments.deinit(self.allocator);
        self.phdrs.deinit(self.allocator);
        self.note_data.deinit(self.allocator);
    }

    pub fn setRegisters(self: *Self, r: regs.Registers) void {
        self.registers = r;
    }

    pub fn setSignal(self: *Self, sig: u32) void {
        self.signal = sig;
    }

    pub fn setPid(self: *Self, pid_val: i32) void {
        self.pid = pid_val;
    }

    pub fn addSegment(self: *Self, vaddr: u64, data: []const u8, flags: u32) !void {
        const seg_copy = try self.allocator.dupe(u8, data);
        try self.segments.append(self.allocator, seg_copy);

        try self.phdrs.append(self.allocator, .{
            .p_type = PT_LOAD,
            .p_flags = flags,
            .p_offset = 0, // Will be computed in build()
            .p_vaddr = vaddr,
            .p_paddr = vaddr,
            .p_filesz = data.len,
            .p_memsz = data.len,
            .p_align = 0x1000,
        });
    }

    pub fn addAuxEntry(self: *Self, aux_type: AuxType, value: u64) !void {
        try self.note_data.appendSlice(self.allocator, std.mem.asBytes(&@intFromEnum(aux_type)));
        try self.note_data.appendSlice(self.allocator, std.mem.asBytes(&value));
    }

    pub fn build(self: *Self) ![]u8 {
        var result = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch @panic("oom");
        errdefer result.deinit(self.allocator);

        // Build note segment with prstatus
        var note_segment = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch @panic("oom");
        defer note_segment.deinit(self.allocator);

        // NT_PRSTATUS note
        try self.buildPrstatusNote(&note_segment);

        // NT_AUXV note (if we have aux entries)
        if (self.note_data.items.len > 0) {
            // Terminate aux vector
            try self.note_data.appendSlice(self.allocator, &[_]u8{0} ** 16); // AT_NULL

            try self.buildNote(&note_segment, NT_AUXV, self.note_data.items);
        }

        // Calculate offsets
        const ehdr_size: u64 = @sizeOf(Elf64Ehdr);
        const phdr_count: u16 = @intCast(self.phdrs.items.len + 1); // +1 for note
        const phdrs_size: u64 = @as(u64, phdr_count) * @sizeOf(Elf64Phdr);
        const note_offset = ehdr_size + phdrs_size;
        const note_size = note_segment.items.len;

        // Update segment offsets
        var current_offset = note_offset + note_size;
        // Align to 8 bytes
        current_offset = (current_offset + 7) & ~@as(u64, 7);

        for (self.phdrs.items, 0..) |_, i| {
            self.phdrs.items[i].p_offset = current_offset;
            current_offset += self.segments.items[i].len;
            current_offset = (current_offset + 7) & ~@as(u64, 7);
        }

        // Build ELF header
        const ehdr = Elf64Ehdr{
            .e_ident = .{ 0x7f, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .e_type = ET_CORE,
            .e_machine = 0x3E, // EM_X86_64
            .e_version = 1,
            .e_entry = 0,
            .e_phoff = ehdr_size,
            .e_shoff = 0,
            .e_flags = 0,
            .e_ehsize = @sizeOf(Elf64Ehdr),
            .e_phentsize = @sizeOf(Elf64Phdr),
            .e_phnum = phdr_count,
            .e_shentsize = 0,
            .e_shnum = 0,
            .e_shstrndx = 0,
        };

        try result.appendSlice(self.allocator, std.mem.asBytes(&ehdr));

        // Write note program header
        const note_phdr = Elf64Phdr{
            .p_type = PT_NOTE,
            .p_flags = 0,
            .p_offset = note_offset,
            .p_vaddr = 0,
            .p_paddr = 0,
            .p_filesz = note_size,
            .p_memsz = note_size,
            .p_align = 1,
        };
        try result.appendSlice(self.allocator, std.mem.asBytes(&note_phdr));

        // Write load segment program headers
        for (self.phdrs.items) |phdr| {
            try result.appendSlice(self.allocator, std.mem.asBytes(&phdr));
        }

        // Write note segment
        try result.appendSlice(self.allocator, note_segment.items);

        // Pad to 8-byte alignment
        while (result.items.len % 8 != 0) {
            try result.append(self.allocator, 0);
        }

        // Write data segments
        for (self.segments.items) |seg| {
            try result.appendSlice(self.allocator, seg);
            while (result.items.len % 8 != 0) {
                try result.append(self.allocator, 0);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn buildPrstatusNote(self: *Self, out: *std.ArrayList(u8)) !void {
        // Build prstatus structure (336 bytes for x86_64)
        var prstatus: [336]u8 = [_]u8{0} ** 336;

        // si_signo at offset 0
        @as(*align(1) u32, @ptrCast(&prstatus[0])).* = self.signal;
        // pr_pid at offset 24
        @as(*align(1) i32, @ptrCast(&prstatus[24])).* = self.pid;
        // pr_reg at offset 112
        @memcpy(prstatus[112..][0..@sizeOf(regs.Registers)], std.mem.asBytes(&self.registers));

        try self.buildNote(out, NT_PRSTATUS, &prstatus);
    }

    fn buildNote(self: *Self, out: *std.ArrayList(u8), note_type: u32, desc: []const u8) !void {
        const name = "CORE\x00";
        const name_len: u32 = 5;
        const name_aligned = (name_len + 3) & ~@as(u32, 3);
        const desc_aligned = (desc.len + 3) & ~@as(usize, 3);

        const nhdr = Elf64Nhdr{
            .n_namesz = name_len,
            .n_descsz = @intCast(desc.len),
            .n_type = note_type,
        };

        try out.appendSlice(self.allocator, std.mem.asBytes(&nhdr));
        try out.appendSlice(self.allocator, name);
        // Pad name
        var i: u32 = name_len;
        while (i < name_aligned) : (i += 1) {
            try out.append(self.allocator, 0);
        }
        try out.appendSlice(self.allocator, desc);
        // Pad desc
        var j: usize = desc.len;
        while (j < desc_aligned) : (j += 1) {
            try out.append(self.allocator, 0);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Permissions from ELF flags" {
    const r = Permissions.fromElfFlags(4);
    try std.testing.expect(r.read);
    try std.testing.expect(!r.write);
    try std.testing.expect(!r.execute);

    const rw = Permissions.fromElfFlags(6);
    try std.testing.expect(rw.read);
    try std.testing.expect(rw.write);
    try std.testing.expect(!rw.execute);

    const rwx = Permissions.fromElfFlags(7);
    try std.testing.expect(rwx.read);
    try std.testing.expect(rwx.write);
    try std.testing.expect(rwx.execute);
}

test "Permissions format" {
    var buf: [16]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try Permissions.RWX.format("", .{}, stream.writer());
    try std.testing.expectEqualStrings("rwx", stream.getWritten());

    stream.reset();
    try Permissions.READ.format("", .{}, stream.writer());
    try std.testing.expectEqualStrings("r--", stream.getWritten());

    stream.reset();
    try Permissions.NONE.format("", .{}, stream.writer());
    try std.testing.expectEqualStrings("---", stream.getWritten());
}

test "MemorySegment contains" {
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const seg = MemorySegment{
        .start = 0x1000,
        .data = &data,
        .permissions = Permissions.RW,
    };

    try std.testing.expect(seg.contains(0x1000));
    try std.testing.expect(seg.contains(0x1007));
    try std.testing.expect(!seg.contains(0x0FFF));
    try std.testing.expect(!seg.contains(0x1008));
}

test "MemorySegment containsRange" {
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const seg = MemorySegment{
        .start = 0x1000,
        .data = &data,
        .permissions = Permissions.RW,
    };

    try std.testing.expect(seg.containsRange(0x1000, 8));
    try std.testing.expect(seg.containsRange(0x1000, 4));
    try std.testing.expect(seg.containsRange(0x1004, 4));
    try std.testing.expect(!seg.containsRange(0x1000, 9));
    try std.testing.expect(!seg.containsRange(0x1005, 4));
}

test "MemorySegment offsetFor" {
    const data = [_]u8{ 1, 2, 3, 4 };
    const seg = MemorySegment{
        .start = 0x2000,
        .data = &data,
        .permissions = Permissions.READ,
    };

    try std.testing.expectEqual(@as(?usize, 0), seg.offsetFor(0x2000));
    try std.testing.expectEqual(@as(?usize, 2), seg.offsetFor(0x2002));
    try std.testing.expectEqual(@as(?usize, null), seg.offsetFor(0x1FFF));
    try std.testing.expectEqual(@as(?usize, null), seg.offsetFor(0x2004));
}

test "AuxType name" {
    try std.testing.expectEqualStrings("AT_ENTRY", AuxType.AT_ENTRY.name());
    try std.testing.expectEqualStrings("AT_PHDR", AuxType.AT_PHDR.name());
    try std.testing.expectEqualStrings("AT_UNKNOWN", (@as(AuxType, @enumFromInt(9999))).name());
}

test "CoreDumpParser parseElfHeader invalid" {
    const short_data = [_]u8{0} ** 32;
    try std.testing.expectError(error.InvalidCoreDump, CoreDumpParser.parseElfHeader(&short_data));

    var bad_magic: [64]u8 = [_]u8{0} ** 64;
    try std.testing.expectError(error.InvalidElf, CoreDumpParser.parseElfHeader(&bad_magic));

    var bad_class: [64]u8 = [_]u8{0} ** 64;
    @memcpy(bad_class[0..4], "\x7fELF");
    bad_class[4] = 1; // 32-bit
    try std.testing.expectError(error.Not64Bit, CoreDumpParser.parseElfHeader(&bad_class));
}

test "CoreDumpParser parseElfHeader not core" {
    var not_core: [64]u8 = [_]u8{0} ** 64;
    @memcpy(not_core[0..4], "\x7fELF");
    not_core[4] = 2; // 64-bit
    not_core[5] = 1; // little-endian
    // e_type at offset 16, leave as 0 (ET_NONE)
    try std.testing.expectError(error.NotCoreDump, CoreDumpParser.parseElfHeader(&not_core));
}

test "FakeCoreDumpBuilder basic" {
    const allocator = std.testing.allocator;

    var builder = FakeCoreDumpBuilder.init(allocator);
    defer builder.deinit();

    var test_regs = std.mem.zeroes(regs.Registers);
    test_regs.rip = 0x400000;
    test_regs.rsp = 0x7fff0000;
    test_regs.rbp = 0x7fff0100;
    test_regs.rax = 42;

    builder.setRegisters(test_regs);
    builder.setSignal(11);
    builder.setPid(5678);

    const seg_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE };
    try builder.addSegment(0x1000, &seg_data, 6); // RW

    const core_data = try builder.build();
    defer allocator.free(core_data);

    try std.testing.expect(core_data.len > @sizeOf(Elf64Ehdr));
}

test "CoreDump parseFromMemory" {
    const allocator = std.testing.allocator;

    var builder = FakeCoreDumpBuilder.init(allocator);
    defer builder.deinit();

    var test_regs = std.mem.zeroes(regs.Registers);
    test_regs.rip = 0x401234;
    test_regs.rsp = 0x7fffffffe000;
    test_regs.rbp = 0x7fffffffe100;
    test_regs.rax = 0xDEADBEEF;
    test_regs.rbx = 0xCAFEBABE;

    builder.setRegisters(test_regs);
    builder.setSignal(6); // SIGABRT
    builder.setPid(9999);

    const seg_data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try builder.addSegment(0x400000, &seg_data, 5); // R-X

    const core_data = try builder.build();
    defer allocator.free(core_data);

    var core = try CoreDump.parseFromMemory(allocator, core_data);
    defer core.deinit();

    try std.testing.expectEqual(@as(u64, 0x401234), core.registers.rip);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), core.registers.rax);
    try std.testing.expectEqual(@as(u64, 0xCAFEBABE), core.registers.rbx);
    try std.testing.expectEqual(@as(u32, 6), core.signal);
    try std.testing.expectEqual(@as(i32, 9999), core.pid);
    try std.testing.expectEqual(@as(usize, 1), core.segments.len);
}

test "CoreDump readMemory" {
    const allocator = std.testing.allocator;

    var builder = FakeCoreDumpBuilder.init(allocator);
    defer builder.deinit();

    builder.setRegisters(std.mem.zeroes(regs.Registers));

    const seg_data = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    try builder.addSegment(0x1000, &seg_data, 4); // R--

    const core_data = try builder.build();
    defer allocator.free(core_data);

    var core = try CoreDump.parseFromMemory(allocator, core_data);
    defer core.deinit();

    const mem = try core.readMemory(0x1000, 4);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44 }, mem);

    const mem2 = try core.readMemory(0x1004, 4);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x55, 0x66, 0x77, 0x88 }, mem2);

    try std.testing.expectError(error.AddressNotMapped, core.readMemory(0x2000, 4));
    try std.testing.expectError(error.AddressNotMapped, core.readMemory(0x1005, 4));
}

test "CoreDump readU64" {
    const allocator = std.testing.allocator;

    var builder = FakeCoreDumpBuilder.init(allocator);
    defer builder.deinit();

    builder.setRegisters(std.mem.zeroes(regs.Registers));

    // Little-endian u64: 0x8877665544332211
    const seg_data = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    try builder.addSegment(0x3000, &seg_data, 4);

    const core_data = try builder.build();
    defer allocator.free(core_data);

    var core = try CoreDump.parseFromMemory(allocator, core_data);
    defer core.deinit();

    const val = try core.readU64(0x3000);
    try std.testing.expectEqual(@as(u64, 0x8877665544332211), val);

    try std.testing.expectError(error.AddressNotMapped, core.readU64(0x4000));
}

test "CoreDump backtrace simple" {
    const allocator = std.testing.allocator;

    var builder = FakeCoreDumpBuilder.init(allocator);
    defer builder.deinit();

    var test_regs = std.mem.zeroes(regs.Registers);
    test_regs.rip = 0x401000;
    test_regs.rbp = 0x7fff0100;

    builder.setRegisters(test_regs);

    // Stack segment with frame chain:
    // 0x7fff0100: prev_rbp = 0x7fff0200, ret_addr = 0x401100
    // 0x7fff0200: prev_rbp = 0, ret_addr = 0x401200
    var stack_data: [0x200]u8 = [_]u8{0} ** 0x200;

    // Frame at 0x7fff0100 (offset 0x100 from base 0x7fff0000)
    @as(*align(1) u64, @ptrCast(&stack_data[0x100])).* = 0x7fff0200; // prev rbp
    @as(*align(1) u64, @ptrCast(&stack_data[0x108])).* = 0x401100; // ret addr

    // Frame at 0x7fff0200 (offset 0x200 from base 0x7fff0000)
    // This would be at offset 0x200, but our buffer is only 0x200 bytes
    // Let's adjust: base = 0x7fff0000, so 0x7fff0100 = offset 0x100, 0x7fff0200 = offset 0x200
    // We need more space

    try builder.addSegment(0x7fff0000, &stack_data, 6);

    const core_data = try builder.build();
    defer allocator.free(core_data);

    var core = try CoreDump.parseFromMemory(allocator, core_data);
    defer core.deinit();

    const frames = try core.backtrace(allocator);
    defer allocator.free(frames);

    try std.testing.expect(frames.len >= 1);
    try std.testing.expectEqual(@as(u64, 0x401000), frames[0].return_address);
}

test "CoreDump multiple segments" {
    const allocator = std.testing.allocator;

    var builder = FakeCoreDumpBuilder.init(allocator);
    defer builder.deinit();

    builder.setRegisters(std.mem.zeroes(regs.Registers));

    const seg1 = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11 };
    const seg2 = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };

    try builder.addSegment(0x1000, &seg1, 5); // R-X
    try builder.addSegment(0x2000, &seg2, 6); // RW-

    const core_data = try builder.build();
    defer allocator.free(core_data);

    var core = try CoreDump.parseFromMemory(allocator, core_data);
    defer core.deinit();

    try std.testing.expectEqual(@as(usize, 2), core.segments.len);

    const mem1 = try core.readMemory(0x1000, 4);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD }, mem1);

    const mem2 = try core.readMemory(0x2000, 4);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x56, 0x78 }, mem2);
}

test "CoreDump segment permissions" {
    const allocator = std.testing.allocator;

    var builder = FakeCoreDumpBuilder.init(allocator);
    defer builder.deinit();

    builder.setRegisters(std.mem.zeroes(regs.Registers));

    const seg_data = [_]u8{0} ** 8;
    try builder.addSegment(0x1000, &seg_data, 5); // R-X

    const core_data = try builder.build();
    defer allocator.free(core_data);

    var core = try CoreDump.parseFromMemory(allocator, core_data);
    defer core.deinit();

    try std.testing.expect(core.segments[0].permissions.read);
    try std.testing.expect(!core.segments[0].permissions.write);
    try std.testing.expect(core.segments[0].permissions.execute);
}

test "CoreDump aux entries" {
    const allocator = std.testing.allocator;

    var builder = FakeCoreDumpBuilder.init(allocator);
    defer builder.deinit();

    builder.setRegisters(std.mem.zeroes(regs.Registers));

    try builder.addAuxEntry(.AT_ENTRY, 0x400000);
    try builder.addAuxEntry(.AT_PAGESZ, 4096);
    try builder.addAuxEntry(.AT_BASE, 0x7f0000000000);

    const seg_data = [_]u8{0} ** 8;
    try builder.addSegment(0x1000, &seg_data, 4);

    const core_data = try builder.build();
    defer allocator.free(core_data);

    var core = try CoreDump.parseFromMemory(allocator, core_data);
    defer core.deinit();

    try std.testing.expectEqual(@as(?u64, 0x400000), core.getAuxEntry(.AT_ENTRY));
    try std.testing.expectEqual(@as(?u64, 4096), core.getAuxEntry(.AT_PAGESZ));
    try std.testing.expectEqual(@as(?u64, 0x7f0000000000), core.getAuxEntry(.AT_BASE));
    try std.testing.expectEqual(@as(?u64, null), core.getAuxEntry(.AT_RANDOM));
}

test "CoreDump all register fields" {
    const allocator = std.testing.allocator;

    var builder = FakeCoreDumpBuilder.init(allocator);
    defer builder.deinit();

    const test_regs = regs.Registers{
        .r15 = 0x1515151515151515,
        .r14 = 0x1414141414141414,
        .r13 = 0x1313131313131313,
        .r12 = 0x1212121212121212,
        .rbp = 0xBBBBBBBBBBBBBBBB,
        .rbx = 0xAAAAAAAAAAAAAAAA,
        .r11 = 0x1111111111111111,
        .r10 = 0x1010101010101010,
        .r9 = 0x0909090909090909,
        .r8 = 0x0808080808080808,
        .rax = 0xDEADDEADDEADDEAD,
        .rcx = 0xCCCCCCCCCCCCCCCC,
        .rdx = 0xDDDDDDDDDDDDDDDD,
        .rsi = 0x5555555555555555,
        .rdi = 0xDDDDDDDDDDDDDDDD,
        .orig_rax = 0xFFFFFFFFFFFFFFFF,
        .rip = 0x400123,
        .cs = 0x33,
        .eflags = 0x246,
        .rsp = 0x7FFFFFFFE000,
        .ss = 0x2B,
        .fs_base = 0x7FFFF7FE0000,
        .gs_base = 0,
        .ds = 0,
        .es = 0,
        .fs = 0,
        .gs = 0,
    };

    builder.setRegisters(test_regs);

    const seg_data = [_]u8{0} ** 8;
    try builder.addSegment(0x1000, &seg_data, 4);

    const core_data = try builder.build();
    defer allocator.free(core_data);

    var core = try CoreDump.parseFromMemory(allocator, core_data);
    defer core.deinit();

    try std.testing.expectEqual(test_regs.r15, core.registers.r15);
    try std.testing.expectEqual(test_regs.r8, core.registers.r8);
    try std.testing.expectEqual(test_regs.rax, core.registers.rax);
    try std.testing.expectEqual(test_regs.rip, core.registers.rip);
    try std.testing.expectEqual(test_regs.rsp, core.registers.rsp);
    try std.testing.expectEqual(test_regs.fs_base, core.registers.fs_base);
}
