const std = @import("std");
const playback = @import("playback.zig");
const platform = @import("platform.zig");
const c = @cImport({
    @cInclude("stdio.h");
});

pub const Metadata = struct {
    title: []u8,
    artist: []u8,
    album: []u8,
    track_number: ?u32 = null,
    duration_ms: ?u32 = null,

    pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.artist);
        allocator.free(self.album);
    }
};

pub fn readMetadata(allocator: std.mem.Allocator, player: *playback.Player, path: []const u8) !Metadata {
    var meta = Metadata{
        .title = try allocator.dupe(u8, defaultTitle(path)),
        .artist = try allocator.dupe(u8, ""),
        .album = try allocator.dupe(u8, ""),
        .track_number = null,
        .duration_ms = null,
    };
    errdefer meta.deinit(allocator);

    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".mp3")) {
        try parseMp3(allocator, path, &meta);
    } else if (std.ascii.eqlIgnoreCase(extension, ".flac")) {
        try parseFlac(allocator, path, &meta);
    } else if (std.ascii.eqlIgnoreCase(extension, ".ogg") or std.ascii.eqlIgnoreCase(extension, ".opus")) {
        try parseOggLike(allocator, path, &meta);
    } else if (std.ascii.eqlIgnoreCase(extension, ".wav")) {
        try parseWav(allocator, path, &meta);
    }

    if (meta.duration_ms == null) meta.duration_ms = try player.probeDurationMs(path);
    return meta;
}

pub fn setOwnedString(allocator: std.mem.Allocator, field: *[]u8, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n\x00");
    if (trimmed.len == 0) return;

    const replacement = try allocator.dupe(u8, trimmed);
    allocator.free(field.*);
    field.* = replacement;
}

fn defaultTitle(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(base);
    if (ext.len == 0) return base;
    return base[0 .. base.len - ext.len];
}

fn readPrefixAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try openWideFile(allocator, path, "rb");
    defer _ = c.fclose(file);

    if (c._fseeki64(file, 0, c.SEEK_END) != 0) return error.FileSeekFailed;
    const file_size = c._ftelli64(file);
    if (file_size < 0) return error.FileSeekFailed;
    if (c._fseeki64(file, 0, c.SEEK_SET) != 0) return error.FileSeekFailed;

    const length = @min(max_bytes, @as(usize, @intCast(file_size)));
    var buffer = try allocator.alloc(u8, length);
    errdefer allocator.free(buffer);

    const read_len = c.fread(buffer.ptr, 1, buffer.len, file);
    return buffer[0..read_len];
}

fn readTailAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try openWideFile(allocator, path, "rb");
    defer _ = c.fclose(file);

    if (c._fseeki64(file, 0, c.SEEK_END) != 0) return error.FileSeekFailed;
    const file_size = c._ftelli64(file);
    if (file_size < 0) return error.FileSeekFailed;

    const total_size = @as(usize, @intCast(file_size));
    const length = @min(max_bytes, total_size);
    var buffer = try allocator.alloc(u8, length);
    errdefer allocator.free(buffer);

    const start = total_size - length;
    if (c._fseeki64(file, @as(i64, @intCast(start)), c.SEEK_SET) != 0) return error.FileSeekFailed;
    const read_len = c.fread(buffer.ptr, 1, buffer.len, file);
    return buffer[0..read_len];
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

fn parseSynchsafe(bytes: []const u8) u32 {
    return (@as(u32, bytes[0] & 0x7f) << 21) |
        (@as(u32, bytes[1] & 0x7f) << 14) |
        (@as(u32, bytes[2] & 0x7f) << 7) |
        @as(u32, bytes[3] & 0x7f);
}

fn parseBe32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

fn latin1ToUtf8Alloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();

    for (text) |byte| {
        if (byte < 0x80) {
            try list.append(byte);
        } else {
            var buf: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(byte, &buf);
            try list.appendSlice(buf[0..len]);
        }
    }

    return list.toOwnedSlice();
}

