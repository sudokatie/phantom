//! ELF parser
//!
//! Parses ELF files to extract sections, symbols, and debug info locations.

const std = @import("std");

/// ELF section information.
pub const Section = struct {
    name: []const u8,
    offset: u64,
    size: u64,
    addr: u64,
};

/// ELF symbol information.
pub const Symbol = struct {
    name: []const u8,
    value: u64,
    size: u64,
    sym_type: u8,
    bind: u8,
};

/// ELF file parser.
pub const Elf = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    data: []const u8,
    sections: std.StringHashMap(Section),
    symbols: std.StringHashMap(Symbol),
    entry_point: u64,

    const Self = @This();

    /// Parse an ELF file.
    pub fn parse(allocator: std.mem.Allocator, path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 1024 * 1024 * 100); // 100MB max

        var self = Self{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .data = data,
            .sections = std.StringHashMap(Section).init(allocator),
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .entry_point = 0,
        };

        try self.parseHeaders();
        return self;
    }

    /// Clean up resources.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
        self.allocator.free(self.path);
        self.sections.deinit();
        self.symbols.deinit();
    }

    fn parseHeaders(self: *Self) !void {
        if (self.data.len < 64) return error.InvalidElf;

        // Check ELF magic
        if (!std.mem.eql(u8, self.data[0..4], "\x7fELF")) {
            return error.InvalidElf;
        }

        // Check 64-bit
        if (self.data[4] != 2) {
            return error.Not64Bit;
        }

        // Parse header
        const ehdr = std.mem.bytesAsValue(std.elf.Elf64_Ehdr, self.data[0..@sizeOf(std.elf.Elf64_Ehdr)]);
        self.entry_point = ehdr.e_entry;

        // Parse section headers
        const shoff = ehdr.e_shoff;
        const shnum = ehdr.e_shnum;
        const shentsize = ehdr.e_shentsize;
        const shstrndx = ehdr.e_shstrndx;

        if (shoff == 0 or shnum == 0) return;

        // Get section name string table
        const shstr_hdr = self.getSectionHeader(shoff, shstrndx, shentsize);
        const shstrtab = self.data[shstr_hdr.sh_offset..][0..shstr_hdr.sh_size];

        // Parse each section
        var i: u16 = 0;
        while (i < shnum) : (i += 1) {
            const shdr = self.getSectionHeader(shoff, i, shentsize);
            const name = std.mem.sliceTo(shstrtab[shdr.sh_name..], 0);

            const section = Section{
                .name = name,
                .offset = shdr.sh_offset,
                .size = shdr.sh_size,
                .addr = shdr.sh_addr,
            };

            self.sections.put(name, section) catch {};

            // Parse symbol table
            if (shdr.sh_type == std.elf.SHT_SYMTAB or shdr.sh_type == std.elf.SHT_DYNSYM) {
                try self.parseSymbols(shdr, shoff, shentsize);
            }
        }
    }

    fn getSectionHeader(self: *Self, shoff: u64, idx: u16, shentsize: u16) *const std.elf.Elf64_Shdr {
        const offset = shoff + @as(u64, idx) * shentsize;
        return std.mem.bytesAsValue(
            std.elf.Elf64_Shdr,
            self.data[offset..][0..@sizeOf(std.elf.Elf64_Shdr)],
        );
    }

    fn parseSymbols(self: *Self, symtab_hdr: *const std.elf.Elf64_Shdr, shoff: u64, shentsize: u16) !void {
        // Get string table for symbol names
        const strtab_hdr = self.getSectionHeader(shoff, @truncate(symtab_hdr.sh_link), shentsize);
        const strtab = self.data[strtab_hdr.sh_offset..][0..strtab_hdr.sh_size];

        const symdata = self.data[symtab_hdr.sh_offset..][0..symtab_hdr.sh_size];
        const sym_count = symtab_hdr.sh_size / @sizeOf(std.elf.Elf64_Sym);

        var i: usize = 0;
        while (i < sym_count) : (i += 1) {
            const sym = std.mem.bytesAsValue(
                std.elf.Elf64_Sym,
                symdata[i * @sizeOf(std.elf.Elf64_Sym) ..][0..@sizeOf(std.elf.Elf64_Sym)],
            );

            if (sym.st_name == 0) continue;

            const name = std.mem.sliceTo(strtab[sym.st_name..], 0);
            if (name.len == 0) continue;

            const symbol = Symbol{
                .name = name,
                .value = sym.st_value,
                .size = sym.st_size,
                .sym_type = @truncate(sym.st_info & 0xf),
                .bind = @truncate(sym.st_info >> 4),
            };

            self.symbols.put(name, symbol) catch {};
        }
    }

    /// Find a section by name.
    pub fn findSection(self: *Self, name: []const u8) ?Section {
        return self.sections.get(name);
    }

    /// Find a symbol by name.
    pub fn findSymbol(self: *Self, name: []const u8) ?Symbol {
        return self.symbols.get(name);
    }

    /// Get section data.
    pub fn sectionData(self: *Self, name: []const u8) ?[]const u8 {
        const section = self.sections.get(name) orelse return null;
        return self.data[section.offset..][0..section.size];
    }

    /// Find symbol containing an address.
    pub fn symbolAt(self: *Self, addr: u64) ?Symbol {
        var best: ?Symbol = null;
        var it = self.symbols.valueIterator();
        while (it.next()) |sym| {
            if (sym.value <= addr and addr < sym.value + sym.size) {
                // Exact match
                return sym.*;
            }
            // Track closest symbol before address
            if (sym.value <= addr) {
                if (best) |b| {
                    if (sym.value > b.value) {
                        best = sym.*;
                    }
                } else {
                    best = sym.*;
                }
            }
        }
        return best;
    }

    /// Check if a section exists.
    pub fn hasSection(self: *Self, name: []const u8) bool {
        return self.sections.contains(name);
    }

    /// Check if debug info is available.
    pub fn hasDebugInfo(self: *Self) bool {
        return self.hasSection(".debug_info");
    }
};

// Symbol types
pub const STT_NOTYPE: u8 = 0;
pub const STT_OBJECT: u8 = 1;
pub const STT_FUNC: u8 = 2;
pub const STT_SECTION: u8 = 3;
pub const STT_FILE: u8 = 4;

// Symbol bindings
pub const STB_LOCAL: u8 = 0;
pub const STB_GLOBAL: u8 = 1;
pub const STB_WEAK: u8 = 2;

test "elf magic check" {
    const bad_data = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expect(!std.mem.eql(u8, &bad_data, "\x7fELF"));
}

test "symbol types" {
    try std.testing.expect(STT_FUNC == 2);
    try std.testing.expect(STB_GLOBAL == 1);
}
