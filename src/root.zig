const std = @import("std");

pub const ConvertError = error{
    InputReadFailed,
    OutputWriteFailed,
};

const TextStyle = enum {
    regular,
    bold,
    italic,
    bold_italic,
    mono,
};

const StyledWord = struct {
    text: []u8,
    style: TextStyle,
};

pub fn defaultOutputPath(allocator: std.mem.Allocator, input_path: []const u8) ![]u8 {
    const slash_idx = std.mem.lastIndexOfScalar(u8, input_path, '/');
    const backslash_idx = std.mem.lastIndexOfScalar(u8, input_path, '\\');
    var sep_idx: ?usize = null;
    if (slash_idx) |s| sep_idx = s;
    if (backslash_idx) |b| {
        if (sep_idx) |s| {
            if (b > s) sep_idx = b;
        } else {
            sep_idx = b;
        }
    }
    const basename_start = if (sep_idx) |i| i + 1 else 0;
    const basename = input_path[basename_start..];

    if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot_in_basename| {
        const dot_idx = basename_start + dot_in_basename;
        return std.fmt.allocPrint(allocator, "{s}.pdf", .{input_path[0..dot_idx]});
    }

    return std.fmt.allocPrint(allocator, "{s}.pdf", .{input_path});
}

pub fn convertMarkdownToPdf(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const markdown = std.fs.cwd().readFileAlloc(a, input_path, 8 * 1024 * 1024) catch {
        return ConvertError.InputReadFailed;
    };

    const pdf_bytes = try renderMarkdownAsPdf(a, markdown);
    std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = pdf_bytes }) catch {
        return ConvertError.OutputWriteFailed;
    };
}

