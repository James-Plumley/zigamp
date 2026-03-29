const builtin = @import("builtin");
const std = @import("std");
const app_mod = @import("app.zig");
const platform = @import("platform.zig");

const c = platform.c;

var global_window: ?*Window = null;

const Window = struct {
    allocator: std.mem.Allocator,
    app: *app_mod.App,
    hwnd: c.HWND = null,
    hdc: c.HDC = null,
    glrc: c.HGLRC = null,
    width: i32 = 1280,
    height: i32 = 760,
    running: bool = true,
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_pressed: bool = false,
    mouse_down: bool = false,
    mouse_double_clicked: bool = false,
    wheel_steps: i32 = 0,
    scroll_rows: i32 = 0,
    font_base: c.GLuint = 1000,
    click_consumed: bool = false,

    fn init(allocator: std.mem.Allocator, app: *app_mod.App) !Window {
        var window = Window{ .allocator = allocator, .app = app };
        try window.create();
        return window;
    }

    fn deinit(self: *Window) void {
        if (global_window == self) global_window = null;
        if (self.glrc != null) {
            _ = c.wglMakeCurrent(null, null);
            _ = c.wglDeleteContext(self.glrc);
        }
        if (self.hdc != null and self.hwnd != null) _ = c.ReleaseDC(self.hwnd, self.hdc);
        if (self.hwnd != null) _ = c.DestroyWindow(self.hwnd);
    }

    fn create(self: *Window) !void {
        const class_name = try platform.utf8ToWideZ(self.allocator, "ZigAmpWindowClass");
        defer self.allocator.free(class_name);

        const title = try platform.utf8ToWideZ(self.allocator, "ZigAmp");
        defer self.allocator.free(title);

        var wc: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
        wc.style = c.CS_HREDRAW | c.CS_VREDRAW | c.CS_OWNDC | c.CS_DBLCLKS;
        wc.lpfnWndProc = wndProc;
        wc.hInstance = c.GetModuleHandleW(null);
        wc.hCursor = c.LoadCursorW(null, @as(?[*:0]const u16, @ptrFromInt(32512)));
        wc.lpszClassName = class_name.ptr;

        _ = c.RegisterClassW(&wc);

        self.hwnd = c.CreateWindowExW(
            0,
            class_name.ptr,
            title.ptr,
            c.WS_OVERLAPPEDWINDOW | c.WS_VISIBLE,
            c.CW_USEDEFAULT,
            c.CW_USEDEFAULT,
            self.width,
            self.height,
            null,
            null,
            wc.hInstance,
            null,
        );
        if (self.hwnd == null) return error.WindowCreationFailed;

        self.hdc = c.GetDC(self.hwnd);
        if (self.hdc == null) return error.DeviceContextFailed;
        self.refreshClientSize();

        var pfd: c.PIXELFORMATDESCRIPTOR = std.mem.zeroes(c.PIXELFORMATDESCRIPTOR);
        pfd.nSize = @as(c.WORD, @intCast(@sizeOf(c.PIXELFORMATDESCRIPTOR)));
        pfd.nVersion = 1;
        pfd.dwFlags = c.PFD_DRAW_TO_WINDOW | c.PFD_SUPPORT_OPENGL | c.PFD_DOUBLEBUFFER;
        pfd.iPixelType = c.PFD_TYPE_RGBA;
        pfd.cColorBits = 32;
        pfd.cAlphaBits = 8;
        pfd.cDepthBits = 24;
        pfd.iLayerType = c.PFD_MAIN_PLANE;

        const pixel_format = c.ChoosePixelFormat(self.hdc, &pfd);
        if (pixel_format == 0) return error.ChoosePixelFormatFailed;
        if (c.SetPixelFormat(self.hdc, pixel_format, &pfd) == 0) return error.SetPixelFormatFailed;

        self.glrc = c.wglCreateContext(self.hdc);
        if (self.glrc == null) return error.GlContextFailed;
        if (c.wglMakeCurrent(self.hdc, self.glrc) == 0) return error.MakeCurrentFailed;

        self.initFont();
        c.DragAcceptFiles(self.hwnd, c.TRUE);
        _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
        _ = c.UpdateWindow(self.hwnd);

    }

    fn initFont(self: *Window) void {
        const font = c.CreateFontW(
            -16,
            0,
            0,
            0,
            c.FW_NORMAL,
            0,
            0,
            0,
            c.DEFAULT_CHARSET,
            c.OUT_DEFAULT_PRECIS,
            c.CLIP_DEFAULT_PRECIS,
            c.CLEARTYPE_QUALITY,
            c.FF_DONTCARE,
            null,
        );
        if (font == null) return;
        defer _ = c.DeleteObject(font);

        const old = c.SelectObject(self.hdc, font);
        defer _ = c.SelectObject(self.hdc, old);

        _ = c.wglUseFontBitmapsW(self.hdc, 32, 95, self.font_base);
    }

    fn pumpMessages(self: *Window) void {
        var msg: c.MSG = std.mem.zeroes(c.MSG);
        while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
            if (msg.message == c.WM_QUIT) {
                self.running = false;
                break;
            }
            _ = c.TranslateMessage(&msg);
            _ = c.DispatchMessageW(&msg);
        }
    }

    fn applyWheel(self: *Window) void {
        if (self.wheel_steps == 0) return;

        self.scroll_rows -= self.wheel_steps * 3;
        if (self.scroll_rows < 0) self.scroll_rows = 0;

        const visible_rows = @max(1, @divTrunc(self.height - 190, 26));
        const max_scroll = @max(0, @as(i32, @intCast(self.app.tracks.items.len)) - visible_rows);
        if (self.scroll_rows > max_scroll) self.scroll_rows = max_scroll;
        self.wheel_steps = 0;
    }

    fn frame(self: *Window) void {
        self.refreshClientSize();
        self.click_consumed = false;
        self.app.pollPlaybackState();
        self.applyWheel();
        self.render();
        _ = c.SwapBuffers(self.hdc);
        self.mouse_pressed = false;
        self.mouse_double_clicked = false;
    }

    fn button(self: *Window, x: f32, y: f32, w: f32, h: f32, label: []const u8) bool {
        const hovered = self.mouse_x >= @as(i32, @intFromFloat(x)) and
            self.mouse_x < @as(i32, @intFromFloat(x + w)) and
            self.mouse_y >= @as(i32, @intFromFloat(y)) and
            self.mouse_y < @as(i32, @intFromFloat(y + h));

        self.drawRect(x, y, w, h, if (hovered) Color.rgb(0.20, 0.24, 0.29) else Color.rgb(0.13, 0.16, 0.20));
        self.drawOutline(x, y, w, h, Color.rgb(0.28, 0.34, 0.41));
        self.drawText(x + 10, y + 18, label, Color.rgb(0.91, 0.94, 0.97));

        if (hovered and self.mouse_pressed and !self.click_consumed) {
            self.click_consumed = true;
            return true;
        }
        return false;
    }

    fn refreshClientSize(self: *Window) void {
        var rect: c.RECT = std.mem.zeroes(c.RECT);
        if (c.GetClientRect(self.hwnd, &rect) != 0) {
            self.width = rect.right - rect.left;
            self.height = rect.bottom - rect.top;
        }
    }

    fn render(self: *Window) void {
        c.glViewport(0, 0, self.width, self.height);
        c.glClearColor(0.07, 0.08, 0.10, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        c.glMatrixMode(c.GL_PROJECTION);
        c.glLoadIdentity();
        c.glOrtho(0, @as(f64, @floatFromInt(self.width)), @as(f64, @floatFromInt(self.height)), 0, -1, 1);
        c.glMatrixMode(c.GL_MODELVIEW);
        c.glLoadIdentity();

        self.drawHeader();
        self.drawTrackTable();
        self.drawFooter();
    }

    fn drawHeader(self: *Window) void {
        const play_label = if (self.app.current_state == .playing) "Pause" else "Play";

        self.drawRect(0, 0, @floatFromInt(self.width), 74, Color.rgb(0.10, 0.11, 0.14));
        self.drawRect(0, 74, @floatFromInt(self.width), 44, Color.rgb(0.11, 0.13, 0.17));
        self.drawText(20, 26, "ZigAmp", Color.rgb(0.95, 0.97, 0.99));
        self.drawText(120, 26, "OpenGL playlist view, Zig metadata parsing, XSPF import/export.", Color.rgb(0.72, 0.76, 0.80));

        if (self.button(20, 82, 90, 28, "Open")) self.openFiles();
        if (self.button(120, 82, 110, 28, "Save XSPF")) self.saveXspf();
        if (self.button(270, 82, 70, 28, "Prev")) self.app.previous(self.hwnd) catch |err| self.app.setMessageFmt("Previous failed: {s}", .{@errorName(err)});
        if (self.button(350, 82, 90, 28, play_label)) self.app.togglePause(self.hwnd) catch |err| self.app.setMessageFmt("Playback failed: {s}", .{@errorName(err)});
        if (self.button(450, 82, 70, 28, "Stop")) self.app.stopPlayback() catch |err| self.app.setMessageFmt("Stop failed: {s}", .{@errorName(err)});
        if (self.button(530, 82, 70, 28, "Next")) self.app.next(self.hwnd) catch |err| self.app.setMessageFmt("Next failed: {s}", .{@errorName(err)});
    }

    fn drawTrackTable(self: *Window) void {
        const top = 128.0;
        const left = 20.0;
        const width = @as(f32, @floatFromInt(self.width - 40));
        const row_height = 26.0;
        const table_height = @as(f32, @floatFromInt(self.height - 210));

        self.drawRect(left, top, width, table_height, Color.rgb(0.08, 0.09, 0.12));
        self.drawOutline(left, top, width, table_height, Color.rgb(0.18, 0.22, 0.27));

        const columns = [_]Column{
            .{ .label = "Title", .field = .title, .x = left + 10, .w = 320 },
            .{ .label = "Artist", .field = .artist, .x = left + 340, .w = 180 },
            .{ .label = "Album", .field = .album, .x = left + 530, .w = 190 },
            .{ .label = "Track", .field = .track_number, .x = left + 730, .w = 60 },
            .{ .label = "Duration", .field = .duration, .x = left + 800, .w = 80 },
            .{ .label = "Path", .field = .path, .x = left + 890, .w = 330 },
        };

        self.drawRect(left, top, width, row_height, Color.rgb(0.11, 0.14, 0.18));
        for (columns) |column| {
            if (self.headerHit(column.x, top, column.w, row_height)) self.app.sortBy(column.field);
            self.drawText(column.x, top + 18, column.label, Color.rgb(0.87, 0.91, 0.95));
        }

        const visible_rows = @max(1, @as(i32, @intFromFloat((table_height - row_height) / row_height)));
        const start_index = @as(usize, @intCast(self.scroll_rows));
        const end_index = @min(self.app.tracks.items.len, start_index + @as(usize, @intCast(visible_rows)));

        var row_y: f32 = top + row_height;
        var buffer: [256]u8 = undefined;
        var duration_buf: [32]u8 = undefined;
        var i = start_index;
        while (i < end_index) : (i += 1) {
            const track = self.app.tracks.items[i];
            const hovered = self.mouse_x >= @as(i32, @intFromFloat(left)) and
                self.mouse_x < @as(i32, @intFromFloat(left + width)) and
                self.mouse_y >= @as(i32, @intFromFloat(row_y)) and
                self.mouse_y < @as(i32, @intFromFloat(row_y + row_height));

            const selected = self.app.selected_track_id != null and self.app.selected_track_id.? == track.id;
            const current = self.app.current_track_id != null and self.app.current_track_id.? == track.id;

            self.drawRect(
                left,
                row_y,
                width,
                row_height,
                if (current)
                    Color.rgb(0.22, 0.26, 0.19)
                else if (selected)
                    Color.rgb(0.17, 0.22, 0.29)
                else if (hovered)
                    Color.rgb(0.12, 0.14, 0.18)
                else
                    Color.rgb(0.08, 0.09, 0.12),
            );

            if (hovered and self.mouse_pressed and !self.click_consumed) {
                self.click_consumed = true;
                self.app.selected_track_id = track.id;
            }
            if (hovered and self.mouse_double_clicked) self.app.playAt(i, self.hwnd) catch |err| self.app.setMessageFmt("Playback failed: {s}", .{@errorName(err)});

            self.drawText(columns[0].x, row_y + 18, platform.sanitizeDisplayUtf8(track.title, &buffer), Color.rgb(0.92, 0.94, 0.96));
            self.drawText(columns[1].x, row_y + 18, platform.sanitizeDisplayUtf8(track.artist, &buffer), Color.rgb(0.76, 0.80, 0.84));
            self.drawText(columns[2].x, row_y + 18, platform.sanitizeDisplayUtf8(track.album, &buffer), Color.rgb(0.76, 0.80, 0.84));

            const track_num_text = if (track.track_number) |num|
                std.fmt.bufPrint(buffer[0..], "{d}", .{num}) catch ""
            else
                "-";
            self.drawText(columns[3].x, row_y + 18, track_num_text, Color.rgb(0.76, 0.80, 0.84));
            self.drawText(columns[4].x, row_y + 18, self.app.formatDuration(i, duration_buf[0..]), Color.rgb(0.76, 0.80, 0.84));
            self.drawText(columns[5].x, row_y + 18, platform.sanitizeDisplayUtf8(track.path, &buffer), Color.rgb(0.60, 0.66, 0.72));

            row_y += row_height;
        }
    }

    fn drawFooter(self: *Window) void {
        const y = @as(f32, @floatFromInt(self.height - 64));
        self.drawRect(0, y, @floatFromInt(self.width), 64, Color.rgb(0.10, 0.11, 0.14));
        self.drawText(20, y + 24, self.app.message(), Color.rgb(0.90, 0.93, 0.96));

        var footer_buf: [96]u8 = undefined;
        const footer_text = std.fmt.bufPrint(footer_buf[0..], "{d} tracks | {s}", .{ self.app.tracks.items.len, self.app.stateLabel() }) catch self.app.stateLabel();
        self.drawText(@as(f32, @floatFromInt(self.width - 220)), y + 24, footer_text, Color.rgb(0.75, 0.80, 0.85));
    }

    fn drawRect(self: *Window, x: f32, y: f32, w: f32, h: f32, color: Color) void {
        _ = self;
        c.glColor4f(color.r, color.g, color.b, color.a);
        c.glBegin(c.GL_QUADS);
        c.glVertex2f(x, y);
        c.glVertex2f(x + w, y);
        c.glVertex2f(x + w, y + h);
        c.glVertex2f(x, y + h);
        c.glEnd();
    }

    fn drawOutline(self: *Window, x: f32, y: f32, w: f32, h: f32, color: Color) void {
        _ = self;
        c.glColor4f(color.r, color.g, color.b, color.a);
        c.glBegin(c.GL_LINE_LOOP);
        c.glVertex2f(x, y);
        c.glVertex2f(x + w, y);
        c.glVertex2f(x + w, y + h);
        c.glVertex2f(x, y + h);
        c.glEnd();
    }

    fn drawText(self: *Window, x: f32, y: f32, text: []const u8, color: Color) void {
        if (text.len == 0) return;
        c.glColor4f(color.r, color.g, color.b, color.a);
        c.glRasterPos2f(x, y);
        c.glListBase(self.font_base - 32);
        c.glCallLists(@intCast(text.len), c.GL_UNSIGNED_BYTE, text.ptr);
    }

    fn headerHit(self: *Window, x: f32, y: f32, w: f32, h: f32) bool {
        const hovered = self.mouse_x >= @as(i32, @intFromFloat(x)) and
            self.mouse_x < @as(i32, @intFromFloat(x + w)) and
            self.mouse_y >= @as(i32, @intFromFloat(y)) and
            self.mouse_y < @as(i32, @intFromFloat(y + h));
        if (hovered and self.mouse_pressed and !self.click_consumed) {
            self.click_consumed = true;
            return true;
        }
        return false;
    }

    fn openPaths(self: *Window, paths: [][]u8) void {
        var xspf_count: usize = 0;
        var xspf_index: usize = 0;
        for (paths, 0..) |path, index| {
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".xspf")) {
                if (xspf_count == 0) xspf_index = index;
                xspf_count += 1;
            }
        }

        if (xspf_count == 0) {
            self.app.importFilePaths(paths) catch |err| self.app.setMessageFmt("Import failed: {s}", .{@errorName(err)});
            return;
        }

        if (paths.len == 1 and xspf_count == 1) {
            self.app.importXspf(paths[xspf_index]) catch |err| self.app.setMessageFmt("XSPF import failed: {s}", .{@errorName(err)});
            return;
        }

        self.app.setMessage("Open accepts either audio files or one XSPF playlist.");
    }

    fn openFiles(self: *Window) void {
        const filter = platform.buildDialogFilter(
            self.allocator,
            "Openable Media\x00*.mp3;*.wav;*.flac;*.ogg;*.opus;*.m4a;*.aac;*.wma;*.xspf\x00Audio Files\x00*.mp3;*.wav;*.flac;*.ogg;*.opus;*.m4a;*.aac;*.wma\x00XSPF Playlist\x00*.xspf\x00All Files\x00*.*\x00\x00",
        ) catch {
            self.app.setMessage("Failed to build open filter.");
            return;
        };
        defer self.allocator.free(filter);

        var buffer: [65536]u16 = [_]u16{0} ** 65536;
        var ofn: c.OPENFILENAMEW = std.mem.zeroes(c.OPENFILENAMEW);
        ofn.lStructSize = @sizeOf(c.OPENFILENAMEW);
        ofn.hwndOwner = self.hwnd;
        ofn.lpstrFilter = filter.ptr;
        ofn.lpstrFile = buffer[0..].ptr;
        ofn.nMaxFile = @as(c.DWORD, @intCast(buffer.len));
        ofn.Flags = c.OFN_EXPLORER | c.OFN_FILEMUSTEXIST | c.OFN_PATHMUSTEXIST | c.OFN_ALLOWMULTISELECT;

        if (c.GetOpenFileNameW(&ofn) == 0) return;

        const paths = platform.parseMultiSelectBuffer(self.allocator, buffer[0..]) catch {
            self.app.setMessage("Failed to parse selected files.");
            return;
        };
        defer platform.freeStringList(self.allocator, paths);

        self.openPaths(paths);
    }

    fn saveXspf(self: *Window) void {
        const filter = platform.buildDialogFilter(self.allocator, "XSPF Playlist\x00*.xspf\x00All Files\x00*.*\x00\x00") catch {
            self.app.setMessage("Failed to build playlist filter.");
            return;
        };
        defer self.allocator.free(filter);

        var buffer: [4096]u16 = [_]u16{0} ** 4096;
        const default_name = platform.utf8ToWideZ(self.allocator, "playlist.xspf") catch return;
        defer self.allocator.free(default_name);
        std.mem.copyForwards(u16, buffer[0..default_name.len], default_name[0..default_name.len]);

        var ofn: c.OPENFILENAMEW = std.mem.zeroes(c.OPENFILENAMEW);
        ofn.lStructSize = @sizeOf(c.OPENFILENAMEW);
        ofn.hwndOwner = self.hwnd;
        ofn.lpstrFilter = filter.ptr;
        ofn.lpstrFile = buffer[0..].ptr;
        ofn.nMaxFile = @as(c.DWORD, @intCast(buffer.len));
        ofn.Flags = c.OFN_EXPLORER | c.OFN_PATHMUSTEXIST | c.OFN_OVERWRITEPROMPT;

        if (c.GetSaveFileNameW(&ofn) == 0) return;

        const path = platform.utf16ToUtf8Alloc(self.allocator, std.mem.sliceTo(buffer[0..], 0)) catch {
            self.app.setMessage("Failed to decode save path.");
            return;
        };
        defer self.allocator.free(path);

        self.app.exportXspf(path) catch |err| self.app.setMessageFmt("XSPF export failed: {s}", .{@errorName(err)});
    }
};

