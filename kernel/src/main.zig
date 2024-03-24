const limine = @import("limine");
const std = @import("std");
const assert = std.debug.assert;
const builtin = std.builtin;
const AtomicOrder = std.builtin.AtomicOrder;

const liero = @import("./liero/liero.zig");

// The Limine requests can be placed anywhere, but it is important that
// the compiler does not optimise them away, so, usually, they should
// be made volatile or equivalent. In Zig, `export var` is what we use.
pub export var framebuffer_request: limine.FramebufferRequest = .{};

// Set the base revision to 1, this is recommended as this is the latest
// base revision described by the Limine boot protocol specification.
// See specification for further info.
pub export var base_revision: limine.BaseRevision = .{ .revision = 1 };

const IntFrame = packed struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,

    int_num: u64,
    err: u64,

    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

const IdtDescriptor = packed struct {
    limit: u16,
    offset: u64,
};

const InterruptDescriptor64 = packed struct {
    offset_low: u16,
    segment_selector: u16,
    ist: u8, // only first 2 bits are used, the rest is 0
    flags: u8, // P(resent) DPL (0) TYPE
    offset_high: u48,
    reserved: u32, //0
};


const TssEntry = packed struct {
    size: u16,
    base_low: u16,
    base_mid: u8,
    flags0: u8,
    flags1: u8,
    base_high: u8,
    base_upper: u32,
    reserved0: u32,
};

const TssDescriptor = packed struct  {
    reserved0: u32,
    rsp0: u64,
    rsp1: u64,
    rsp2: u64,
    reserved1: u64,
    ist0: u64,
    ist1: u64,
    ist2: u64,
    ist3: u64,
    ist4: u64,
    ist5: u64,
    ist6: u64,
    reserved2: u32,
    reserved3: u32,
    reserved4: u16,
    iomap_base: u16,
};

const GdtEntry = packed struct {
    limit_low: u16,
    base_low: u24,
    access: packed struct {
        accessed: u1,
        read_write: u1,
        direction: u1,
        executable: u1,
        is_segment: u1,
        privilege_level: u2,
        present: u1
    },
    flags: packed union {
        byte: packed struct {
            dummy0: u4,
            byte: u4,
        },
        bits: packed struct {
            limit_high: u4,
            available: u1,
            long_mode: u1,
            data_size: u1,
            granularity: u1,
        }
    },
    base_high: u8,
};

comptime {
    assert(@offsetOf(IdtDescriptor, "limit") == 0);
    assert(@offsetOf(IdtDescriptor, "offset") == 2);
    assert(@bitSizeOf(IdtDescriptor) == 80);
    assert(@sizeOf(IdtDescriptor) == 16); // FIXME: Should actually be 10, but does it matter?
    assert(@sizeOf(InterruptDescriptor64) == 16);
    assert(256 * @sizeOf(@TypeOf(idt[0])) - 1 == 256 * 16 - 1);
    assert(@sizeOf(TssEntry) == 16);
    assert(@sizeOf(GdtEntry) == 8);
    assert(@bitSizeOf(TssDescriptor) == 104 * 8);
    assert(@sizeOf(TssDescriptor) == 104);
}

const GdtEntries = extern struct {
    entries: [11]GdtEntry,
    tss: TssEntry,
};

const GdtDescriptor = packed struct {
    size: u16,
    addr: u64,
};

const KERNEL16_CS: u8 = 0x08;
const KERNEL16_DS: u8 = 0x10;
const KERNEL32_CS: u8 = 0x18;
const KERNEL32_DS: u8 = 0x20;
const KERNEL64_CS: u8 = 0x28;
const KERNEL64_DS: u8 = 0x30;
const KERNEL_SYSENTER_CS: u8 = 0x38;
const KERNEL_SYSENTER_DS: u8 = 0x40;
const USER_CS: u8 = 0x48;
const USER_DS: u8 = 0x50;

const IDT_PRESENT_FLAG: u8 = 0x80;
const IDT_INTERRUPT_TYPE_FLAG: u8 = 0x0E;
const IDT_SEGMENT_SELECTOR: u8 = 0x08;

var idt_desc: IdtDescriptor = undefined;
var idt: [256]InterruptDescriptor64 = undefined;

var gdtDesc: GdtDescriptor = undefined;
var gdt: GdtEntries = undefined;
var tss: TssDescriptor = undefined;

pub fn asByteSlice(value: anytype) []u8 {
    return @as([*]u8, @ptrCast(value))[0..@sizeOf(@TypeOf(value.*))];
}

inline fn enableInt() void {
    asm volatile ("sti");
}

inline fn disableInt() void {
    asm volatile ("cli");
}