fn renderMarkdownAsPdf(allocator: std.mem.Allocator, markdown: []const u8) ![]u8 {
    var page_streams: std.ArrayList([]u8) = .empty;
    defer page_streams.deinit(allocator);

    var current_page: std.ArrayList(u8) = .empty;
    defer current_page.deinit(allocator);

    var has_page = false;
    var cursor_y: i32 = 0;
    const margin_left: i32 = 54;
    const margin_top: i32 = 54;
    const margin_bottom: i32 = 54;
    const page_height: i32 = 792;

    var paragraph: std.ArrayList(u8) = .empty;
    defer paragraph.deinit(allocator);

    var in_code_block = false;
    var code_block: std.ArrayList(u8) = .empty;
    defer code_block.deinit(allocator);

    var it = std.mem.splitScalar(u8, markdown, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        if (in_code_block) {
            if (std.mem.startsWith(u8, trimmed, "```")) {
                try drawCodeBlock(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    code_block.items,
                    margin_left,
                    margin_top,
                    margin_bottom,
                    page_height,
                );
                try code_block.resize(allocator, 0);
                in_code_block = false;
            } else {
                try code_block.appendSlice(allocator, line);
                try code_block.append(allocator, '\n');
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (paragraph.items.len > 0) {
                try drawWrapped(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    paragraph.items,
                    margin_left,
                    12,
                    16,
                    80,
                    margin_top,
                    margin_bottom,
                    page_height,
                );
                try paragraph.resize(allocator, 0);
                cursor_y -= 4;
            }
            in_code_block = true;
            continue;
        }

        if (trimmed.len == 0) {
            if (paragraph.items.len > 0) {
                try drawWrapped(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    paragraph.items,
                    margin_left,
                    12,
                    16,
                    80,
                    margin_top,
                    margin_bottom,
                    page_height,
                );
                try paragraph.resize(allocator, 0);
                cursor_y -= 4;
            }
            continue;
        }

        if (isThematicBreak(trimmed)) {
            if (paragraph.items.len > 0) {
                try drawWrapped(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    paragraph.items,
                    margin_left,
                    12,
                    16,
                    80,
                    margin_top,
                    margin_bottom,
                    page_height,
                );
                try paragraph.resize(allocator, 0);
                cursor_y -= 4;
            }

            try ensureSpace(allocator, &page_streams, &current_page, &has_page, &cursor_y, 16, margin_top, margin_bottom, page_height);
            try drawHorizontalRule(allocator, &current_page, margin_left, 612 - margin_left, cursor_y);
            cursor_y -= 20;
            continue;
        }

        if (trimmed[0] == '#') {
            if (paragraph.items.len > 0) {
                try drawWrapped(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    paragraph.items,
                    margin_left,
                    12,
                    16,
                    80,
                    margin_top,
                    margin_bottom,
                    page_height,
                );
                try paragraph.resize(allocator, 0);
                cursor_y -= 4;
            }

            var level: u8 = 0;
            while (level < trimmed.len and trimmed[level] == '#') : (level += 1) {}
            const heading_text = std.mem.trimLeft(u8, trimmed[@min(level, @as(u8, @intCast(trimmed.len)))..], " ");

            const heading_size: i32 = switch (level) {
                0, 1 => 24,
                2 => 18,
                else => 14,
            };
            const heading_max: usize = switch (heading_size) {
                24 => 40,
                18 => 55,
                else => 70,
            };
            const heading_line: i32 = heading_size + 6;

            try drawWrapped(
                allocator,
                &page_streams,
                &current_page,
                &has_page,
                &cursor_y,
                heading_text,
                margin_left,
                heading_size,
                heading_line,
                heading_max,
                margin_top,
                margin_bottom,
                page_height,
            );
            cursor_y -= 6;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            if (paragraph.items.len > 0) {
                try drawWrapped(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    paragraph.items,
                    margin_left,
                    12,
                    16,
                    80,
                    margin_top,
                    margin_bottom,
                    page_height,
                );
                try paragraph.resize(allocator, 0);
                cursor_y -= 4;
            }

            const bullet_body = std.mem.trimLeft(u8, trimmed[2..], " ");
            const bullet_text = try std.fmt.allocPrint(allocator, "- {s}", .{bullet_body});
            try drawWrapped(
                allocator,
                &page_streams,
                &current_page,
                &has_page,
                &cursor_y,
                bullet_text,
                margin_left,
                12,
                16,
                76,
                margin_top,
                margin_bottom,
                page_height,
            );
            continue;
        }

        if (paragraph.items.len != 0) {
            try paragraph.append(allocator, ' ');
        }
        try paragraph.appendSlice(allocator, trimmed);
    }

    if (in_code_block and code_block.items.len > 0) {
        try drawCodeBlock(
            allocator,
            &page_streams,
            &current_page,
            &has_page,
            &cursor_y,
            code_block.items,
            margin_left,
            margin_top,
            margin_bottom,
            page_height,
        );
    }

    if (paragraph.items.len > 0) {
        try drawWrapped(
            allocator,
            &page_streams,
            &current_page,
            &has_page,
            &cursor_y,
            paragraph.items,
            margin_left,
            12,
            16,
            80,
            margin_top,
            margin_bottom,
            page_height,
        );
    }

    if (!has_page) {
        cursor_y = page_height - margin_top;
        has_page = true;
        try drawTextLine(allocator, &current_page, "(empty document)", margin_left, cursor_y, 12);
    }

    const last_stream = try current_page.toOwnedSlice(allocator);
    try page_streams.append(allocator, last_stream);

    return try buildPdf(allocator, page_streams.items);
}

fn drawWrapped(
    allocator: std.mem.Allocator,
    page_streams: *std.ArrayList([]u8),
    current_page: *std.ArrayList(u8),
    has_page: *bool,
    cursor_y: *i32,
    text: []const u8,
    x: i32,
    font_size: i32,
    line_height: i32,
    max_chars: usize,
    margin_top: i32,
    margin_bottom: i32,
    page_height: i32,
) !void {
    var words = try inlineStyledWords(allocator, text);
    defer deinitStyledWords(allocator, &words);

    var line_words: std.ArrayList(StyledWord) = .empty;
    defer line_words.deinit(allocator);

    var line_chars: usize = 0;

    for (words.items) |word| {
        if (line_words.items.len == 0) {
            try line_words.append(allocator, word);
            line_chars = word.text.len;
            continue;
        }

        if (line_chars + 1 + word.text.len <= max_chars) {
            try line_words.append(allocator, word);
            line_chars += 1 + word.text.len;
            continue;
        }

        try ensureSpace(allocator, page_streams, current_page, has_page, cursor_y, line_height, margin_top, margin_bottom, page_height);
        try drawStyledLine(allocator, current_page, line_words.items, x, cursor_y.*, font_size);
        cursor_y.* -= line_height;
        try line_words.resize(allocator, 0);
        try line_words.append(allocator, word);
        line_chars = word.text.len;
    }

    if (line_words.items.len > 0) {
        try ensureSpace(allocator, page_streams, current_page, has_page, cursor_y, line_height, margin_top, margin_bottom, page_height);
        try drawStyledLine(allocator, current_page, line_words.items, x, cursor_y.*, font_size);
        cursor_y.* -= line_height;
    }
}

fn ensureSpace(
    allocator: std.mem.Allocator,
    page_streams: *std.ArrayList([]u8),
    current_page: *std.ArrayList(u8),
    has_page: *bool,
    cursor_y: *i32,
    line_height: i32,
    margin_top: i32,
    margin_bottom: i32,
    page_height: i32,
) !void {
    if (!has_page.*) {
        has_page.* = true;
        cursor_y.* = page_height - margin_top;
        return;
    }

    if (cursor_y.* - line_height < margin_bottom) {
        const done = try current_page.toOwnedSlice(allocator);
        try page_streams.append(allocator, done);
        current_page.* = .empty;
        cursor_y.* = page_height - margin_top;
    }
}

fn drawTextLine(
    allocator: std.mem.Allocator,
    page_stream: *std.ArrayList(u8),
    text: []const u8,
    x: i32,
    y: i32,
    font_size: i32,
) !void {
    return drawTextLineWithStyle(allocator, page_stream, text, x, y, font_size, .regular);
}

fn drawTextLineWithStyle(
    allocator: std.mem.Allocator,
    page_stream: *std.ArrayList(u8),
    text: []const u8,
    x: i32,
    y: i32,
    font_size: i32,
    style: TextStyle,
) !void {
    const escaped = try escapePdfText(allocator, text);
    const command = try std.fmt.allocPrint(
        allocator,
        "BT {s} {d} Tf 1 0 0 1 {d} {d} Tm ({s}) Tj ET\n",
        .{ fontNameForStyle(style), font_size, x, y, escaped },
    );
    try page_stream.appendSlice(allocator, command);
}

fn drawCodeBlock(
    allocator: std.mem.Allocator,
    page_streams: *std.ArrayList([]u8),
    current_page: *std.ArrayList(u8),
    has_page: *bool,
    cursor_y: *i32,
    code: []const u8,
    x: i32,
    margin_top: i32,
    margin_bottom: i32,
    page_height: i32,
) !void {
    const font_size: i32 = 11;
    const line_height: i32 = 14;
    const max_chars: usize = 84;

    cursor_y.* -= 2;
    const code_text = std.mem.trimRight(u8, code, "\n");
    var lines = std.mem.splitScalar(u8, code_text, '\n');
    while (lines.next()) |raw_line| {
        var line = raw_line;
        while (line.len > max_chars) {
            try ensureSpace(allocator, page_streams, current_page, has_page, cursor_y, line_height, margin_top, margin_bottom, page_height);
            try drawTextLineWithStyle(allocator, current_page, line[0..max_chars], x, cursor_y.*, font_size, .mono);
            cursor_y.* -= line_height;
            line = line[max_chars..];
        }

        try ensureSpace(allocator, page_streams, current_page, has_page, cursor_y, line_height, margin_top, margin_bottom, page_height);
        try drawTextLineWithStyle(allocator, current_page, line, x, cursor_y.*, font_size, .mono);
        cursor_y.* -= line_height;
    }
    cursor_y.* -= 6;
}

fn drawHorizontalRule(
    allocator: std.mem.Allocator,
    page_stream: *std.ArrayList(u8),
    x1: i32,
    x2: i32,
    y: i32,
) !void {
    const command = try std.fmt.allocPrint(
        allocator,
        "q 1 w {d} {d} m {d} {d} l S Q\n",
        .{ x1, y, x2, y },
    );
    try page_stream.appendSlice(allocator, command);
}

fn isThematicBreak(line: []const u8) bool {
    var marker: ?u8 = null;
    var count: usize = 0;

    for (line) |c| {
        if (c == ' ' or c == '\t') continue;
        if (c != '-' and c != '*' and c != '_') return false;
        if (marker == null) marker = c;
        if (marker.? != c) return false;
        count += 1;
    }

    return count >= 3;
}

fn drawStyledLine(
    allocator: std.mem.Allocator,
    page_stream: *std.ArrayList(u8),
    words: []const StyledWord,
    x: i32,
    y: i32,
    font_size: i32,
) !void {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator, "BT 1 0 0 1 {d} {d} Tm\n", .{ x, y });
    try command.appendSlice(allocator, header);

    var current_style: ?TextStyle = null;
    for (words, 0..) |word, idx| {
        if (idx != 0) {
            if (current_style == null or current_style.? != word.style) {
                const set_font = try std.fmt.allocPrint(
                    allocator,
                    "{s} {d} Tf\n",
                    .{ fontNameForStyle(word.style), font_size },
                );
                try command.appendSlice(allocator, set_font);
                current_style = word.style;
            }
            try command.appendSlice(allocator, "( ) Tj\n");
        }

        if (current_style == null or current_style.? != word.style) {
            const set_font = try std.fmt.allocPrint(
                allocator,
                "{s} {d} Tf\n",
                .{ fontNameForStyle(word.style), font_size },
            );
            try command.appendSlice(allocator, set_font);
            current_style = word.style;
        }

        const escaped = try escapePdfText(allocator, word.text);
        const text_cmd = try std.fmt.allocPrint(allocator, "({s}) Tj\n", .{escaped});
        try command.appendSlice(allocator, text_cmd);
    }

    try command.appendSlice(allocator, "ET\n");
    try page_stream.appendSlice(allocator, command.items);
}

