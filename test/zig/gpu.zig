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
    var back: u1 = 1;
    var x: i32 = 16;
    var y: i32 = 12;
    var prev_x = [2]i32{ x, x };
    var prev_y = [2]i32{ y, y };

    var dx: i32 = 3;
    var dy: i32 = 2;

    while (true) {
        graphics.fillRect(@intCast(prev_x[back]), @intCast(prev_y[back]), 32, 24, 0);
        graphics.fillRect(@intCast(x), @intCast(y), 32, 24, 1);
        graphics.present(frame);

        prev_x[back] = x;
        prev_y[back] = y;

        frame +%= 1;
        back = ~back;

        x += dx;
        y += dy;

        if (x <= 0) {
            x = 0;
            dx = -dx;
        } else if (x >= 320 - 32) {
            x = 320 - 32;
            dx = -dx;
        }

        if (y <= 0) {
            y = 0;
            dy = -dy;
        } else if (y >= 200 - 24) {
            y = 200 - 24;
            dy = -dy;
        }
    }
}
