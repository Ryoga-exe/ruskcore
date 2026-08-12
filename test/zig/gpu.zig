const base: usize = 0x1001_0000;

const status = reg(0x00);
const command = reg(0x04);
const x = reg(0x08);
const y = reg(0x0c);
const w = reg(0x10);
const h = reg(0x14);
const color = reg(0x18);
const data = reg(0x1c);

const regs = struct {
    pub const base: u32 = 0x1001_0000;
    pub const status: *volatile u32 = @ptrFromInt(base + 0x00);
};

const op = struct {
    pub const clear: u8 = 1;
    pub const fill_rect: u8 = 2;
    pub const set_pallete: u8 = 4;
    pub const present: u8 = 5;
};

fn reg(offset: usize) *volatile u32 {
    return @ptrFromInt(base + offset);
}

fn waitIdle() void {
    while (status.* & 1 == 0) {}
}

fn palette() void {
    x.* = 0;
    w.* = 2;
    command.* = 4; // SET_PALETTE
    data.* = 0x000000; // palette 0: black
    data.* = 0xffffff; // palette 1: white
}

fn show(value: u8, frame: u8) void {
    waitIdle();
    color.* = value;
    command.* = 1; // CLEAR

    waitIdle();
    command.* = @as(u32, frame) << 8 | 5; // PRESENT
}

pub export fn main() noreturn {
    palette();

    waitIdle();
    color.* = 0;

    var frame: u8 = 0;
    while (true) {
        show(0, frame);
        frame +%= 1;
        show(1, frame);
        frame +%= 1;
    }
}
