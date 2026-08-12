const graphics = struct {
    const regs = struct {
        const base: u32 = 0x1001_0000;
        const status: *volatile u32 = @ptrFromInt(base + 0x00);
        const command: *volatile u32 = @ptrFromInt(base + 0x04);
        const x: *volatile u32 = @ptrFromInt(base + 0x08);
        const y: *volatile u32 = @ptrFromInt(base + 0x0c);
        const w: *volatile u32 = @ptrFromInt(base + 0x10);
        const h: *volatile u32 = @ptrFromInt(base + 0x14);
        const color: *volatile u32 = @ptrFromInt(base + 0x18);
        const data: *volatile u32 = @ptrFromInt(base + 0x1c);
    };

    const ops = struct {
        const clear: u8 = 1;
        const fill_rect: u8 = 2;
        const set_pallete: u8 = 4;
        const present: u8 = 5;
    };

    fn waitIdle() void {
        while (regs.status.* & 1 == 0) {}
    }

    fn issue(op: u8, arg: u8) void {
        regs.command.* = @as(u32, op) | (@as(u32, arg) << 8);
    }

    fn clear() void {
        waitIdle();
        regs.color.* = 0;
        issue(ops.clear, 0);
    }

    fn fillRect(x: u32, y: u32, w: u32, h: u32, color: u8) void {
        waitIdle();
        regs.x.* = x;
        regs.y.* = y;
        regs.w.* = w;
        regs.h.* = h;
        regs.color.* = color;
        issue(ops.fill_rect, 0);
    }

    fn present(frame: u8) void {
        waitIdle();
        issue(ops.present, frame);
    }
};

pub export fn main() noreturn {
    // set pallete
    {
        graphics.waitIdle();

        graphics.regs.x.* = 0;
        graphics.regs.w.* = 4;
        graphics.issue(graphics.ops.set_pallete, 0);
        graphics.regs.data.* = 0x000000;
        graphics.regs.data.* = 0xff0000;
        graphics.regs.data.* = 0xffff00;
        graphics.regs.data.* = 0xff00ff;
    }

    graphics.clear();
    graphics.present(0);
    graphics.clear();
    graphics.present(1);

    var frame: u8 = 0;
    while (true) {
        graphics.fillRect(100, 100, 100, 100, 1);
        graphics.present(frame);
        frame +%= 1;
    }
}