inline fn inportb(portnum: u16) u8 {
    return asm volatile ("inb %[portnum], %[ret]"
        : [ret] "={al}" (-> u8),
        : [portnum] "{dx}" (portnum)
        :);
}

inline fn outportb(portnum: u16, data: u8) void {
    asm volatile ("outb %[data], %[portnum]"
        :
        : [portnum] "{dx}" (portnum),
          [data] "{al}" (data)
        :);
}

inline fn done() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

fn setIdtEntry(idx: u16, flags: u8, selector: u16, ist: u8, handler: fn() callconv(.C) void) void {
    idt[idx].flags = flags;
    idt[idx].ist = ist;
    idt[idx].segment_selector = selector;

    const handlerInt: u64 = @intFromPtr(&handler);
    idt[idx].offset_low = @intCast(handlerInt & 0xFFFF);
    idt[idx].offset_high = @intCast(handlerInt >> 16);
    idt[idx].reserved = 0x0;
}

const GDT_READ_WRITE: u32 = 1;
const GDT_EXECUTABLE: u32 = 1 << 1;
const GDT_LONG_MODE: u32 = 1 << 2;
const GDT_DATA32: u32 = 1 << 3;
const GDT_GRANULARITY4KiB: u32 = 1 << 4;

const DPL0: u32 = 0; // ring 0 (kernelspace)
const DPL3: u32 = 3; // ring 3 (userspace)

fn createGdtEntry(limit: u32, base: u32, priv: u2, flags: u32) GdtEntry {
    var entry: GdtEntry = undefined;

    entry.limit_low = @intCast(limit & 0xffff);
    entry.flags.bits.limit_high = @intCast(limit >> 16);

    entry.base_low = @intCast(base & 0xffffff);
    entry.base_high = @intCast(base >> 24);

    entry.access.accessed = 0;
    entry.access.read_write = @intFromBool((flags & GDT_READ_WRITE) != 0);
    entry.access.direction = 0;
    entry.access.executable = @intFromBool((flags & GDT_EXECUTABLE) != 0);
    entry.access.is_segment = 1;
    entry.access.privilege_level = priv;
    entry.access.present = 1;

    entry.flags.bits.available = 0;
    entry.flags.bits.long_mode = @intFromBool((flags & GDT_LONG_MODE) != 0);
    entry.flags.bits.data_size = @intFromBool((flags & GDT_DATA32) != 0);
    entry.flags.bits.granularity = @intFromBool((flags & GDT_GRANULARITY4KiB) != 0);

    return entry;
}

fn createNullGdtEntry() GdtEntry {
    var entry: GdtEntry = undefined;

    entry.limit_low = 0;
    entry.flags.bits.limit_high = 0;

    entry.base_low = 0;
    entry.base_high = 0;

    entry.access.accessed = 0;
    entry.access.read_write = 0;
    entry.access.direction = 0;
    entry.access.executable = 0;
    entry.access.is_segment = 0;
    entry.access.privilege_level = 0;
    entry.access.present = 0;

    entry.flags.bits.available = 0;
    entry.flags.bits.long_mode = 0;
    entry.flags.bits.data_size = 0;
    entry.flags.bits.granularity = 0;

    return entry;
}

fn createTss() TssEntry {
    const addr: usize = @intFromPtr(&tss);

    @memset(asByteSlice(&tss), 0);

    return .{
        .size = @sizeOf(@TypeOf(tss)),
        .base_low = @intCast(addr & 0xffff),
        .base_mid = @intCast((addr >> 16) & 0xff),
        .flags0 = 0b10001001,
        .flags1 = 0,
        .base_high = @intCast((addr >> 24) & 0xff),
        .base_upper = @intCast(addr >> 32),
        .reserved0 = 0
    };
}

extern fn gdtLoad(ptr: *const GdtDescriptor, code: u16, data: u16) callconv(.C) void;