const Column = struct {
    label: []const u8,
    field: app_mod.SortField,
    x: f32,
    w: f32,
};

const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b };
    }
};

pub fn main() !void {
    if (builtin.os.tag != .windows) {
        std.log.err("This build currently targets Windows only.", .{});
        return;
    }

    const allocator = std.heap.page_allocator;

    var app = app_mod.App.init(allocator);
    defer app.deinit();

    var window = try Window.init(allocator, &app);
    global_window = &window;
    defer window.deinit();

    while (window.running) {
        window.pumpMessages();
        window.frame();
        c.Sleep(8);
    }
}

export fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const window = global_window;

    switch (msg) {
        c.WM_CLOSE => {
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_DESTROY => {
            if (window) |w| w.running = false;
            c.PostQuitMessage(0);
            return 0;
        },
        c.WM_SIZE => {
            if (window) |w| {
                const size_bits: usize = @bitCast(lparam);
                w.width = @as(i32, @intCast(size_bits & 0xffff));
                w.height = @as(i32, @intCast((size_bits >> 16) & 0xffff));
            }
            return 0;
        },
        c.WM_MOUSEMOVE => {
            if (window) |w| {
                const mouse_bits: usize = @bitCast(lparam);
                const x_bits = @as(u16, @intCast(mouse_bits & 0xffff));
                const y_bits = @as(u16, @intCast((mouse_bits >> 16) & 0xffff));
                w.mouse_x = @as(i16, @bitCast(x_bits));
                w.mouse_y = @as(i16, @bitCast(y_bits));
            }
            return 0;
        },
        c.WM_LBUTTONDOWN => {
            if (window) |w| {
                w.mouse_down = true;
                w.mouse_pressed = true;
            }
            return 0;
        },
        c.WM_LBUTTONUP => {
            if (window) |w| w.mouse_down = false;
            return 0;
        },
        c.WM_LBUTTONDBLCLK => {
            if (window) |w| w.mouse_double_clicked = true;
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            if (window) |w| {
                const delta = @as(i16, @bitCast(@as(u16, @truncate((wparam >> 16) & 0xffff))));
                w.wheel_steps += @divTrunc(delta, @as(i16, @intCast(c.WHEEL_DELTA)));
            }
            return 0;
        },
        c.WM_KEYDOWN => {
            if (window) |w| {
                switch (wparam) {
                    c.VK_SPACE => w.app.togglePause(hwnd) catch {},
                    c.VK_RETURN => w.app.playSelected(hwnd) catch {},
                    c.VK_LEFT => w.app.previous(hwnd) catch {},
                    c.VK_RIGHT => w.app.next(hwnd) catch {},
                    c.VK_ESCAPE => w.app.stopPlayback() catch {},
                    else => {},
                }
            }
            return 0;
        },
        c.WM_DROPFILES => {
            if (window) |w| {
                const drop_handle: c.HDROP = @ptrFromInt(@as(usize, @intCast(wparam)));
                const count = c.DragQueryFileW(drop_handle, 0xFFFFFFFF, null, 0);
                var paths = std.array_list.Managed([]u8).init(w.allocator);
                defer {
                    for (paths.items) |item| w.allocator.free(item);
                    paths.deinit();
                    c.DragFinish(drop_handle);
                }

                var i: c.UINT = 0;
                while (i < count) : (i += 1) {
                    const length = c.DragQueryFileW(drop_handle, i, null, 0);
                    const wide = w.allocator.alloc(u16, @as(usize, @intCast(length)) + 1) catch continue;
                    defer w.allocator.free(wide);
                    _ = c.DragQueryFileW(drop_handle, i, wide.ptr, length + 1);

                    const utf8 = platform.utf16ToUtf8Alloc(w.allocator, wide[0..length]) catch continue;
                    paths.append(utf8) catch {
                        w.allocator.free(utf8);
                        continue;
                    };
                }

                w.openPaths(paths.items);
            }
            return 0;
        },
        c.MM_MCINOTIFY => {
            if (window) |w| {
                if (wparam == c.MCI_NOTIFY_SUCCESSFUL) {
                    w.app.notifyPlaybackEnded(hwnd);
                }
            }
            return 0;
        },
        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