fn utf16BytesToUtf8Alloc(allocator: std.mem.Allocator, bytes: []const u8, big_endian: bool) ![]u8 {
    const usable_len = bytes.len - (bytes.len % 2);
    const units = try allocator.alloc(u16, usable_len / 2);
    defer allocator.free(units);

    var i: usize = 0;
    while (i < usable_len) : (i += 2) {
        const idx = i / 2;
        units[idx] = if (big_endian)
            (@as(u16, bytes[i]) << 8) | bytes[i + 1]
        else
            (@as(u16, bytes[i + 1]) << 8) | bytes[i];
    }

    return std.unicode.utf16LeToUtf8Alloc(allocator, units);
}

fn decodeTextFrameAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    if (payload.len == 0) return allocator.dupe(u8, "");

    const encoding = payload[0];
    const raw = std.mem.trim(u8, payload[1..], "\x00");

    switch (encoding) {
        0 => return latin1ToUtf8Alloc(allocator, raw),
        1 => {
            if (raw.len >= 2 and raw[0] == 0xfe and raw[1] == 0xff) return utf16BytesToUtf8Alloc(allocator, raw[2..], true);
            if (raw.len >= 2 and raw[0] == 0xff and raw[1] == 0xfe) return utf16BytesToUtf8Alloc(allocator, raw[2..], false);
            return utf16BytesToUtf8Alloc(allocator, raw, false);
        },
        2 => return utf16BytesToUtf8Alloc(allocator, raw, true),
        3 => return allocator.dupe(u8, raw),
        else => return allocator.dupe(u8, ""),
    }
}

fn parseTrackNumber(text: []const u8) ?u32 {
    const slash_index = std.mem.indexOfScalar(u8, text, '/') orelse text.len;
    return std.fmt.parseInt(u32, std.mem.trim(u8, text[0..slash_index], " \t\r\n"), 10) catch null;
}

fn parseMp3(allocator: std.mem.Allocator, path: []const u8, meta: *Metadata) !void {
    const prefix = try readPrefixAlloc(allocator, path, 512 * 1024);
    defer allocator.free(prefix);

    if (prefix.len >= 10 and std.mem.eql(u8, prefix[0..3], "ID3")) {
        const version = prefix[3];
        const tag_size = parseSynchsafe(prefix[6..10]);
        const end = @min(prefix.len, 10 + @as(usize, tag_size));
        var cursor: usize = 10;

        while (cursor + 10 <= end) {
            const frame_id = prefix[cursor .. cursor + 4];
            if (std.mem.allEqual(u8, frame_id, 0)) break;

            const frame_size = if (version == 4)
                parseSynchsafe(prefix[cursor + 4 .. cursor + 8])
            else
                parseBe32(prefix[cursor + 4 .. cursor + 8]);

            if (frame_size == 0) break;

            const payload_start = cursor + 10;
            const payload_end = payload_start + @as(usize, frame_size);
            if (payload_end > end) break;
            const payload = prefix[payload_start..payload_end];

            if (std.mem.eql(u8, frame_id, "TIT2")) {
                const text = try decodeTextFrameAlloc(allocator, payload);
                defer allocator.free(text);
                try setOwnedString(allocator, &meta.title, text);
            } else if (std.mem.eql(u8, frame_id, "TPE1")) {
                const text = try decodeTextFrameAlloc(allocator, payload);
                defer allocator.free(text);
                try setOwnedString(allocator, &meta.artist, text);
            } else if (std.mem.eql(u8, frame_id, "TALB")) {
                const text = try decodeTextFrameAlloc(allocator, payload);
                defer allocator.free(text);
                try setOwnedString(allocator, &meta.album, text);
            } else if (std.mem.eql(u8, frame_id, "TRCK")) {
                const text = try decodeTextFrameAlloc(allocator, payload);
                defer allocator.free(text);
                meta.track_number = parseTrackNumber(text) orelse meta.track_number;
            } else if (std.mem.eql(u8, frame_id, "TLEN")) {
                const text = try decodeTextFrameAlloc(allocator, payload);
                defer allocator.free(text);
                meta.duration_ms = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \t\r\n"), 10) catch meta.duration_ms;
            }

            cursor = payload_end;
        }
    }

    const tail = try readTailAlloc(allocator, path, 128);
    defer allocator.free(tail);
    if (tail.len == 128 and std.mem.eql(u8, tail[0..3], "TAG")) {
        if (std.mem.eql(u8, meta.title, defaultTitle(path))) {
            try setOwnedString(allocator, &meta.title, std.mem.trim(u8, tail[3..33], "\x00 "));
        }
        if (meta.artist.len == 0) try setOwnedString(allocator, &meta.artist, std.mem.trim(u8, tail[33..63], "\x00 "));
        if (meta.album.len == 0) try setOwnedString(allocator, &meta.album, std.mem.trim(u8, tail[63..93], "\x00 "));
    }
}

