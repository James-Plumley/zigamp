const std = @import("std");
const metadata = @import("metadata.zig");
const playback = @import("playback.zig");
const platform = @import("platform.zig");
const xspf = @import("xspf.zig");

pub const SortField = enum {
    added,
    title,
    artist,
    album,
    duration,
    track_number,
    path,
};

pub const Track = struct {
    id: u64,
    added_order: u64,
    path: []u8,
    title: []u8,
    artist: []u8,
    album: []u8,
    track_number: ?u32,
    duration_ms: ?u32,

    pub fn deinit(self: *Track, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.title);
        allocator.free(self.artist);
        allocator.free(self.album);
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    player: playback.Player,
    tracks: std.array_list.Managed(Track),
    selected_track_id: ?u64 = null,
    current_track_id: ?u64 = null,
    next_track_id: u64 = 1,
    next_added_order: u64 = 1,
    sort_field: SortField = .added,
    sort_descending: bool = false,
    current_state: playback.State = .stopped,
    suppress_auto_advance: bool = false,
    message_buf: [256]u8 = [_]u8{0} ** 256,
    message_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) App {
        var app = App{
            .allocator = allocator,
            .player = playback.Player.init(allocator),
            .tracks = std.array_list.Managed(Track).init(allocator),
        };
        app.setMessage("Import audio files or open an XSPF playlist.");
        return app;
    }

    pub fn deinit(self: *App) void {
        self.player.deinit();
        for (self.tracks.items) |*track| track.deinit(self.allocator);
        self.tracks.deinit();
    }

    pub fn message(self: *const App) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    pub fn setMessage(self: *App, text: []const u8) void {
        self.message_len = @min(text.len, self.message_buf.len);
        std.mem.copyForwards(u8, self.message_buf[0..self.message_len], text[0..self.message_len]);
    }

    pub fn setMessageFmt(self: *App, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(self.message_buf[0..], fmt, args) catch {
            self.message_len = 0;
            return;
        };
        self.message_len = written.len;
    }

    fn addTrack(self: *App, path: []const u8, meta: metadata.Metadata) !void {
        var owned = meta;
        errdefer owned.deinit(self.allocator);

        const duplicated_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(duplicated_path);

        const track = Track{
            .id = self.next_track_id,
            .added_order = self.next_added_order,
            .path = duplicated_path,
            .title = owned.title,
            .artist = owned.artist,
            .album = owned.album,
            .track_number = owned.track_number,
            .duration_ms = owned.duration_ms,
        };

        self.next_track_id += 1;
        self.next_added_order += 1;
        self.tracks.append(track) catch |err| {
            self.allocator.free(duplicated_path);
            return err;
        };
        self.selected_track_id = track.id;
    }

    fn indexById(self: *const App, track_id: u64) ?usize {
        for (self.tracks.items, 0..) |track, index| {
            if (track.id == track_id) return index;
        }
        return null;
    }

    pub fn selectedIndex(self: *const App) ?usize {
        if (self.selected_track_id) |track_id| return self.indexById(track_id);
        return null;
    }

    pub fn currentIndex(self: *const App) ?usize {
        if (self.current_track_id) |track_id| return self.indexById(track_id);
        return null;
    }

    pub fn importFilePaths(self: *App, paths: [][]u8) !void {
        var imported_count: usize = 0;
        var probe_player = playback.Player.init(self.allocator);
        defer probe_player.deinit();

        for (paths) |path| {
            const meta = metadata.readMetadata(self.allocator, &probe_player, path) catch |err| {
                self.setMessageFmt("Metadata read failed for {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
                continue;
            };
            try self.addTrack(path, meta);
            imported_count += 1;
        }

        self.sortTracks();
        if (imported_count > 0) self.setMessageFmt("Imported {d} audio file(s).", .{imported_count});
    }

    fn mergeImportedTrack(self: *App, item: xspf.ImportedTrack) !void {
        var imported = item;
        errdefer imported.deinit(self.allocator);
        var probe_player = playback.Player.init(self.allocator);
        defer probe_player.deinit();

        var meta = metadata.readMetadata(self.allocator, &probe_player, imported.path) catch metadata.Metadata{
            .title = try self.allocator.dupe(u8, if (imported.title.len > 0) imported.title else std.fs.path.basename(imported.path)),
            .artist = try self.allocator.dupe(u8, imported.artist),
            .album = try self.allocator.dupe(u8, imported.album),
            .track_number = imported.track_number,
            .duration_ms = imported.duration_ms,
        };

        if (imported.title.len > 0 and std.mem.eql(u8, meta.title, std.fs.path.basename(imported.path))) {
            try metadata.setOwnedString(self.allocator, &meta.title, imported.title);
        }
        if (imported.artist.len > 0 and meta.artist.len == 0) {
            try metadata.setOwnedString(self.allocator, &meta.artist, imported.artist);
        }
        if (imported.album.len > 0 and meta.album.len == 0) {
            try metadata.setOwnedString(self.allocator, &meta.album, imported.album);
        }
        if (meta.track_number == null) meta.track_number = imported.track_number;
        if (meta.duration_ms == null) meta.duration_ms = imported.duration_ms;

        try self.addTrack(imported.path, meta);
    }

    pub fn clearTracks(self: *App) void {
        self.stopPlayback() catch {};
        for (self.tracks.items) |*track| track.deinit(self.allocator);
        self.tracks.clearRetainingCapacity();
        self.selected_track_id = null;
        self.current_track_id = null;
        self.current_state = .stopped;
    }

    pub fn importXspf(self: *App, path: []const u8) !void {
        const imported = try xspf.loadFromFile(self.allocator, path);
        defer {
            for (imported) |*item| item.deinit(self.allocator);
            self.allocator.free(imported);
        }

        self.clearTracks();
        for (imported) |item| try self.mergeImportedTrack(item);
        self.sortTracks();
        self.setMessageFmt("Loaded playlist: {s}", .{std.fs.path.basename(path)});
    }

    pub fn exportXspf(self: *App, path: []const u8) !void {
        const items = try self.allocator.alloc(xspf.ImportedTrack, self.tracks.items.len);
        defer {
            for (items) |*item| item.deinit(self.allocator);
            self.allocator.free(items);
        }

        for (self.tracks.items, 0..) |track, index| {
            items[index] = .{
                .path = try self.allocator.dupe(u8, track.path),
                .title = try self.allocator.dupe(u8, track.title),
                .artist = try self.allocator.dupe(u8, track.artist),
                .album = try self.allocator.dupe(u8, track.album),
                .track_number = track.track_number,
                .duration_ms = track.duration_ms,
            };
        }

        try xspf.writeToFile(self.allocator, path, items);
        self.setMessageFmt("Saved playlist: {s}", .{std.fs.path.basename(path)});
    }

    fn orderForField(self: *const App, a: Track, b: Track) std.math.Order {
        const primary = switch (self.sort_field) {
            .added => compareInt(a.added_order, b.added_order),
            .title => compareText(a.title, b.title),
            .artist => compareText(a.artist, b.artist),
            .album => compareText(a.album, b.album),
            .duration => compareOptionalInt(a.duration_ms, b.duration_ms),
            .track_number => compareOptionalInt(a.track_number, b.track_number),
            .path => compareText(a.path, b.path),
        };

        if (primary != .eq) {
            return if (self.sort_descending) invertOrder(primary) else primary;
        }
        return compareInt(a.added_order, b.added_order);
    }

    pub fn sortTracks(self: *App) void {
        var i: usize = 1;
        while (i < self.tracks.items.len) : (i += 1) {
            var j = i;
            while (j > 0 and self.orderForField(self.tracks.items[j - 1], self.tracks.items[j]) == .gt) : (j -= 1) {
                std.mem.swap(Track, &self.tracks.items[j - 1], &self.tracks.items[j]);
            }
        }
    }

    pub fn sortBy(self: *App, field: SortField) void {
        if (self.sort_field == field) {
            self.sort_descending = !self.sort_descending;
        } else {
            self.sort_field = field;
            self.sort_descending = false;
        }
        self.sortTracks();
    }

    pub fn playAt(self: *App, index: usize, hwnd: platform.c.HWND) !void {
        if (index >= self.tracks.items.len) return error.IndexOutOfBounds;

        try self.player.open(self.tracks.items[index].path);
        try self.player.play(hwnd);
        self.current_track_id = self.tracks.items[index].id;
        self.selected_track_id = self.current_track_id;
        self.current_state = .playing;
        self.suppress_auto_advance = false;
        self.setMessageFmt("Playing: {s}", .{self.tracks.items[index].title});
    }

    pub fn playSelected(self: *App, hwnd: platform.c.HWND) !void {
        if (self.selectedIndex()) |index| try self.playAt(index, hwnd);
    }

    pub fn togglePause(self: *App, hwnd: platform.c.HWND) !void {
        if (self.current_track_id == null) return self.playSelected(hwnd);

        switch (self.current_state) {
            .playing => {
                try self.player.pause();
                self.current_state = .paused;
                self.setMessage("Paused.");
            },
            .paused => {
                try self.player.resumePlayback();
                self.current_state = .playing;
                self.setMessage("Resumed.");
            },
            .stopped => {
                if (self.currentIndex()) |index| try self.playAt(index, hwnd);
            },
        }
    }

    pub fn stopPlayback(self: *App) !void {
        self.suppress_auto_advance = true;
        try self.player.stop();
        self.current_state = .stopped;
        self.setMessage("Stopped.");
    }

    pub fn next(self: *App, hwnd: platform.c.HWND) !void {
        if (self.tracks.items.len == 0) return;
        const current_index = self.currentIndex() orelse 0;
        const next_index = if (current_index + 1 < self.tracks.items.len) current_index + 1 else 0;
        try self.playAt(next_index, hwnd);
    }

    pub fn previous(self: *App, hwnd: platform.c.HWND) !void {
        if (self.tracks.items.len == 0) return;
        const current_index = self.currentIndex() orelse 0;
        const prev_index = if (current_index == 0) self.tracks.items.len - 1 else current_index - 1;
        try self.playAt(prev_index, hwnd);
    }

    pub fn pollPlaybackState(self: *App) void {
        self.current_state = self.player.queryMode() catch self.current_state;
        if (self.suppress_auto_advance and self.current_state == .stopped) {
            self.suppress_auto_advance = false;
        }
    }

    pub fn notifyPlaybackEnded(self: *App, hwnd: platform.c.HWND) void {
        if (self.suppress_auto_advance) {
            self.suppress_auto_advance = false;
            return;
        }
        self.next(hwnd) catch {};
    }

    pub fn formatDuration(self: *const App, index: usize, buffer: []u8) []const u8 {
        const duration = self.tracks.items[index].duration_ms orelse return "--:--";
        const total_seconds = duration / 1000;
        const minutes = total_seconds / 60;
        const seconds = total_seconds % 60;
        return std.fmt.bufPrint(buffer, "{d}:{d:0>2}", .{ minutes, seconds }) catch "--:--";
    }

    pub fn stateLabel(self: *const App) []const u8 {
        return switch (self.current_state) {
            .stopped => "Stopped",
            .playing => "Playing",
            .paused => "Paused",
        };
    }
};

fn invertOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

fn compareText(a: []const u8, b: []const u8) std.math.Order {
    const len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const lhs = std.ascii.toLower(a[i]);
        const rhs = std.ascii.toLower(b[i]);
        if (lhs < rhs) return .lt;
        if (lhs > rhs) return .gt;
    }

    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return .eq;
}

fn compareInt(a: anytype, b: @TypeOf(a)) std.math.Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
}

fn compareOptionalInt(a: anytype, b: @TypeOf(a)) std.math.Order {
    if (a == null and b == null) return .eq;
    if (a == null) return .gt;
    if (b == null) return .lt;
    return compareInt(a.?, b.?);
}
