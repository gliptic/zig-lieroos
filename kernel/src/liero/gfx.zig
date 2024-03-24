pub fn ImageCursor(T: type) type {
    return struct {
        pixels: T,
        pitch: u32,
        bpp: u32,
    };
}

pub fn ImageSlice(T: type) type {
    const Cursor = ImageCursor(T);

    return struct {
        const Self = @This();

        cursor: Cursor,
        dim: @Vector(2, u32),

        pub fn toCursor(self: Self) Cursor {
            return self.cursor;
        }

        pub fn pixelPtr(self: Self, x: u32, y: u32, bpp: u32) T {
            return self.cursor.pixels + y*self.cursor.pitch + x*bpp;
        }
    };
}

pub const ImageSliceMut = ImageSlice([*]u8);
pub const ImageSliceConst = ImageSlice([*]const u8);

const BaseBlitContext = struct {
    dim: @Vector(2, u32),

    const CursorMut = ImageCursor([*]u8);
    const Cursor = ImageCursor([*]const u8);
    const SliceMut = ImageSlice([*]u8);
    const Slice = ImageSlice([*]const u8);

    pub fn init(
        self: *BaseBlitContext,
        sources: [*]Cursor, from: [*]Slice, source_count: usize,
        targets: [*]CursorMut, to: [*]SliceMut, target_count: usize,
        x: *i32, y: *i32) void {

        self.dim = from[0].dim;
        const todim = to[0].dim;

        const src = clip(&self.dim, x, y, todim);

        //for (u32 i = 0; i < source_count; ++i) {
        for (0..source_count) |i| {
            const fbpp = from[i].cursor.bpp;
            sources[i].pixels = from[i].pixelPtr(src[0], src[1], fbpp);
            sources[i].pitch = from[i].cursor.pitch;
            sources[i].bpp = fbpp;
        }

        //for (u32 i = 0; i < target_count; ++i) {
        for (0..target_count) |i| {
            const tbpp = to[i].cursor.bpp;
            targets[i].pixels = to[i].pixelPtr(@intCast(x.*), @intCast(y.*), tbpp);
            targets[i].pitch = to[i].cursor.pitch;
            targets[i].bpp = tbpp;
        }
    }
};

pub const BlitContext = struct {
    base: BaseBlitContext,
    targets: [1]ImageCursor([*]u8),
    sources: [1]ImageCursor([*]const u8),
};

pub const Color = struct {
    c: @Vector(4, u8),

    pub fn r(self: Color) u8 {
        self.c[2];
    }

    pub fn g(self: Color) u8 {
        self.c[1];
    }

    pub fn b(self: Color) u8 {
        self.c[0];
    }

    pub fn a(self: Color) u8 {
        self.c[3];
    }
};

pub fn oneSource(to: ImageSlice([*]u8), from: ImageSlice([*]const u8), x: i32, y: i32) BlitContext {
    var x_ = x;
    var y_ = y;

    var ctx: BlitContext = .{
        .base = undefined,
        .targets = .{ to.toCursor() },
        .sources = .{ from.toCursor() },
    };

    var t: [1]ImageSlice([*]u8) = .{ to };
    var s: [1]ImageSlice([*]const u8) = .{ from };

    ctx.base.init(&ctx.sources, &s, 1, &ctx.targets, &t, 1, &x_, &y_);
    return ctx;
}

pub fn clip(dim: *@Vector(2, u32), x: *i32, y: *i32, todim: @Vector(2, u32)) @Vector(2, u32) {
    
    var src: @Vector(2, u32) = .{ 0, 0 };
    if (y.* < 0) {
        if (y.* < -@as(i32, @intCast(dim[1]))) {
            dim[1] = 0;
        } else {
            src[1] = @intCast(-y.*);
            dim[1] +%= @bitCast(y.*);
            y.* = 0;
        }
    }
    
    if (y.* + @as(i32, @intCast(dim[1])) > @as(i32, @intCast(todim[1]))) {
        if (y.* >= @as(i32, @intCast(todim[1]))) {
            dim[1] = 0;
        } else {
            dim[1] = todim[1] -% @as(u32, @bitCast(y.*));
        }
    }

    if (x.* < 0) {
        if (x.* < -@as(i32, @intCast(dim[0]))) {
            dim[0] = 0;
        } else {
            src[0] = @intCast(-x.*);
            dim[0] +%= @bitCast(x.*);
            x.* = 0;
        }
    }

    if (x.* + @as(i32, @intCast(dim[0])) > @as(i32, @intCast(todim[0]))) {
        if (x.* >= @as(i32, @intCast(todim[0]))) {
            dim[0] = 0;
        } else {
            dim[0] = todim[0] -% @as(u32, @bitCast(x.*));
        }
    }

    return src;
}

pub inline fn blit1To1(ctx: anytype, plotter: anytype) void {
    const tpitch = ctx.targets[0].pitch;
    const fpitch = ctx.sources[0].pitch;
    var tp = ctx.targets[0].pixels;
    var fp = ctx.sources[0].pixels;
    var hleft = ctx.base.dim[1];
    const w = ctx.base.dim[1];
    const tbpp = ctx.targets[0].bpp;
    const fbpp = ctx.sources[0].bpp;

    while (hleft > 0) {
        hleft -= 1;
        
        plotter.scanline(w, tbpp, fbpp, tp, fp);

        tp += tpitch;
        fp += fpitch;
    }
}