fn parseLe32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn parseVorbisComments(allocator: std.mem.Allocator, block: []const u8, meta: *Metadata) !void {
    if (block.len < 8) return;

    var cursor: usize = 0;
    const vendor_len = parseLe32(block[cursor..]);
    cursor += 4 + @as(usize, vendor_len);
    if (cursor + 4 > block.len) return;

    const comment_count = parseLe32(block[cursor..]);
    cursor += 4;

    var i: u32 = 0;
    while (i < comment_count and cursor + 4 <= block.len) : (i += 1) {
        const len = parseLe32(block[cursor..]);
        cursor += 4;
        if (cursor + len > block.len) break;

        const entry = block[cursor .. cursor + len];
        cursor += len;

        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        const value = entry[eq + 1 ..];

        if (std.ascii.eqlIgnoreCase(key, "TITLE")) {
            try setOwnedString(allocator, &meta.title, value);
        } else if (std.ascii.eqlIgnoreCase(key, "ARTIST")) {
            try setOwnedString(allocator, &meta.artist, value);
        } else if (std.ascii.eqlIgnoreCase(key, "ALBUM")) {
            try setOwnedString(allocator, &meta.album, value);
        } else if (std.ascii.eqlIgnoreCase(key, "TRACKNUMBER")) {
            meta.track_number = std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t\r\n"), 10) catch meta.track_number;
        }
    }
}

fn parseFlac(allocator: std.mem.Allocator, path: []const u8, meta: *Metadata) !void {
    const bytes = try readPrefixAlloc(allocator, path, 512 * 1024);
    defer allocator.free(bytes);

    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "fLaC")) return;

    var cursor: usize = 4;
    var last_block = false;
    while (!last_block and cursor + 4 <= bytes.len) {
        const header = bytes[cursor];
        last_block = (header & 0x80) != 0;
        const block_type = header & 0x7f;
        const block_len = (@as(usize, bytes[cursor + 1]) << 16) | (@as(usize, bytes[cursor + 2]) << 8) | bytes[cursor + 3];
        cursor += 4;
        if (cursor + block_len > bytes.len) break;

        const block = bytes[cursor .. cursor + block_len];
        if (block_type == 0 and block_len >= 18) {
            const sample_rate = (@as(u32, block[10]) << 12) | (@as(u32, block[11]) << 4) | (@as(u32, block[12]) >> 4);
            const total_samples = (@as(u64, block[13] & 0x0f) << 32) |
                (@as(u64, block[14]) << 24) |
                (@as(u64, block[15]) << 16) |
                (@as(u64, block[16]) << 8) |
                @as(u64, block[17]);
            if (sample_rate > 0 and total_samples > 0) {
                meta.duration_ms = @as(u32, @intCast((total_samples * 1000) / sample_rate));
            }
        } else if (block_type == 4) {
            try parseVorbisComments(allocator, block, meta);
        }

        cursor += block_len;
    }
}

