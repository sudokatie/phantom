# Phantom

A native debugger written in Zig. For understanding what happens between your breakpoint and the CPU.

## What This Is

Phantom implements a debugger from scratch using:
- Linux ptrace for process control
- DWARF debug info for source-level debugging
- Software breakpoints (int3)
- Stack unwinding with CFI

It's educational - see how GDB works under the hood.

## Features

- Process control (attach, detach, continue, step)
- Software breakpoints
- Register inspection
- Memory read/write
- DWARF symbol lookup
- Stack traces

## Quick Start

```bash
# Build
zig build

# Debug a program
./zig-out/bin/phantom ./your-program

# Or attach to running process
./zig-out/bin/phantom attach 1234
```

## Commands

```
continue, c       Continue execution
step, s           Single step instruction
break <addr>      Set breakpoint at address
break <func>      Set breakpoint at function
delete <n>        Delete breakpoint
info registers    Show registers
info breakpoints  List breakpoints
quit              Exit debugger
```

## Requirements

- Linux (x86-64)
- Zig 0.14+
- Root or CAP_SYS_PTRACE capability
- Debug symbols in target binary (-g)

## Architecture

```
phantom/
├── src/
│   ├── main.zig        Entry point, argument parsing
│   ├── debugger.zig    Debugger state machine
│   ├── process.zig     ptrace operations
│   ├── breakpoint.zig  Breakpoint management
│   ├── dwarf/          DWARF parser
│   ├── elf.zig         ELF parsing
│   ├── regs.zig        Register handling
│   └── cli.zig         Command interface
└── build.zig
```

## How It Works

1. **Attach**: Use ptrace(ATTACH) to trace the target
2. **Breakpoints**: Write 0xCC (int3) to instruction locations
3. **Wait**: waitpid() for process state changes
4. **Inspect**: Read memory and registers via ptrace
5. **Continue**: ptrace(CONT) to resume execution

## Limitations (v0.1.0)

- x86-64 Linux only
- No hardware watchpoints
- No conditional breakpoints
- No multi-threading support
- No remote debugging

## License

MIT

---

*Built by Katie to understand debuggers.*
