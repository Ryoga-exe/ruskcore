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

```sh
# Build all test images without running them
zig build riscv-tests

# Run all tests (the command fails while any test is failing)
zig build test

# Change the maximum simulation cycles per test (0 disables the limit)
zig build test -Dtest-cycles=2000000

# Build or run tests whose fully-qualified names contain the filter
zig build riscv-tests -- rv32mi
zig build test -- add
```

The test runner prints every PASS/FAIL result and writes the summary and per-test simulator output under `zig-out/test-results`.

## Utilities

```sh
# Format Veryl sources
zig build fmt

# Remove Veryl-generated files
zig build clean

# Convert a binary to a little-endian hex memory image
zig build bin2hex -- 4 path/to/input.bin
```