fn fontNameForStyle(style: TextStyle) []const u8 {
    return switch (style) {
        .regular => "/F1",
        .bold => "/F2",
        .italic => "/F3",
        .bold_italic => "/F4",
        .mono => "/F5",
    };
}

fn styleFromFlags(bold: bool, italic: bool) TextStyle {
    if (bold and italic) return .bold_italic;
    if (bold) return .bold;
    if (italic) return .italic;
    return .regular;
}

fn deinitStyledWords(allocator: std.mem.Allocator, words: *std.ArrayList(StyledWord)) void {
    for (words.items) |word| allocator.free(word.text);
    words.deinit(allocator);
}

fn inlineStyledWords(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList(StyledWord) {
    var out: std.ArrayList(StyledWord) = .empty;
    errdefer deinitStyledWords(allocator, &out);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var bold = false;
    var italic = false;
    var in_code = false;

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            if (buffer.items.len > 0) {
                try appendStyledWord(allocator, &out, buffer.items, if (in_code) .mono else styleFromFlags(bold, italic));
                try buffer.resize(allocator, 0);
            }
            in_code = !in_code;
            i += 1;
            continue;
        }

        if (in_code) {
            try buffer.append(allocator, text[i]);
            i += 1;
            continue;
        }

        if (text[i] == '\\' and i + 1 < text.len and (text[i + 1] == '*' or text[i + 1] == '_' or text[i + 1] == '\\' or text[i + 1] == '`')) {
            try buffer.append(allocator, text[i + 1]);
            i += 2;
            continue;
        }

        if ((text[i] == '*' or text[i] == '_') and i + 2 < text.len and text[i + 1] == text[i] and text[i + 2] == text[i] and canToggleMarker(text, i, 3)) {
            if (buffer.items.len > 0) {
                try appendStyledWord(allocator, &out, buffer.items, styleFromFlags(bold, italic));
                try buffer.resize(allocator, 0);
            }
            bold = !bold;
            italic = !italic;
            i += 3;
            continue;
        }

        if ((text[i] == '*' or text[i] == '_') and i + 1 < text.len and text[i + 1] == text[i] and canToggleMarker(text, i, 2)) {
            if (buffer.items.len > 0) {
                try appendStyledWord(allocator, &out, buffer.items, styleFromFlags(bold, italic));
                try buffer.resize(allocator, 0);
            }
            bold = !bold;
            i += 2;
            continue;
        }

        if ((text[i] == '*' or text[i] == '_') and canToggleMarker(text, i, 1)) {
            if (buffer.items.len > 0) {
                try appendStyledWord(allocator, &out, buffer.items, styleFromFlags(bold, italic));
                try buffer.resize(allocator, 0);
            }
            italic = !italic;
            i += 1;
            continue;
        }

        if (std.ascii.isWhitespace(text[i])) {
            if (buffer.items.len > 0) {
                try appendStyledWord(allocator, &out, buffer.items, styleFromFlags(bold, italic));
                try buffer.resize(allocator, 0);
            }
            i += 1;
            while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
            continue;
        }

        try buffer.append(allocator, text[i]);
        i += 1;
    }

    if (buffer.items.len > 0) {
        try appendStyledWord(allocator, &out, buffer.items, if (in_code) .mono else styleFromFlags(bold, italic));
    }

    return out;
}

