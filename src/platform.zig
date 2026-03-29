const std = @import("std");

pub const c = @cImport({
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cInclude("windows.h");
    @cInclude("commdlg.h");
    @cInclude("shellapi.h");
    @cInclude("gl/GL.h");
    @cInclude("mmsystem.h");
});

pub fn utf8ToWideZ(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

pub fn utf16ToUtf8Alloc(allocator: std.mem.Allocator, text: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(allocator, text);
}

pub fn utf16ZToUtf8Alloc(allocator: std.mem.Allocator, text: [*:0]const u16) ![]u8 {
    return utf16ToUtf8Alloc(allocator, std.mem.sliceTo(text, 0));
}

pub fn buildDialogFilter(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

pub fn xmlEscapeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();

    for (text) |ch| {
        switch (ch) {
            '&' => try list.appendSlice("&amp;"),
            '<' => try list.appendSlice("&lt;"),
            '>' => try list.appendSlice("&gt;"),
            '"' => try list.appendSlice("&quot;"),
            '\'' => try list.appendSlice("&apos;"),
            else => try list.append(ch),
        }
    }

    return list.toOwnedSlice();
}

pub fn xmlUnescapeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            if (std.mem.startsWith(u8, text[i..], "&amp;")) {
                try list.append('&');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, text[i..], "&lt;")) {
                try list.append('<');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, text[i..], "&gt;")) {
                try list.append('>');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, text[i..], "&quot;")) {
                try list.append('"');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, text[i..], "&apos;")) {
                try list.append('\'');
                i += 6;
                continue;
            }
        }

        try list.append(text[i]);
        i += 1;
    }

    return list.toOwnedSlice();
}

fn isUriSafeByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/' or ch == ':';
}

pub fn filePathToUriAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();

    try list.appendSlice("file:///");
    for (path) |ch| {
        const normalized: u8 = if (ch == '\\') '/' else ch;
        if (isUriSafeByte(normalized)) {
            try list.append(normalized);
        } else {
            try list.print("%{X:0>2}", .{normalized});
        }
    }

    return list.toOwnedSlice();
}

fn hexNibble(ch: u8) !u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return 10 + ch - 'a';
    if (ch >= 'A' and ch <= 'F') return 10 + ch - 'A';
    return error.InvalidPercentEncoding;
}

pub fn uriToFilePathAlloc(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    const trimmed = if (std.mem.startsWith(u8, uri, "file:///")) uri[8..] else uri;

    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();

    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == '%' and i + 2 < trimmed.len) {
            const hi = try hexNibble(trimmed[i + 1]);
            const lo = try hexNibble(trimmed[i + 2]);
            try list.append((hi << 4) | lo);
            i += 3;
            continue;
        }

        try list.append(if (trimmed[i] == '/') '\\' else trimmed[i]);
        i += 1;
    }

    return list.toOwnedSlice();
}

pub fn parseMultiSelectBuffer(allocator: std.mem.Allocator, buffer: []const u16) ![][]u8 {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }

    const first_end = std.mem.indexOfScalar(u16, buffer, 0) orelse return error.InvalidDialogBuffer;
    if (first_end == 0) return out.toOwnedSlice();

    if (first_end + 1 >= buffer.len or buffer[first_end + 1] == 0) {
        const full_path = try utf16ToUtf8Alloc(allocator, buffer[0..first_end]);
        try out.append(full_path);
        return out.toOwnedSlice();
    }

    const dir_utf8 = try utf16ToUtf8Alloc(allocator, buffer[0..first_end]);
    defer allocator.free(dir_utf8);

    var scan = first_end + 1;
    while (scan < buffer.len and buffer[scan] != 0) {
        const name_end_rel = std.mem.indexOfScalar(u16, buffer[scan..], 0) orelse break;
        const name_end = scan + name_end_rel;
        const file_name = try utf16ToUtf8Alloc(allocator, buffer[scan..name_end]);
        defer allocator.free(file_name);

        const full_path = try std.fs.path.join(allocator, &.{ dir_utf8, file_name });
        try out.append(full_path);
        scan = name_end + 1;
    }

    return out.toOwnedSlice();
}

pub fn freeStringList(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

pub fn sanitizeDisplayUtf8(input: []const u8, out: []u8) []const u8 {
    const max_len = @min(input.len, out.len);
    var i: usize = 0;
    while (i < max_len) : (i += 1) {
        const ch = input[i];
        out[i] = if (ch >= 32 and ch <= 126) ch else '?';
    }
    return out[0..max_len];
}
