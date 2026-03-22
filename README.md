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

- Process control (attach, detach, continue, step, next)
- Software breakpoints (by address or symbol name)
- Register and memory inspection
- Stack unwinding with backtrace
- DWARF debug info parsing (abbreviations, DIEs, line numbers)
- Location expression evaluation
- Call frame information (CFI) for stack unwinding
- Expression evaluator for variable inspection

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
Running:
  run, r [args]     Start/restart program with arguments
  continue, c       Continue execution until breakpoint or exit
  step, s           Single step (into functions)
  next, n           Step over (same as step for now)
  quit, q           Detach and exit debugger

Breakpoints:
  break, b <loc>    Set breakpoint (address or symbol name)
  delete, d <n>     Delete breakpoint by number
  info breakpoints  List all breakpoints

Inspection:
  backtrace, bt     Show call stack with symbols
  frame, f <n>      Select stack frame for inspection
  print, p <expr>   Print variable or expression
  x <addr>          Examine memory at address
  info registers    Show CPU registers
  info locals       Show local variables
  help, h           Show all commands
```

Press Enter to repeat the last command. Ctrl+C interrupts the debuggee, not the debugger.

## Requirements

- Linux (x86-64)
- Zig 0.15+
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
│   ├── eval.zig        Expression evaluator
│   ├── elf.zig         ELF parsing
│   ├── regs.zig        Register handling
│   ├── cli.zig         Command interface
│   └── dwarf/
│       ├── mod.zig     DWARF module exports
│       ├── types.zig   DWARF constants
│       ├── abbrev.zig  Abbreviation table parser
│       ├── info.zig    .debug_info DIE parser
│       ├── line.zig    Line number program
│       ├── expr.zig    Location expression evaluator
│       └── frame.zig   Call frame information
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
