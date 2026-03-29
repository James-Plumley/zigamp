const std = @import("std");
const platform = @import("platform.zig");
const c = @cImport({
    @cInclude("stdio.h");
});

pub const ImportedTrack = struct {
    path: []u8,
    title: []u8,
    artist: []u8,
    album: []u8,
    track_number: ?u32 = null,
    duration_ms: ?u32 = null,

    pub fn deinit(self: *ImportedTrack, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.title);
        allocator.free(self.artist);
        allocator.free(self.album);
    }
};

fn readFileAbsoluteAllocCompat(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try openWideFile(allocator, path, "rb");
    defer _ = c.fclose(file);

    if (c._fseeki64(file, 0, c.SEEK_END) != 0) return error.FileSeekFailed;
    const file_size = c._ftelli64(file);
    if (file_size < 0) return error.FileSeekFailed;
    if (@as(u64, @intCast(file_size)) > max_bytes) return error.FileTooLarge;
    if (c._fseeki64(file, 0, c.SEEK_SET) != 0) return error.FileSeekFailed;

    const len = @as(usize, @intCast(file_size));
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);

    const read_len = c.fread(bytes.ptr, 1, bytes.len, file);
    return bytes[0..read_len];
}

fn writeFileAbsoluteCompat(path: []const u8, bytes: []const u8) !void {
    const file = try openWideFile(std.heap.page_allocator, path, "wb");
    defer _ = c.fclose(file);

    const written = c.fwrite(bytes.ptr, 1, bytes.len, file);
    if (written != bytes.len) return error.FileWriteFailed;
}

fn openWideFile(allocator: std.mem.Allocator, path: []const u8, mode: []const u8) !*c.FILE {
    const wide_path = try platform.utf8ToWideZ(allocator, path);
    defer allocator.free(wide_path);
    const wide_mode = try platform.utf8ToWideZ(allocator, mode);
    defer allocator.free(wide_mode);

    const file = c._wfopen(wide_path.ptr, wide_mode.ptr);
    if (file == null) return error.FileOpenFailed;
    return file;
}

fn extractTagAlloc(allocator: std.mem.Allocator, haystack: []const u8, tag: []const u8) !?[]u8 {
    const open_tag = try std.fmt.allocPrint(allocator, "<{s}>", .{tag});
    defer allocator.free(open_tag);
    const close_tag = try std.fmt.allocPrint(allocator, "</{s}>", .{tag});
    defer allocator.free(close_tag);

    const start = std.mem.indexOf(u8, haystack, open_tag) orelse return null;
    const content_start = start + open_tag.len;
    const end_rel = std.mem.indexOf(u8, haystack[content_start..], close_tag) orelse return null;
    const raw = haystack[content_start .. content_start + end_rel];
    return try platform.xmlUnescapeAlloc(allocator, raw);
}

pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) ![]ImportedTrack {
    const bytes = try readFileAbsoluteAllocCompat(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(bytes);

    var tracks = std.array_list.Managed(ImportedTrack).init(allocator);
    errdefer {
        for (tracks.items) |*track| track.deinit(allocator);
        tracks.deinit();
    }

    var cursor: usize = 0;
    while (true) {
        const start_rel = std.mem.indexOf(u8, bytes[cursor..], "<track>") orelse break;
        const start = cursor + start_rel + "<track>".len;
        const end_rel = std.mem.indexOf(u8, bytes[start..], "</track>") orelse break;
        const block = bytes[start .. start + end_rel];
        cursor = start + end_rel + "</track>".len;

        const location = try extractTagAlloc(allocator, block, "location");
        if (location == null) continue;
        defer allocator.free(location.?);

        const file_path = try platform.uriToFilePathAlloc(allocator, location.?);
        errdefer allocator.free(file_path);

        const title = (try extractTagAlloc(allocator, block, "title")) orelse try allocator.dupe(u8, "");
        errdefer allocator.free(title);

        const artist = (try extractTagAlloc(allocator, block, "creator")) orelse try allocator.dupe(u8, "");
        errdefer allocator.free(artist);

        const album = (try extractTagAlloc(allocator, block, "album")) orelse try allocator.dupe(u8, "");
        errdefer allocator.free(album);

        const track_number = blk: {
            const text = (try extractTagAlloc(allocator, block, "trackNum")) orelse break :blk null;
            defer allocator.free(text);
            break :blk std.fmt.parseInt(u32, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
        };

        const duration_ms = blk: {
            const text = (try extractTagAlloc(allocator, block, "duration")) orelse break :blk null;
            defer allocator.free(text);
            break :blk std.fmt.parseInt(u32, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
        };

        try tracks.append(.{
            .path = file_path,
            .title = title,
            .artist = artist,
            .album = album,
            .track_number = track_number,
            .duration_ms = duration_ms,
        });
    }

    return tracks.toOwnedSlice();
}

pub fn writeToFile(allocator: std.mem.Allocator, path: []const u8, tracks: []const ImportedTrack) !void {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    try out.appendSlice(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<playlist xmlns="http://xspf.org/ns/0/" version="1">
        \\  <title>ZigAmp Playlist</title>
        \\  <trackList>
        \\
    );

    for (tracks) |track| {
        const uri = try platform.filePathToUriAlloc(allocator, track.path);
        defer allocator.free(uri);

        const esc_title = try platform.xmlEscapeAlloc(allocator, track.title);
        defer allocator.free(esc_title);

        const esc_artist = try platform.xmlEscapeAlloc(allocator, track.artist);
        defer allocator.free(esc_artist);

        const esc_album = try platform.xmlEscapeAlloc(allocator, track.album);
        defer allocator.free(esc_album);

        const esc_uri = try platform.xmlEscapeAlloc(allocator, uri);
        defer allocator.free(esc_uri);

        try out.print("    <track>\n      <location>{s}</location>\n", .{esc_uri});
        if (track.title.len > 0) try out.print("      <title>{s}</title>\n", .{esc_title});
        if (track.artist.len > 0) try out.print("      <creator>{s}</creator>\n", .{esc_artist});
        if (track.album.len > 0) try out.print("      <album>{s}</album>\n", .{esc_album});
        if (track.track_number) |num| try out.print("      <trackNum>{d}</trackNum>\n", .{num});
        if (track.duration_ms) |dur| try out.print("      <duration>{d}</duration>\n", .{dur});
        try out.appendSlice("    </track>\n");
    }

    try out.appendSlice(
        \\  </trackList>
        \\</playlist>
        \\
    );

    try writeFileAbsoluteCompat(path, out.items);
}

test "round trip location escaping" {
    const allocator = std.testing.allocator;
    const uri = try platform.filePathToUriAlloc(allocator, "C:\\Music\\Test Track.mp3");
    defer allocator.free(uri);

    const decoded = try platform.uriToFilePathAlloc(allocator, uri);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings("C:\\Music\\Test Track.mp3", decoded);
}
