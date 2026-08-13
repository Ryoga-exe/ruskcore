const uart = struct {
    const base: u32 = 0x1000_0000;
    const rbr: *volatile u8 = @ptrFromInt(base + 0x00);
    const thr: *volatile u8 = @ptrFromInt(base + 0x00);
    const lsr: *volatile u8 = @ptrFromInt(base + 0x05);

    fn getChar() u8 {
        while ((lsr.* & 0x01) == 0) {}
        return rbr.*;
    }

    fn putChar(c: u8) void {
        while ((lsr.* & 0x20) == 0) {}
        thr.* = c;
    }
};

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

    const op_clear: u8 = 1;
    const op_upload_rect: u8 = 3;
    const op_set_palette: u8 = 4;
    const op_present: u8 = 5;

    fn waitIdle() void {
        while ((regs.status.* & 0x01) == 0) {}
    }

    fn issue(op: u8, arg: u8) void {
        regs.command.* = @as(u32, op) | (@as(u32, arg) << 8);
    }

    fn clear(color: u8) void {
        waitIdle();
        regs.color.* = color;
        issue(op_clear, 0);
        waitIdle();
    }

    fn present(frame: u8) void {
        waitIdle();
        issue(op_present, frame);
        waitIdle();
    }

    fn setRgb332Palette() void {
        waitIdle();
        regs.x.* = 0;
        regs.w.* = 256;
        issue(op_set_palette, 0);

        var index: u32 = 0;
        while (index < 256) : (index += 1) {
            const r3: u32 = (index >> 5) & 0x07;
            const g3: u32 = (index >> 2) & 0x07;
            const b2: u32 = index & 0x03;
            const r8: u32 = (r3 * 255) / 7;
            const g8: u32 = (g3 * 255) / 7;
            const b8: u32 = (b2 * 255) / 3;
            regs.data.* = (r8 << 16) | (g8 << 8) | b8;
        }
        waitIdle();
    }

    fn uploadRow(x: u16, y: u16, row: *const [screen_width]u8, width: u16) void {
        waitIdle();
        regs.x.* = x;
        regs.y.* = y;
        regs.w.* = width;
        regs.h.* = 1;
        issue(op_upload_rect, 0);

        var offset: usize = 0;
        while (offset < width) : (offset += 4) {
            var word: u32 = row[offset];
            if (offset + 1 < width) word |= @as(u32, row[offset + 1]) << 8;
            if (offset + 2 < width) word |= @as(u32, row[offset + 2]) << 16;
            if (offset + 3 < width) word |= @as(u32, row[offset + 3]) << 24;
            regs.data.* = word;
        }
        waitIdle();
    }
};

const screen_width: usize = 320;
const screen_height: u16 = 200;
const magic = [_]u8{ 'R', 'I', 'M', 'G' };
const protocol_version: u8 = 1;
const ack: u8 = 0x06;
const nak: u8 = 0x15;

const Header = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    frame: u8,
};

fn readU16() u16 {
    const low: u16 = uart.getChar();
    const high: u16 = uart.getChar();
    return low | (high << 8);
}

fn waitForMagic() void {
    var matched: usize = 0;
    while (matched < magic.len) {
        const byte = uart.getChar();
        if (byte == magic[matched]) {
            matched += 1;
        } else if (byte == magic[0]) {
            matched = 1;
        } else {
            matched = 0;
        }
    }
}

fn readHeader() ?Header {
    waitForMagic();
    if (uart.getChar() != protocol_version) return null;

    const header = Header{
        .x = readU16(),
        .y = readU16(),
        .width = readU16(),
        .height = readU16(),
        .frame = uart.getChar(),
    };

    if (header.width == 0 or header.height == 0) return null;
    if (@as(u32, header.x) + header.width > screen_width) return null;
    if (@as(u32, header.y) + header.height > screen_height) return null;
    return header;
}

pub export fn main() callconv(.c) noreturn {
    graphics.setRgb332Palette();

    // Start with two identical black buffers.
    graphics.clear(0);
    graphics.present(0);
    graphics.clear(0);
    graphics.present(1);

    var row: [screen_width]u8 = undefined;

    while (true) {
        const header = readHeader() orelse {
            uart.putChar(nak);
            continue;
        };

        // ACK
        uart.putChar(ack);

        var row_index: u16 = 0;
        var frame = header.frame;
        while (row_index < header.height) : (row_index += 1) {
            var column: usize = 0;
            while (column < header.width) : (column += 1) {
                row[column] = uart.getChar();
            }

            const y = header.y + row_index;
            graphics.uploadRow(header.x, y, &row, header.width);
            graphics.present(frame);

            // copy
            graphics.uploadRow(header.x, y, &row, header.width);

            frame +%= 1;
            uart.putChar(ack);
        }
    }
}
