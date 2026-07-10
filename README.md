# ruskcore

A RISC-V CPU written in Veryl.

## Build

Zig, Veryl, and Verilator are required.

```sh
# Generate SystemVerilog with Veryl
zig build

# Build the Verilator simulator
zig build sim

# Run memory image with an optional cycle limit
zig build run -- path/to/memory.hex 1000
```

## Test

By default, `zig build test` recursively runs the `.hex` files under `test/share/riscv-tests`.
A different directory and optional filename filters can be passed after `--`.

```sh
zig build test
zig build test -- path/to/tests
zig build test -- path/to/tests rv32ui rv32mi
```

## Utilities

```sh
# Format Veryl sources
zig build fmt

# Remove Veryl-generated files
zig build clean

# Convert a binary to a little-endian hex memory image
zig build bin2hex -- 4 path/to/input.bin
```
