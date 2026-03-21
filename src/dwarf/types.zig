//! DWARF constants and types

const std = @import("std");

// DWARF Tags (DW_TAG_*)
pub const TAG = struct {
    pub const compile_unit: u16 = 0x11;
    pub const subprogram: u16 = 0x2e;
    pub const variable: u16 = 0x34;
    pub const formal_parameter: u16 = 0x05;
    pub const base_type: u16 = 0x24;
    pub const pointer_type: u16 = 0x0f;
    pub const structure_type: u16 = 0x13;
    pub const member: u16 = 0x0d;
    pub const lexical_block: u16 = 0x0b;
    pub const inlined_subroutine: u16 = 0x1d;
};

// DWARF Attributes (DW_AT_*)
pub const AT = struct {
    pub const name: u16 = 0x03;
    pub const low_pc: u16 = 0x11;
    pub const high_pc: u16 = 0x12;
    pub const language: u16 = 0x13;
    pub const comp_dir: u16 = 0x1b;
    pub const stmt_list: u16 = 0x10;
    pub const type_: u16 = 0x49;
    pub const location: u16 = 0x02;
    pub const frame_base: u16 = 0x40;
    pub const decl_file: u16 = 0x3a;
    pub const decl_line: u16 = 0x3b;
    pub const byte_size: u16 = 0x0b;
    pub const encoding: u16 = 0x3e;
};

// DWARF Forms (DW_FORM_*)
pub const FORM = struct {
    pub const addr: u8 = 0x01;
    pub const data1: u8 = 0x0b;
    pub const data2: u8 = 0x05;
    pub const data4: u8 = 0x06;
    pub const data8: u8 = 0x07;
    pub const string: u8 = 0x08;
    pub const strp: u8 = 0x0e;
    pub const ref1: u8 = 0x11;
    pub const ref2: u8 = 0x12;
    pub const ref4: u8 = 0x13;
    pub const ref8: u8 = 0x14;
    pub const sec_offset: u8 = 0x17;
    pub const exprloc: u8 = 0x18;
    pub const flag_present: u8 = 0x19;
};

// DWARF Operations (DW_OP_*)
pub const OP = struct {
    pub const addr: u8 = 0x03;
    pub const deref: u8 = 0x06;
    pub const const1u: u8 = 0x08;
    pub const const1s: u8 = 0x09;
    pub const const2u: u8 = 0x0a;
    pub const const2s: u8 = 0x0b;
    pub const const4u: u8 = 0x0c;
    pub const const4s: u8 = 0x0d;
    pub const const8u: u8 = 0x0e;
    pub const const8s: u8 = 0x0f;
    pub const dup: u8 = 0x12;
    pub const drop: u8 = 0x13;
    pub const plus: u8 = 0x22;
    pub const plus_uconst: u8 = 0x23;
    pub const minus: u8 = 0x1c;
    pub const fbreg: u8 = 0x91;
    pub const reg0: u8 = 0x50;
    pub const reg15: u8 = 0x5f;
    pub const breg0: u8 = 0x70;
    pub const breg15: u8 = 0x7f;
    pub const regx: u8 = 0x90;
    pub const bregx: u8 = 0x92;
    pub const call_frame_cfa: u8 = 0x9c;
};

test "dwarf constants" {
    try std.testing.expect(TAG.compile_unit == 0x11);
    try std.testing.expect(AT.name == 0x03);
    try std.testing.expect(FORM.addr == 0x01);
}