fn parseOggCommentPacket(allocator: std.mem.Allocator, packet: []const u8, meta: *Metadata) !void {
    if (packet.len >= 8 and std.mem.eql(u8, packet[0..8], "OpusTags")) {
        try parseVorbisComments(allocator, packet[8..], meta);
        return;
    }
    if (packet.len >= 7 and packet[0] == 0x03 and std.mem.eql(u8, packet[1..7], "vorbis")) {
        try parseVorbisComments(allocator, packet[7..], meta);
    }
}

fn parseOggLike(allocator: std.mem.Allocator, path: []const u8, meta: *Metadata) !void {
    const bytes = try readPrefixAlloc(allocator, path, 512 * 1024);
    defer allocator.free(bytes);

    var cursor: usize = 0;
    while (cursor + 27 <= bytes.len) {
        if (!std.mem.eql(u8, bytes[cursor .. cursor + 4], "OggS")) {
            cursor += 1;
            continue;
        }

        const segment_count = bytes[cursor + 26];
        if (cursor + 27 + segment_count > bytes.len) break;

        const lacing = bytes[cursor + 27 .. cursor + 27 + segment_count];
        const payload_offset = cursor + 27 + segment_count;
        var packet_size: usize = 0;

        for (lacing) |segment| {
            packet_size += segment;
            if (segment < 255) {
                if (payload_offset + packet_size <= bytes.len) {
                    try parseOggCommentPacket(allocator, bytes[payload_offset .. payload_offset + packet_size], meta);
                }
                return;
            }
        }

        cursor = payload_offset + packet_size;
    }
}

fn parseWav(allocator: std.mem.Allocator, path: []const u8, meta: *Metadata) !void {
    const bytes = try readPrefixAlloc(allocator, path, 512 * 1024);
    defer allocator.free(bytes);

    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return;

    var byte_rate: ?u32 = null;
    var data_size: ?u32 = null;

    var cursor: usize = 12;
    while (cursor + 8 <= bytes.len) {
        const chunk_id = bytes[cursor .. cursor + 4];
        const chunk_len = parseLe32(bytes[cursor + 4 .. cursor + 8]);
        cursor += 8;
        if (cursor + chunk_len > bytes.len) break;

        const chunk = bytes[cursor .. cursor + chunk_len];
        if (std.mem.eql(u8, chunk_id, "fmt ") and chunk_len >= 8) {
            byte_rate = parseLe32(chunk[4..8]);
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_size = chunk_len;
        } else if (std.mem.eql(u8, chunk_id, "LIST") and chunk_len >= 4 and std.mem.eql(u8, chunk[0..4], "INFO")) {
            var info_cursor: usize = 4;
            while (info_cursor + 8 <= chunk.len) {
                const info_id = chunk[info_cursor .. info_cursor + 4];
                const info_len = parseLe32(chunk[info_cursor + 4 .. info_cursor + 8]);
                info_cursor += 8;
                if (info_cursor + info_len > chunk.len) break;

                const value = std.mem.trim(u8, chunk[info_cursor .. info_cursor + info_len], "\x00 ");
                if (std.mem.eql(u8, info_id, "INAM")) {
                    try setOwnedString(allocator, &meta.title, value);
                } else if (std.mem.eql(u8, info_id, "IART")) {
                    try setOwnedString(allocator, &meta.artist, value);
                } else if (std.mem.eql(u8, info_id, "IPRD")) {
                    try setOwnedString(allocator, &meta.album, value);
                } else if (std.mem.eql(u8, info_id, "ITRK")) {
                    meta.track_number = std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t\r\n"), 10) catch meta.track_number;
                }

                info_cursor += info_len + (info_len % 2);
            }
        }

        cursor += chunk_len + (chunk_len % 2);
    }

    if (byte_rate != null and data_size != null and byte_rate.? > 0) {
        meta.duration_ms = @as(u32, @intCast((@as(u64, data_size.?) * 1000) / byte_rate.?));
    }
}