fn gdtStart() void {

    gdt.entries[0] = createNullGdtEntry();

    gdt.entries[KERNEL16_CS / 8] = createGdtEntry(0xffff, 0x0, DPL0, GDT_EXECUTABLE | GDT_READ_WRITE);
    gdt.entries[KERNEL16_DS / 8] = createGdtEntry(0xffff, 0x0, DPL0, GDT_READ_WRITE);

    gdt.entries[KERNEL32_CS / 8] = createGdtEntry(0xfffff, 0x0, DPL0, GDT_EXECUTABLE | GDT_READ_WRITE | GDT_DATA32 | GDT_GRANULARITY4KiB);
    gdt.entries[KERNEL32_DS / 8] = createGdtEntry(0xfffff, 0x0, DPL0, GDT_READ_WRITE | GDT_DATA32 | GDT_GRANULARITY4KiB);

    gdt.entries[KERNEL64_CS / 8] = createGdtEntry(0x0, 0x0, DPL0, GDT_READ_WRITE | GDT_EXECUTABLE | GDT_LONG_MODE);
    gdt.entries[KERNEL64_DS / 8] = createGdtEntry(0x0, 0x0, DPL0, GDT_READ_WRITE);

    gdt.entries[KERNEL_SYSENTER_CS / 8] = createNullGdtEntry();
    gdt.entries[KERNEL_SYSENTER_DS / 8] = createNullGdtEntry();

    gdt.entries[USER_CS / 8] = createGdtEntry(0x0, 0x0, DPL3, GDT_READ_WRITE | GDT_EXECUTABLE | GDT_LONG_MODE);
    gdt.entries[USER_DS / 8] = createGdtEntry(0x0, 0x0, DPL3, GDT_READ_WRITE);

    gdt.tss = createTss();

    gdtDesc.addr = @intFromPtr(&gdt);
    gdtDesc.size = @sizeOf(@TypeOf(gdt)) - 1;

    gdtLoad(&gdtDesc, KERNEL64_CS, KERNEL64_DS);
}

var counter: u32 = 0;
var key_buffer: [1024]u8 =  undefined;
var key_buffer_read: u32 = 0;
var key_buffer_write: u32 = 0;
var handler_called: bool = false;

export fn isrHandler(frame: *IntFrame) void {

    if (frame.int_num >= 8 and frame.int_num < 8 + 16) {
        const irq = frame.int_num - 8;
        if (irq == 0) {
            handler_called = true;

            @atomicStore(u32, &counter, counter + 1, AtomicOrder.monotonic); // FIXME: What ordering is necessary?
        } else if (irq == 1) {

            const scan_code = inportb(0x60);

            key_buffer[key_buffer_write] = scan_code;
            key_buffer_write = (key_buffer_write + 1) & (1024 - 1);
        }
        
        if (irq >= 8) {
            outportb(0xA0, 0x20);
        }
        outportb(0x20, 0x20);
    } else if (frame.int_num == 49) {
        // Test interrupt
    }
}

extern fn isr0() void;
extern fn isr1() void;
extern fn isr2() void;
extern fn isr3() void;
extern fn isr4() void;
extern fn isr5() void;
extern fn isr6() void;
extern fn isr7() void;
extern fn isr8() void;
extern fn isr9() void;
extern fn isr10() void;
extern fn isr11() void;
extern fn isr12() void;
extern fn isr13() void;
extern fn isr14() void;
extern fn isr15() void;
extern fn isr16() void;
extern fn isr17() void;
extern fn isr18() void;
extern fn isr19() void;
extern fn isr20() void;
extern fn isr21() void;
extern fn isr22() void;
extern fn isr23() void;
extern fn isr24() void;
extern fn isr25() void;
extern fn isr26() void;
extern fn isr27() void;
extern fn isr28() void;
extern fn isr29() void;
extern fn isr30() void;
extern fn isr31() void;
extern fn isr33() void;
extern fn isr49() void;

pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;

    if (framebuffer_request.response) |framebuffer_response| {
        if (framebuffer_response.framebuffer_count < 1) {
            done();
        }

        // Get the first framebuffer's information.
        const framebuffer = framebuffer_response.framebuffers()[0];

        for (0..framebuffer.height) |y| {
            const pixel_offset = y * framebuffer.pitch;
            const begin: [*]u32 = @ptrCast(@alignCast(framebuffer.address + pixel_offset));
            @memset(begin[0..framebuffer.width], 0xff00007f);
        }

        const screen: liero.gfx.ImageSlice([*]u8) = .{
            .cursor = .{
                .pixels = framebuffer.address,
                .pitch = @intCast(framebuffer.pitch), //320 * 4,
                .bpp = 4,
            },
            .dim = .{ @intCast(framebuffer.width), @intCast(framebuffer.height) }
        };

        // FIXME
        // if (error_return_trace) |trace| {
        //     
        // }

        drawText(screen, 0xffffffff, msg, 100, 100);
    }

    while (true) {
        @breakpoint();
    }
}