fn appendStyledWord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(StyledWord),
    text: []const u8,
    style: TextStyle,
) !void {
    const copy = try allocator.alloc(u8, text.len);
    @memcpy(copy, text);
    try out.append(allocator, .{ .text = copy, .style = style });
}

fn canToggleMarker(text: []const u8, marker_idx: usize, marker_len: usize) bool {
    const marker = text[marker_idx];
    if (marker == '*') return true;
    if (marker != '_') return false;
    return underscoreDelimiterAllowed(text, marker_idx, marker_len);
}

fn underscoreDelimiterAllowed(text: []const u8, marker_idx: usize, marker_len: usize) bool {
    const prev_is_alnum = marker_idx > 0 and std.ascii.isAlphanumeric(text[marker_idx - 1]);
    const next_idx = marker_idx + marker_len;
    const next_is_alnum = next_idx < text.len and std.ascii.isAlphanumeric(text[next_idx]);
    return !(prev_is_alnum and next_is_alnum);
}

fn escapePdfText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (text) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '(' => try out.appendSlice(allocator, "\\("),
            ')' => try out.appendSlice(allocator, "\\)"),
            else => try out.append(allocator, c),
        }
    }

    return out.toOwnedSlice(allocator);
}

fn buildPdf(allocator: std.mem.Allocator, page_streams: []const []const u8) ![]u8 {
    var objects: std.ArrayList([]const u8) = .empty;
    defer objects.deinit(allocator);

    try objects.append(allocator, "");
    try objects.append(allocator, "");
    try objects.append(allocator, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
    try objects.append(allocator, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>");
    try objects.append(allocator, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique >>");
    try objects.append(allocator, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-BoldOblique >>");
    try objects.append(allocator, "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>");

    var content_ids: std.ArrayList(usize) = .empty;
    defer content_ids.deinit(allocator);
    for (page_streams) |stream| {
        const content_obj = try std.fmt.allocPrint(
            allocator,
            "<< /Length {d} >>\nstream\n{s}endstream",
            .{ stream.len, stream },
        );
        try objects.append(allocator, content_obj);
        try content_ids.append(allocator, objects.items.len);
    }

    var page_ids: std.ArrayList(usize) = .empty;
    defer page_ids.deinit(allocator);
    for (content_ids.items) |content_id| {
        const page_obj = try std.fmt.allocPrint(
            allocator,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R /F4 6 0 R /F5 7 0 R >> >> /Contents {d} 0 R >>",
            .{content_id},
        );
        try objects.append(allocator, page_obj);
        try page_ids.append(allocator, objects.items.len);
    }

    var kids: std.ArrayList(u8) = .empty;
    defer kids.deinit(allocator);
    for (page_ids.items) |id| {
        const kid = try std.fmt.allocPrint(allocator, "{d} 0 R ", .{id});
        try kids.appendSlice(allocator, kid);
    }

    objects.items[0] = "<< /Type /Catalog /Pages 2 0 R >>";
    objects.items[1] = try std.fmt.allocPrint(
        allocator,
        "<< /Type /Pages /Count {d} /Kids [{s}] >>",
        .{ page_ids.items.len, kids.items },
    );

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "%PDF-1.4\n");
    try out.appendSlice(allocator, "%\xFF\xFF\xFF\xFF\n");

    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(allocator);

    var i: usize = 0;
    while (i < objects.items.len) : (i += 1) {
        try offsets.append(allocator, out.items.len);
        const obj_line = try std.fmt.allocPrint(allocator, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, objects.items[i] });
        try out.appendSlice(allocator, obj_line);
    }

    const xref_start = out.items.len;
    const xref_header = try std.fmt.allocPrint(allocator, "xref\n0 {d}\n", .{objects.items.len + 1});
    try out.appendSlice(allocator, xref_header);
    try out.appendSlice(allocator, "0000000000 65535 f \n");

    for (offsets.items) |off| {
        try appendXrefOffset(allocator, &out, off);
    }

    const trailer = try std.fmt.allocPrint(
        allocator,
        "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n",
        .{ objects.items.len + 1, xref_start },
    );
    try out.appendSlice(allocator, trailer);

    return out.toOwnedSlice(allocator);
}

fn appendXrefOffset(allocator: std.mem.Allocator, out: *std.ArrayList(u8), offset: usize) !void {
    var digits: [32]u8 = undefined;
    const off_str = try std.fmt.bufPrint(&digits, "{d}", .{offset});

    var zeros: usize = 0;
    if (off_str.len < 10) zeros = 10 - off_str.len;
    var z: usize = 0;
    while (z < zeros) : (z += 1) {
        try out.append(allocator, '0');
    }

    try out.appendSlice(allocator, off_str);
    try out.appendSlice(allocator, " 00000 n \n");
}

test "default output path replaces extension" {
    const allocator = std.testing.allocator;
    const out = try defaultOutputPath(allocator, "notes/today.md");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("notes/today.pdf", out);
}

test "default output path appends extension" {
    const allocator = std.testing.allocator;
    const out = try defaultOutputPath(allocator, "README");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("README.pdf", out);
}

test "pdf escaping" {
    const allocator = std.testing.allocator;
    const escaped = try escapePdfText(allocator, "a(b)\\c");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("a\\(b\\)\\\\c", escaped);
}

test "inline styles parse bold and italic" {
    const allocator = std.testing.allocator;
    var words = try inlineStyledWords(allocator, "plain **bold** *italic* ***both*** end");
    defer deinitStyledWords(allocator, &words);

    try std.testing.expectEqual(@as(usize, 5), words.items.len);
    try std.testing.expectEqualStrings("plain", words.items[0].text);
    try std.testing.expect(words.items[0].style == .regular);
    try std.testing.expectEqualStrings("bold", words.items[1].text);
    try std.testing.expect(words.items[1].style == .bold);
    try std.testing.expectEqualStrings("italic", words.items[2].text);
    try std.testing.expect(words.items[2].style == .italic);
    try std.testing.expectEqualStrings("both", words.items[3].text);
    try std.testing.expect(words.items[3].style == .bold_italic);
    try std.testing.expectEqualStrings("end", words.items[4].text);
    try std.testing.expect(words.items[4].style == .regular);
}

test "inline styles support escaped asterisks" {
    const allocator = std.testing.allocator;
    var words = try inlineStyledWords(allocator, "show \\*literal\\* and **b\\*old** text");
    defer deinitStyledWords(allocator, &words);

    try std.testing.expectEqual(@as(usize, 5), words.items.len);
    try std.testing.expectEqualStrings("show", words.items[0].text);
    try std.testing.expect(words.items[0].style == .regular);
    try std.testing.expectEqualStrings("*literal*", words.items[1].text);
    try std.testing.expect(words.items[1].style == .regular);
    try std.testing.expectEqualStrings("and", words.items[2].text);
    try std.testing.expect(words.items[2].style == .regular);
    try std.testing.expectEqualStrings("b*old", words.items[3].text);
    try std.testing.expect(words.items[3].style == .bold);
    try std.testing.expectEqualStrings("text", words.items[4].text);
    try std.testing.expect(words.items[4].style == .regular);
}

test "inline styles parse underscores" {
    const allocator = std.testing.allocator;
    var words = try inlineStyledWords(allocator, "plain __bold__ _italic_ ___both___ end");
    defer deinitStyledWords(allocator, &words);

    try std.testing.expectEqual(@as(usize, 5), words.items.len);
    try std.testing.expectEqualStrings("plain", words.items[0].text);
    try std.testing.expect(words.items[0].style == .regular);
    try std.testing.expectEqualStrings("bold", words.items[1].text);
    try std.testing.expect(words.items[1].style == .bold);
    try std.testing.expectEqualStrings("italic", words.items[2].text);
    try std.testing.expect(words.items[2].style == .italic);
    try std.testing.expectEqualStrings("both", words.items[3].text);
    try std.testing.expect(words.items[3].style == .bold_italic);
    try std.testing.expectEqualStrings("end", words.items[4].text);
    try std.testing.expect(words.items[4].style == .regular);
}

test "inline styles support escaped underscores" {
    const allocator = std.testing.allocator;
    var words = try inlineStyledWords(allocator, "show \\_literal\\_ and __b\\_old__ text");
    defer deinitStyledWords(allocator, &words);

    try std.testing.expectEqual(@as(usize, 5), words.items.len);
    try std.testing.expectEqualStrings("show", words.items[0].text);
    try std.testing.expect(words.items[0].style == .regular);
    try std.testing.expectEqualStrings("_literal_", words.items[1].text);
    try std.testing.expect(words.items[1].style == .regular);
    try std.testing.expectEqualStrings("and", words.items[2].text);
    try std.testing.expect(words.items[2].style == .regular);
    try std.testing.expectEqualStrings("b_old", words.items[3].text);
    try std.testing.expect(words.items[3].style == .bold);
    try std.testing.expectEqualStrings("text", words.items[4].text);
    try std.testing.expect(words.items[4].style == .regular);
}

test "inline underscore styles do not trigger inside words" {
    const allocator = std.testing.allocator;
    var words = try inlineStyledWords(allocator, "use snake_case and __bold__ with x_y");
    defer deinitStyledWords(allocator, &words);

    try std.testing.expectEqual(@as(usize, 6), words.items.len);
    try std.testing.expectEqualStrings("use", words.items[0].text);
    try std.testing.expect(words.items[0].style == .regular);
    try std.testing.expectEqualStrings("snake_case", words.items[1].text);
    try std.testing.expect(words.items[1].style == .regular);
    try std.testing.expectEqualStrings("and", words.items[2].text);
    try std.testing.expect(words.items[2].style == .regular);
    try std.testing.expectEqualStrings("bold", words.items[3].text);
    try std.testing.expect(words.items[3].style == .bold);
    try std.testing.expectEqualStrings("with", words.items[4].text);
    try std.testing.expect(words.items[4].style == .regular);
    try std.testing.expectEqualStrings("x_y", words.items[5].text);
    try std.testing.expect(words.items[5].style == .regular);
}

test "inline code spans are monospaced and literal" {
    const allocator = std.testing.allocator;
    var words = try inlineStyledWords(allocator, "use `code *raw* _raw_` and **bold**");
    defer deinitStyledWords(allocator, &words);

    try std.testing.expectEqual(@as(usize, 4), words.items.len);
    try std.testing.expectEqualStrings("use", words.items[0].text);
    try std.testing.expect(words.items[0].style == .regular);
    try std.testing.expectEqualStrings("code *raw* _raw_", words.items[1].text);
    try std.testing.expect(words.items[1].style == .mono);
    try std.testing.expectEqualStrings("and", words.items[2].text);
    try std.testing.expect(words.items[2].style == .regular);
    try std.testing.expectEqualStrings("bold", words.items[3].text);
    try std.testing.expect(words.items[3].style == .bold);
}

test "thematic break detection" {
    try std.testing.expect(isThematicBreak("---"));
    try std.testing.expect(isThematicBreak("***"));
    try std.testing.expect(isThematicBreak("___"));
    try std.testing.expect(isThematicBreak("- - -"));
    try std.testing.expect(!isThematicBreak("--"));
    try std.testing.expect(!isThematicBreak("-_ -"));
    try std.testing.expect(!isThematicBreak("text"));
}
