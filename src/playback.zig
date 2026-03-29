const std = @import("std");
const platform = @import("platform.zig");
const c = platform.c;

pub const State = enum {
    stopped,
    playing,
    paused,
};

pub const Player = struct {
    allocator: std.mem.Allocator,
    last_state: State = .stopped,
    has_open_file: bool = false,

    pub fn init(allocator: std.mem.Allocator) Player {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Player) void {
        self.closeCurrent() catch {};
    }

    fn aliasName() []const u8 {
        return "zigamp";
    }

    fn send(self: *Player, command: []const u8, out_buffer: ?[]u16, callback: c.HWND) !void {
        const wide = try platform.utf8ToWideZ(self.allocator, command);
        defer self.allocator.free(wide);

        const out_ptr = if (out_buffer) |buf| buf.ptr else null;
        const out_len: c.UINT = if (out_buffer) |buf| @intCast(buf.len) else 0;

        const result = c.mciSendStringW(wide.ptr, out_ptr, out_len, callback);
        if (result != 0) return error.MciCommandFailed;
    }

    pub fn open(self: *Player, path: []const u8) !void {
        self.closeCurrent() catch {};

        const open_cmd = try std.fmt.allocPrint(self.allocator, "open \"{s}\" alias {s}", .{ path, aliasName() });
        defer self.allocator.free(open_cmd);
        try self.send(open_cmd, null, null);

        const format_cmd = try std.fmt.allocPrint(self.allocator, "set {s} time format milliseconds", .{aliasName()});
        defer self.allocator.free(format_cmd);
        try self.send(format_cmd, null, null);

        self.has_open_file = true;
        self.last_state = .stopped;
    }

    pub fn play(self: *Player, hwnd: c.HWND) !void {
        if (!self.has_open_file) return error.NoFileOpen;

        const cmd = try std.fmt.allocPrint(self.allocator, "play {s} notify", .{aliasName()});
        defer self.allocator.free(cmd);
        try self.send(cmd, null, hwnd);
        self.last_state = .playing;
    }

    pub fn pause(self: *Player) !void {
        if (!self.has_open_file) return error.NoFileOpen;

        const cmd = try std.fmt.allocPrint(self.allocator, "pause {s}", .{aliasName()});
        defer self.allocator.free(cmd);
        try self.send(cmd, null, null);
        self.last_state = .paused;
    }

    pub fn resumePlayback(self: *Player) !void {
        if (!self.has_open_file) return error.NoFileOpen;

        const cmd = try std.fmt.allocPrint(self.allocator, "resume {s}", .{aliasName()});
        defer self.allocator.free(cmd);
        try self.send(cmd, null, null);
        self.last_state = .playing;
    }

    pub fn stop(self: *Player) !void {
        if (!self.has_open_file) return;

        const stop_cmd = try std.fmt.allocPrint(self.allocator, "stop {s}", .{aliasName()});
        defer self.allocator.free(stop_cmd);
        _ = self.send(stop_cmd, null, null) catch {};

        const seek_cmd = try std.fmt.allocPrint(self.allocator, "seek {s} to start", .{aliasName()});
        defer self.allocator.free(seek_cmd);
        _ = self.send(seek_cmd, null, null) catch {};

        self.last_state = .stopped;
    }

    pub fn closeCurrent(self: *Player) !void {
        if (!self.has_open_file) return;

        const cmd = try std.fmt.allocPrint(self.allocator, "close {s}", .{aliasName()});
        defer self.allocator.free(cmd);
        _ = self.send(cmd, null, null) catch {};

        self.has_open_file = false;
        self.last_state = .stopped;
    }

    pub fn queryMode(self: *Player) !State {
        if (!self.has_open_file) return .stopped;

        var buffer: [64]u16 = [_]u16{0} ** 64;
        const cmd = try std.fmt.allocPrint(self.allocator, "status {s} mode", .{aliasName()});
        defer self.allocator.free(cmd);
        try self.send(cmd, buffer[0..], null);

        const mode_utf8 = try platform.utf16ToUtf8Alloc(self.allocator, std.mem.sliceTo(buffer[0..], 0));
        defer self.allocator.free(mode_utf8);

        if (std.mem.eql(u8, mode_utf8, "playing")) return .playing;
        if (std.mem.eql(u8, mode_utf8, "paused")) return .paused;
        return .stopped;
    }

    fn queryNumeric(self: *Player, command: []const u8) !?u32 {
        if (!self.has_open_file) return null;

        var buffer: [64]u16 = [_]u16{0} ** 64;
        try self.send(command, buffer[0..], null);

        const text = try platform.utf16ToUtf8Alloc(self.allocator, std.mem.sliceTo(buffer[0..], 0));
        defer self.allocator.free(text);

        return std.fmt.parseInt(u32, std.mem.trim(u8, text, " \r\n\t"), 10) catch null;
    }

    pub fn lengthMs(self: *Player) !?u32 {
        const cmd = try std.fmt.allocPrint(self.allocator, "status {s} length", .{aliasName()});
        defer self.allocator.free(cmd);
        return self.queryNumeric(cmd);
    }

    pub fn positionMs(self: *Player) !?u32 {
        const cmd = try std.fmt.allocPrint(self.allocator, "status {s} position", .{aliasName()});
        defer self.allocator.free(cmd);
        return self.queryNumeric(cmd);
    }

    pub fn probeDurationMs(self: *Player, path: []const u8) !?u32 {
        self.open(path) catch return null;
        defer self.closeCurrent() catch {};
        return self.lengthMs();
    }
};