fn idtStart() void {
    @memset(asByteSlice(&idt), 0);

    setIdtEntry(0x00, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr0);
    
    setIdtEntry(0x01, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr1);
    setIdtEntry(0x02, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr2);
    setIdtEntry(0x03, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr3);
    setIdtEntry(0x04, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr4);
    setIdtEntry(0x05, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr5);
    setIdtEntry(0x06, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr6);
    setIdtEntry(0x07, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr7);
    setIdtEntry(0x08, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr8);
    setIdtEntry(0x09, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr9);
    setIdtEntry(0x0A, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr10);
    setIdtEntry(0x0B, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr11);
    setIdtEntry(0x0C, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr12);
    setIdtEntry(0x0D, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr13);
    setIdtEntry(0x0E, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr14);
    setIdtEntry(0x0F, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr15);
    setIdtEntry(0x10, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr16);
    setIdtEntry(0x11, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr17);
    setIdtEntry(0x12, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr18);
    setIdtEntry(0x21, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr33);

    setIdtEntry(49, IDT_PRESENT_FLAG | IDT_INTERRUPT_TYPE_FLAG, KERNEL64_CS, 0, isr49);

    idt_desc.limit = 256 * @sizeOf(@TypeOf(idt[0])) - 1;
    idt_desc.offset = @intFromPtr(&idt);

    const idt_ptr: *const IdtDescriptor = &idt_desc;
    asm volatile ("lidt (%%rax)"
        :
        : [idtPtr] "{rax}" (idt_ptr));
}

fn br() void {
    asm volatile("1: jmp 1b");
}

// Assumes interrupts are off
fn setPitCount(count: u32) void {

    // Set low byte
    outportb(0x40, @intCast(count & 0xFF));		// Low byte
    outportb(0x40, @intCast((count & 0xFF00) >> 8));	// High byte
    return;
}

inline fn hlt() void {
    asm volatile ("hlt");
}

fn sleep() void {
    const current = @atomicLoad(u32, &counter, AtomicOrder.monotonic);
    while (current == @atomicLoad(u32, &counter, AtomicOrder.monotonic)) {
        hlt();
    }
}

const CharPlotter = struct {
    color: u32,

    pub fn init(color: u32) CharPlotter {
        return .{
            .color = color
        };
    }

    // pub fn check(self: PixelChar, tbpp: u32, fbpp: u32) !void {
    //     if ()
    // }

    pub fn scanline(self: CharPlotter, w: u32, tbpp: u32, fbpp: u32, tp: [*]u8, fp: [*]const u8) void {
        _ = tbpp;
        _ = fbpp;
        for (0..w) |x| {
            if (fp[x] != 0) {
                @as(*u32, @alignCast(@ptrCast(tp + x * 4))).* = self.color;
            }
        }
    }
};

pub fn drawText(target: liero.gfx.ImageSliceMut, color: u32, text: []const u8, x: i32, y: i32) void {
    var tx = x;

    for (text) |c| {
        const chr: liero.gfx.ImageSlice([*]const u8) = .{
            .cursor = .{
                .pixels = @ptrCast(&liero.tc.font[@as(usize, c) * 64]),
                .pitch = 8,
                .bpp = 1,
            },
            .dim = .{ 8, 8 }
        };

        liero.gfx.blit1To1(liero.gfx.oneSource(target, chr, tx, y), CharPlotter.init(color));
        tx += liero.tc.fontWidths[c];
    }
}

export fn _start() callconv(.C) noreturn {

    gdtStart();
    idtStart();

    outportb(0x43, 0b00110100); // channel 0, lobyte/hibyte, rate generator
    setPitCount(17045);

    outportb(0x21, 0b11111100); // PIC1 data
    outportb(0xa1, 0b11111111); // PIC2 data
    enableInt();

    asm volatile ("int $49");

    if (!base_revision.is_supported()) {
        done();
    }

    var offset: usize = 10;

    while (true) {

        if (framebuffer_request.response) |framebuffer_response| {
            if (framebuffer_response.framebuffer_count < 1) {
                done();
            }

            const framebuffer = framebuffer_response.framebuffers()[0];

            const screen: liero.gfx.ImageSlice([*]u8) = .{
                .cursor = .{
                    .pixels = framebuffer.address,
                    .pitch = @intCast(framebuffer.pitch), //320 * 4,
                    .bpp = 4,
                },
                .dim = .{ @intCast(framebuffer.width), @intCast(framebuffer.height) }
            };

            drawText(screen, 0xffffffff, "HELLO WORLD", 200, 200);

            sleep();

            for (0..100) |i| {
                const pixel_offset = offset * 4 + (i + key_buffer_write) * framebuffer.pitch + (i + offset + counter) * 4;

                @as(*u32, @ptrCast(@alignCast(framebuffer.address + pixel_offset))).* = 0xFFFF00FF + (@as(u32, @intCast(offset & 0xff)) << 8);
            }
        }

        if (@atomicLoad(bool, &handler_called, AtomicOrder.seq_cst)) {
            offset = (offset + 1) & 0xff;
        }
    }

    done();
}
