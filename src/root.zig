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

const CodeTokenKind = enum {
    normal,
    keyword,
    command,
    option,
    string,
    number,
    comment,
};

const CodeToken = struct {
    text: []const u8,
    kind: CodeTokenKind,
};

const ListKind = enum {
    unordered,
    ordered,
};

const ListItemInfo = struct {
    kind: ListKind,
    level: usize,
    marker: []const u8,
    content_start: usize,
};

const BlockquoteInfo = struct {
    level: usize,
    content_start: usize,
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
    var code_lang: ?[]const u8 = null;

    var in_indented_code_block = false;
    var indented_code_block: std.ArrayList(u8) = .empty;
    defer indented_code_block.deinit(allocator);

    var active_list_level: ?usize = null;
    var active_list_text_x: i32 = 0;
    var active_list_max: usize = 0;
    var in_list_block = false;
    var list_loose = false;
    var pending_list_blank = false;

    var it = std.mem.splitScalar(u8, markdown, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        if (in_indented_code_block) {
            const indent_cols = leadingIndentColumns(line);
            if (trimmed.len == 0) {
                try indented_code_block.append(allocator, '\n');
                continue;
            }
            if (indent_cols >= 4) {
                const content_start = skipIndentColumns(line, 4);
                try indented_code_block.appendSlice(allocator, line[content_start..]);
                try indented_code_block.append(allocator, '\n');
                continue;
            }

            try drawCodeBlock(
                allocator,
                &page_streams,
                &current_page,
                &has_page,
                &cursor_y,
                indented_code_block.items,
                null,
                margin_left,
                margin_top,
                margin_bottom,
                page_height,
            );
            try indented_code_block.resize(allocator, 0);
            in_indented_code_block = false;
        }

        if (in_code_block) {
            if (std.mem.startsWith(u8, trimmed, "```")) {
                try drawCodeBlock(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    code_block.items,
                    code_lang,
                    margin_left,
                    margin_top,
                    margin_bottom,
                    page_height,
                );
                try code_block.resize(allocator, 0);
                in_code_block = false;
                code_lang = null;
            } else {
                try code_block.appendSlice(allocator, line);
                try code_block.append(allocator, '\n');
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "```")) {
            active_list_level = null;
            in_list_block = false;
            list_loose = false;
            pending_list_blank = false;
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
            code_lang = parseFenceLanguage(trimmed);
            continue;
        }

        if (trimmed.len > 0 and leadingIndentColumns(line) >= 4 and paragraph.items.len == 0 and
            parseListItem(line) == null and parseBlockquoteLine(line) == null)
        {
            active_list_level = null;
            in_list_block = false;
            list_loose = false;
            pending_list_blank = false;
            in_indented_code_block = true;

            const content_start = skipIndentColumns(line, 4);
            try indented_code_block.appendSlice(allocator, line[content_start..]);
            try indented_code_block.append(allocator, '\n');
            continue;
        }

        if (trimmed.len == 0) {
            if (in_list_block) {
                pending_list_blank = true;
                active_list_level = null;
            } else {
                active_list_level = null;
                list_loose = false;
                pending_list_blank = false;
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
                try paragraph.resize(allocator, 0);
                cursor_y -= 4;
            }
            continue;
        }

        if (!in_list_block and paragraph.items.len > 0) {
            if (parseSetextUnderline(trimmed)) |setext_level| {
                const heading_size: i32 = switch (setext_level) {
                    1 => 24,
                    else => 18,
                };
                const heading_max: usize = switch (heading_size) {
                    24 => 40,
                    else => 55,
                };
                const heading_line: i32 = heading_size + 6;

                try drawWrapped(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    paragraph.items,
                    margin_left,
                    heading_size,
                    heading_line,
                    heading_max,
                    margin_top,
                    margin_bottom,
                    page_height,
                );
                try paragraph.resize(allocator, 0);
                cursor_y -= 6;
                continue;
            }
        }

        if (isThematicBreak(trimmed)) {
            active_list_level = null;
            in_list_block = false;
            list_loose = false;
            pending_list_blank = false;
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

        if (parseBlockquoteLine(line)) |quote| {
            active_list_level = null;
            in_list_block = false;
            list_loose = false;
            pending_list_blank = false;

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

            const content = std.mem.trimLeft(u8, line[quote.content_start..], " \t");
            const level_i32: i32 = @intCast(quote.level);
            const quote_x = margin_left + 14 + level_i32 * 18;
            const shrink = quote.level * 7;
            const quote_max: usize = if (80 > shrink + 2) 80 - shrink else 24;
            const quote_start_y = cursor_y;

            if (content.len == 0) {
                cursor_y -= 8;
                continue;
            }

            try drawWrapped(
                allocator,
                &page_streams,
                &current_page,
                &has_page,
                &cursor_y,
                content,
                quote_x,
                12,
                16,
                quote_max,
                margin_top,
                margin_bottom,
                page_height,
            );

            const bar_x = quote_x - 10;
            try drawVerticalRule(allocator, &current_page, bar_x, quote_start_y + 2, cursor_y + 2);
            continue;
        }

        if (parseListItem(line)) |item| {
            if (!in_list_block) {
                in_list_block = true;
                list_loose = false;
            }

            if (pending_list_blank) {
                list_loose = true;
                cursor_y -= 4;
                pending_list_blank = false;
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
                try paragraph.resize(allocator, 0);
                cursor_y -= 4;
            }

            const body = std.mem.trimLeft(u8, line[item.content_start..], " \t");
            const list_text = try std.fmt.allocPrint(allocator, "{s} {s}", .{ item.marker, body });
            const level_i32: i32 = @intCast(item.level);
            const item_x = margin_left + level_i32 * 24;
            const shrink = item.level * 8;
            const item_max: usize = if (80 > shrink + 2) 80 - shrink else 24;

            try drawWrapped(
                allocator,
                &page_streams,
                &current_page,
                &has_page,
                &cursor_y,
                list_text,
                item_x,
                12,
                16,
                item_max,
                margin_top,
                margin_bottom,
                page_height,
            );

            active_list_level = item.level;
            active_list_text_x = item_x + 20;
            active_list_max = if (item_max > 4) item_max - 4 else item_max;
            if (list_loose) cursor_y -= 2;
            continue;
        }

        if (active_list_level) |level| {
            if (isListContinuation(line, level)) {
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

                const continuation = std.mem.trimLeft(u8, line, " \t");
                try drawWrapped(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    continuation,
                    active_list_text_x,
                    12,
                    16,
                    active_list_max,
                    margin_top,
                    margin_bottom,
                    page_height,
                );
                continue;
            }
        }

        active_list_level = null;
        in_list_block = false;
        list_loose = false;
        pending_list_blank = false;

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
            code_lang,
            margin_left,
            margin_top,
            margin_bottom,
            page_height,
        );
    }

    if (in_indented_code_block and indented_code_block.items.len > 0) {
        try drawCodeBlock(
            allocator,
            &page_streams,
            &current_page,
            &has_page,
            &cursor_y,
            indented_code_block.items,
            null,
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
    language: ?[]const u8,
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
            try drawCodeLineWithHighlight(allocator, current_page, line[0..max_chars], language, x, cursor_y.*, font_size);
            cursor_y.* -= line_height;
            line = line[max_chars..];
        }

        try ensureSpace(allocator, page_streams, current_page, has_page, cursor_y, line_height, margin_top, margin_bottom, page_height);
        try drawCodeLineWithHighlight(allocator, current_page, line, language, x, cursor_y.*, font_size);
        cursor_y.* -= line_height;
    }
    cursor_y.* -= 6;
}

fn drawCodeLineWithHighlight(
    allocator: std.mem.Allocator,
    page_stream: *std.ArrayList(u8),
    line: []const u8,
    language: ?[]const u8,
    x: i32,
    y: i32,
    font_size: i32,
) !void {
    var tokens = try tokenizeCodeLine(allocator, line, language);
    defer tokens.deinit(allocator);

    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator, "BT /F5 {d} Tf 1 0 0 1 {d} {d} Tm\n", .{ font_size, x, y });
    try command.appendSlice(allocator, header);

    var current_kind: ?CodeTokenKind = null;
    for (tokens.items) |token| {
        if (current_kind == null or current_kind.? != token.kind) {
            try command.appendSlice(allocator, colorCommandForCodeToken(token.kind));
            current_kind = token.kind;
        }
        const escaped = try escapePdfText(allocator, token.text);
        const text_cmd = try std.fmt.allocPrint(allocator, "({s}) Tj\n", .{escaped});
        try command.appendSlice(allocator, text_cmd);
    }

    try command.appendSlice(allocator, "ET\n");
    try page_stream.appendSlice(allocator, command.items);
}

fn colorCommandForCodeToken(kind: CodeTokenKind) []const u8 {
    return switch (kind) {
        .normal => "0 0 0 rg\n",
        .keyword => "0.09 0.21 0.58 rg\n",
        .command => "0.42 0.08 0.50 rg\n",
        .option => "0.55 0.32 0.03 rg\n",
        .string => "0.62 0.16 0.15 rg\n",
        .number => "0.10 0.45 0.48 rg\n",
        .comment => "0.20 0.43 0.17 rg\n",
    };
}

fn parseFenceLanguage(trimmed_line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, trimmed_line, "```")) return null;
    const rest = std.mem.trimLeft(u8, trimmed_line[3..], " \t");
    if (rest.len == 0) return null;

    var end = rest.len;
    for (rest, 0..) |c, i| {
        if (c == ' ' or c == '\t') {
            end = i;
            break;
        }
    }
    if (end == 0) return null;
    return rest[0..end];
}

fn parseListItem(line: []const u8) ?ListItemInfo {
    var i: usize = 0;
    var indent_cols: usize = 0;
    while (i < line.len) {
        if (line[i] == ' ') {
            indent_cols += 1;
            i += 1;
            continue;
        }
        if (line[i] == '\t') {
            indent_cols += 4;
            i += 1;
            continue;
        }
        break;
    }

    if (i >= line.len) return null;
    const level = indent_cols / 2;

    if (line[i] == '-' or line[i] == '*' or line[i] == '+') {
        if (i + 1 < line.len and (line[i + 1] == ' ' or line[i + 1] == '\t')) {
            return .{
                .kind = .unordered,
                .level = level,
                .marker = line[i .. i + 1],
                .content_start = i + 2,
            };
        }
        return null;
    }

    if (!std.ascii.isDigit(line[i])) return null;
    const start = i;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i >= line.len) return null;
    if (line[i] != '.' and line[i] != ')') return null;
    const punct = i;
    if (punct + 1 >= line.len) return null;
    if (line[punct + 1] != ' ' and line[punct + 1] != '\t') return null;

    return .{
        .kind = .ordered,
        .level = level,
        .marker = line[start .. punct + 1],
        .content_start = punct + 2,
    };
}

fn parseBlockquoteLine(line: []const u8) ?BlockquoteInfo {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len or line[i] != '>') return null;

    var level: usize = 0;
    while (i < line.len and line[i] == '>') {
        level += 1;
        i += 1;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    }

    return .{ .level = level, .content_start = i };
}

fn parseSetextUnderline(trimmed_line: []const u8) ?u8 {
    if (trimmed_line.len == 0) return null;

    var marker: ?u8 = null;
    var count: usize = 0;
    for (trimmed_line) |c| {
        if (c == ' ' or c == '\t') continue;
        if (c != '=' and c != '-') return null;
        if (marker == null) marker = c;
        if (marker.? != c) return null;
        count += 1;
    }

    if (count == 0) return null;
    return if (marker.? == '=') 1 else 2;
}

fn isListContinuation(line: []const u8, active_level: usize) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.startsWith(u8, trimmed, "```")) return false;
    if (parseListItem(line) != null) return false;

    const indent_cols = leadingIndentColumns(line);
    return indent_cols >= (active_level + 1) * 2;
}

fn leadingIndentColumns(line: []const u8) usize {
    var i: usize = 0;
    var cols: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == ' ') {
            cols += 1;
            continue;
        }
        if (line[i] == '\t') {
            cols += 4;
            continue;
        }
        break;
    }
    return cols;
}

fn skipIndentColumns(line: []const u8, want_cols: usize) usize {
    var i: usize = 0;
    var cols: usize = 0;
    while (i < line.len and cols < want_cols) : (i += 1) {
        if (line[i] == ' ') {
            cols += 1;
            continue;
        }
        if (line[i] == '\t') {
            cols += 4;
            continue;
        }
        break;
    }
    return i;
}

fn tokenizeCodeLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    language: ?[]const u8,
) !std.ArrayList(CodeToken) {
    if (language) |lang| {
        if (std.ascii.eqlIgnoreCase(lang, "zig")) return tokenizeZigCodeLine(allocator, line);
        if (std.ascii.eqlIgnoreCase(lang, "json")) return tokenizeJsonCodeLine(allocator, line);
        if (std.ascii.eqlIgnoreCase(lang, "bash") or std.ascii.eqlIgnoreCase(lang, "sh")) {
            return tokenizeBashCodeLine(allocator, line);
        }
    }

    var out: std.ArrayList(CodeToken) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, .{ .text = line, .kind = .normal });
    return out;
}

fn tokenizeZigCodeLine(allocator: std.mem.Allocator, line: []const u8) !std.ArrayList(CodeToken) {
    var out: std.ArrayList(CodeToken) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < line.len) {
        if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
            try out.append(allocator, .{ .text = line[i..], .kind = .comment });
            break;
        }

        if (line[i] == '"') {
            var j = i + 1;
            while (j < line.len) : (j += 1) {
                if (line[j] == '\\' and j + 1 < line.len) {
                    j += 1;
                    continue;
                }
                if (line[j] == '"') {
                    j += 1;
                    break;
                }
            }
            try out.append(allocator, .{ .text = line[i..@min(j, line.len)], .kind = .string });
            i = @min(j, line.len);
            continue;
        }

        if (std.ascii.isDigit(line[i])) {
            var j = i + 1;
            while (j < line.len and isCodeNumberChar(line[j])) : (j += 1) {}
            try out.append(allocator, .{ .text = line[i..j], .kind = .number });
            i = j;
            continue;
        }

        if (isIdentStart(line[i])) {
            var j = i + 1;
            while (j < line.len and isIdentContinue(line[j])) : (j += 1) {}
            const ident = line[i..j];
            try out.append(allocator, .{ .text = ident, .kind = if (isZigKeyword(ident)) .keyword else .normal });
            i = j;
            continue;
        }

        var j = i + 1;
        while (j < line.len and !isTokenBoundary(line, j)) : (j += 1) {}
        try out.append(allocator, .{ .text = line[i..j], .kind = .normal });
        i = j;
    }

    return out;
}

fn tokenizeJsonCodeLine(allocator: std.mem.Allocator, line: []const u8) !std.ArrayList(CodeToken) {
    var out: std.ArrayList(CodeToken) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < line.len) {
        if (std.ascii.isWhitespace(line[i])) {
            const start = i;
            i += 1;
            while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
            try out.append(allocator, .{ .text = line[start..i], .kind = .normal });
            continue;
        }

        if (line[i] == '"') {
            const start = i;
            i += 1;
            while (i < line.len) : (i += 1) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 1;
                    continue;
                }
                if (line[i] == '"') {
                    i += 1;
                    break;
                }
            }

            var k = i;
            while (k < line.len and std.ascii.isWhitespace(line[k])) : (k += 1) {}
            const kind: CodeTokenKind = if (k < line.len and line[k] == ':') .keyword else .string;
            try out.append(allocator, .{ .text = line[start..@min(i, line.len)], .kind = kind });
            continue;
        }

        if (line[i] == '-' or std.ascii.isDigit(line[i])) {
            const start = i;
            i += 1;
            while (i < line.len and isJsonNumberChar(line[i])) : (i += 1) {}
            try out.append(allocator, .{ .text = line[start..i], .kind = .number });
            continue;
        }

        if (std.ascii.isAlphabetic(line[i])) {
            const start = i;
            i += 1;
            while (i < line.len and std.ascii.isAlphabetic(line[i])) : (i += 1) {}
            const word = line[start..i];
            try out.append(allocator, .{ .text = word, .kind = if (isJsonKeyword(word)) .keyword else .normal });
            continue;
        }

        try out.append(allocator, .{ .text = line[i .. i + 1], .kind = .normal });
        i += 1;
    }

    return out;
}

fn tokenizeBashCodeLine(allocator: std.mem.Allocator, line: []const u8) !std.ArrayList(CodeToken) {
    var out: std.ArrayList(CodeToken) = .empty;
    errdefer out.deinit(allocator);

    var expecting_command = true;
    var i: usize = 0;
    while (i < line.len) {
        if (std.ascii.isWhitespace(line[i])) {
            const start_ws = i;
            i += 1;
            while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
            try out.append(allocator, .{ .text = line[start_ws..i], .kind = .normal });
            continue;
        }

        if (line[i] == '#' and (i == 0 or std.ascii.isWhitespace(line[i - 1]))) {
            try out.append(allocator, .{ .text = line[i..], .kind = .comment });
            break;
        }

        if (isBashCommandSeparator(line, i)) |sep_len| {
            try out.append(allocator, .{ .text = line[i .. i + sep_len], .kind = .normal });
            i += sep_len;
            expecting_command = true;
            continue;
        }

        if (line[i] == '`') {
            const start = i;
            i += 1;
            while (i < line.len) : (i += 1) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 1;
                    continue;
                }
                if (line[i] == '`') {
                    i += 1;
                    break;
                }
            }
            try out.append(allocator, .{ .text = line[start..@min(i, line.len)], .kind = .keyword });
            expecting_command = false;
            continue;
        }

        if (line[i] == '"' or line[i] == '\'') {
            const quote = line[i];
            const start = i;
            i += 1;
            while (i < line.len) : (i += 1) {
                if (quote == '"' and line[i] == '\\' and i + 1 < line.len) {
                    i += 1;
                    continue;
                }
                if (line[i] == quote) {
                    i += 1;
                    break;
                }
            }
            try out.append(allocator, .{ .text = line[start..@min(i, line.len)], .kind = .string });
            expecting_command = false;
            continue;
        }

        if (line[i] == '$') {
            const start = i;
            if (i + 1 < line.len and line[i + 1] == '(') {
                i = parseDollarParenSubstitutionEnd(line, i);
            } else {
                i += 1;
                if (i < line.len and line[i] == '{') {
                    i += 1;
                    while (i < line.len and line[i] != '}') : (i += 1) {}
                    if (i < line.len) i += 1;
                } else {
                    while (i < line.len and isBashIdentContinue(line[i])) : (i += 1) {}
                }
            }
            try out.append(allocator, .{ .text = line[start..@max(start + 1, i)], .kind = .keyword });
            expecting_command = false;
            continue;
        }

        if (line[i] == '-' and isBashOptionStart(line, i)) {
            const start = i;
            i += 1;
            while (i < line.len and isBashOptionChar(line[i])) : (i += 1) {}
            try out.append(allocator, .{ .text = line[start..i], .kind = .option });
            expecting_command = false;
            continue;
        }

        if (std.ascii.isDigit(line[i])) {
            const start = i;
            i += 1;
            while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '.')) : (i += 1) {}
            try out.append(allocator, .{ .text = line[start..i], .kind = .number });
            expecting_command = false;
            continue;
        }

        if (isBashIdentStart(line[i])) {
            const start = i;
            i += 1;
            while (i < line.len and isBashIdentContinue(line[i])) : (i += 1) {}
            const word = line[start..i];

            const kind: CodeTokenKind = kind: {
                if (isBashKeyword(word)) break :kind .keyword;
                if (expecting_command and isCommonBashCommand(word)) break :kind .command;
                break :kind .normal;
            };
            try out.append(allocator, .{ .text = word, .kind = kind });
            if (kind == .keyword and bashKeywordStartsCommand(word)) {
                expecting_command = true;
            } else if (!isEnvAssignment(word)) {
                expecting_command = false;
            }
            continue;
        }

        const start = i;
        i += 1;
        while (i < line.len and !isBashTokenBoundary(line, i)) : (i += 1) {}
        try out.append(allocator, .{ .text = line[start..i], .kind = .normal });
        expecting_command = false;
    }

    return out;
}

fn isBashCommandSeparator(line: []const u8, i: usize) ?usize {
    if (line[i] == '|') {
        if (i + 1 < line.len and line[i + 1] == '|') return 2;
        return 1;
    }
    if (line[i] == ';') return 1;
    if (line[i] == '&' and i + 1 < line.len and line[i + 1] == '&') return 2;
    return null;
}

fn isEnvAssignment(word: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (eq == 0) return false;
    var i: usize = 0;
    while (i < eq) : (i += 1) {
        const c = word[i];
        if (i == 0) {
            if (!isBashIdentStart(c)) return false;
        } else if (!isBashIdentContinue(c)) {
            return false;
        }
    }
    return true;
}

fn parseDollarParenSubstitutionEnd(line: []const u8, start_idx: usize) usize {
    var i = start_idx + 2;
    var depth: usize = 1;

    while (i < line.len) : (i += 1) {
        if (line[i] == '\\' and i + 1 < line.len) {
            i += 1;
            continue;
        }

        if (line[i] == '\'') {
            i += 1;
            while (i < line.len and line[i] != '\'') : (i += 1) {}
            continue;
        }

        if (line[i] == '"') {
            i += 1;
            while (i < line.len) : (i += 1) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 1;
                    continue;
                }
                if (line[i] == '"') break;
            }
            continue;
        }

        if (line[i] == '$' and i + 1 < line.len and line[i + 1] == '(') {
            depth += 1;
            i += 1;
            continue;
        }

        if (line[i] == ')') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }

    return line.len;
}

fn isCodeNumberChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

fn isJsonNumberChar(c: u8) bool {
    return std.ascii.isDigit(c) or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn isTokenBoundary(line: []const u8, idx: usize) bool {
    const c = line[idx];
    if (std.ascii.isWhitespace(c)) return true;
    if (c == '"') return true;
    if (idx + 1 < line.len and c == '/' and line[idx + 1] == '/') return true;
    if (isIdentStart(c) or std.ascii.isDigit(c)) return true;
    return false;
}

fn isBashIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isBashIdentContinue(c: u8) bool {
    return isBashIdentStart(c) or std.ascii.isDigit(c);
}

fn isBashTokenBoundary(line: []const u8, idx: usize) bool {
    const c = line[idx];
    if (std.ascii.isWhitespace(c)) return true;
    if (c == '"' or c == '\'' or c == '$' or c == '`') return true;
    if (c == '#' and (idx == 0 or std.ascii.isWhitespace(line[idx - 1]))) return true;
    if (isBashIdentStart(c) or std.ascii.isDigit(c)) return true;
    return false;
}

fn isBashOptionStart(line: []const u8, idx: usize) bool {
    if (line[idx] != '-') return false;
    if (idx + 1 >= line.len) return false;
    if (line[idx + 1] == '-' and idx + 2 < line.len) {
        return std.ascii.isAlphabetic(line[idx + 2]);
    }
    return std.ascii.isAlphabetic(line[idx + 1]);
}

fn isBashOptionChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn isJsonKeyword(word: []const u8) bool {
    return std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false") or std.mem.eql(u8, word, "null");
}

fn isZigKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "const",   "var",      "fn",    "pub",      "if",     "else", "while", "for",    "switch",   "return", "try", "catch",
        "defer",   "errdefer", "break", "continue", "struct", "enum", "union", "opaque", "comptime", "inline", "asm", "nosuspend",
        "suspend", "resume",   "await", "true",     "false",  "null", "or",    "and",
    };
    for (keywords) |k| {
        if (std.mem.eql(u8, k, word)) return true;
    }
    return false;
}

fn isBashKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "if",    "then",   "else",   "elif",  "fi",       "for", "while", "do", "done", "in", "case", "esac", "function",
        "local", "export", "return", "break", "continue", "[[",  "]]",
    };
    for (keywords) |k| {
        if (std.mem.eql(u8, k, word)) return true;
    }
    return false;
}

fn isCommonBashCommand(word: []const u8) bool {
    const commands = [_][]const u8{
        "echo", "printf",   "cd",      "pwd",   "ls",     "cat",   "grep",  "sed", "awk", "cut", "sort",  "uniq",  "tr",
        "head", "tail",     "find",    "xargs", "chmod",  "chown", "mkdir", "rm",  "cp",  "mv",  "touch", "which", "command",
        "test", "basename", "dirname", "env",   "export", "read",  "tee",   "wc",
    };
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd, word)) return true;
    }
    return false;
}

fn bashKeywordStartsCommand(word: []const u8) bool {
    return std.mem.eql(u8, word, "if") or
        std.mem.eql(u8, word, "then") or
        std.mem.eql(u8, word, "else") or
        std.mem.eql(u8, word, "elif") or
        std.mem.eql(u8, word, "do");
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

fn drawVerticalRule(
    allocator: std.mem.Allocator,
    page_stream: *std.ArrayList(u8),
    x: i32,
    y_top: i32,
    y_bottom: i32,
) !void {
    const command = try std.fmt.allocPrint(
        allocator,
        "q 1 w {d} {d} m {d} {d} l S Q\n",
        .{ x, y_top, x, y_bottom },
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

test "parse fenced code language" {
    try std.testing.expectEqualStrings("zig", parseFenceLanguage("```zig").?);
    try std.testing.expectEqualStrings("rust", parseFenceLanguage("``` rust").?);
    try std.testing.expect(parseFenceLanguage("```") == null);
}

test "parse unordered list item with nesting" {
    const item = parseListItem("    - child item").?;
    try std.testing.expect(item.kind == .unordered);
    try std.testing.expectEqual(@as(usize, 2), item.level);
    try std.testing.expectEqualStrings("-", item.marker);
    try std.testing.expectEqualStrings("child item", std.mem.trimLeft(u8, "    - child item"[item.content_start..], " \t"));
}

test "parse ordered list item" {
    const item = parseListItem("  12. step").?;
    try std.testing.expect(item.kind == .ordered);
    try std.testing.expectEqual(@as(usize, 1), item.level);
    try std.testing.expectEqualStrings("12.", item.marker);
    try std.testing.expectEqualStrings("step", std.mem.trimLeft(u8, "  12. step"[item.content_start..], " \t"));
}

test "non list lines are ignored" {
    try std.testing.expect(parseListItem("abc- not list") == null);
    try std.testing.expect(parseListItem("-not list") == null);
    try std.testing.expect(parseListItem("1.not list") == null);
}

test "list continuation detection" {
    try std.testing.expect(isListContinuation("    continuation text", 1));
    try std.testing.expect(!isListContinuation("  too shallow", 1));
    try std.testing.expect(!isListContinuation("    - nested list", 1));
}

test "skip indent columns" {
    try std.testing.expectEqual(@as(usize, 4), skipIndentColumns("    code", 4));
    try std.testing.expectEqual(@as(usize, 1), skipIndentColumns("\tcode", 4));
    try std.testing.expectEqual(@as(usize, 3), skipIndentColumns("  \tcode", 4));
}

test "parse blockquote line" {
    const one = parseBlockquoteLine("> quote").?;
    try std.testing.expectEqual(@as(usize, 1), one.level);
    try std.testing.expectEqualStrings("quote", std.mem.trimLeft(u8, "> quote"[one.content_start..], " \t"));

    const nested = parseBlockquoteLine("  >> nested quote").?;
    try std.testing.expectEqual(@as(usize, 2), nested.level);
    try std.testing.expectEqualStrings("nested quote", std.mem.trimLeft(u8, "  >> nested quote"[nested.content_start..], " \t"));

    try std.testing.expect(parseBlockquoteLine("not quote") == null);
}

test "parse setext underline" {
    try std.testing.expectEqual(@as(?u8, 1), parseSetextUnderline("====="));
    try std.testing.expectEqual(@as(?u8, 2), parseSetextUnderline("---"));
    try std.testing.expectEqual(@as(?u8, 2), parseSetextUnderline(" - - - "));
    try std.testing.expect(parseSetextUnderline("--=") == null);
    try std.testing.expect(parseSetextUnderline("text") == null);
}

test "zig code tokenization applies highlight kinds" {
    const allocator = std.testing.allocator;
    var tokens = try tokenizeCodeLine(allocator, "const n = 42 // note", "zig");
    defer tokens.deinit(allocator);

    try std.testing.expect(tokens.items.len >= 5);
    try std.testing.expectEqualStrings("const", tokens.items[0].text);
    try std.testing.expect(tokens.items[0].kind == .keyword);

    var found_number = false;
    var found_comment = false;
    for (tokens.items) |tok| {
        if (std.mem.eql(u8, tok.text, "42") and tok.kind == .number) found_number = true;
        if (std.mem.eql(u8, tok.text, "// note") and tok.kind == .comment) found_comment = true;
    }
    try std.testing.expect(found_number);
    try std.testing.expect(found_comment);
}

test "json code tokenization applies highlight kinds" {
    const allocator = std.testing.allocator;
    var tokens = try tokenizeCodeLine(allocator, "{\"name\":\"zig\",\"n\":42,\"ok\":true}", "json");
    defer tokens.deinit(allocator);

    var found_key = false;
    var found_string = false;
    var found_number = false;
    var found_keyword = false;
    for (tokens.items) |tok| {
        if (std.mem.eql(u8, tok.text, "\"name\"") and tok.kind == .keyword) found_key = true;
        if (std.mem.eql(u8, tok.text, "\"zig\"") and tok.kind == .string) found_string = true;
        if (std.mem.eql(u8, tok.text, "42") and tok.kind == .number) found_number = true;
        if (std.mem.eql(u8, tok.text, "true") and tok.kind == .keyword) found_keyword = true;
    }
    try std.testing.expect(found_key);
    try std.testing.expect(found_string);
    try std.testing.expect(found_number);
    try std.testing.expect(found_keyword);
}

test "bash code tokenization applies highlight kinds" {
    const allocator = std.testing.allocator;
    var tokens = try tokenizeCodeLine(allocator, "if [ \"$n\" -gt 2 ]; then echo \"ok\" | grep ok # done", "bash");
    defer tokens.deinit(allocator);

    var found_if = false;
    var found_echo = false;
    var found_grep = false;
    var found_number = false;
    var found_string = false;
    var found_comment = false;
    for (tokens.items) |tok| {
        if (std.mem.eql(u8, tok.text, "if") and tok.kind == .keyword) found_if = true;
        if (std.mem.eql(u8, tok.text, "echo") and tok.kind == .command) found_echo = true;
        if (std.mem.eql(u8, tok.text, "grep") and tok.kind == .command) found_grep = true;
        if (std.mem.eql(u8, tok.text, "2") and tok.kind == .number) found_number = true;
        if (std.mem.eql(u8, tok.text, "\"$n\"") and tok.kind == .string) found_string = true;
        if (std.mem.eql(u8, tok.text, "# done") and tok.kind == .comment) found_comment = true;
    }
    try std.testing.expect(found_if);
    try std.testing.expect(found_echo);
    try std.testing.expect(found_grep);
    try std.testing.expect(found_number);
    try std.testing.expect(found_string);
    try std.testing.expect(found_comment);
}

test "bash command substitutions are highlighted" {
    const allocator = std.testing.allocator;
    var tokens = try tokenizeCodeLine(allocator, "echo $(date +%s) and ${USER}", "bash");
    defer tokens.deinit(allocator);

    var found_echo = false;
    var found_subst = false;
    var found_braced = false;
    for (tokens.items) |tok| {
        if (std.mem.eql(u8, tok.text, "echo") and tok.kind == .command) found_echo = true;
        if (std.mem.eql(u8, tok.text, "$(date +%s)") and tok.kind == .keyword) found_subst = true;
        if (std.mem.eql(u8, tok.text, "${USER}") and tok.kind == .keyword) found_braced = true;
    }
    try std.testing.expect(found_echo);
    try std.testing.expect(found_subst);
    try std.testing.expect(found_braced);
}

test "bash backticks are highlighted" {
    const allocator = std.testing.allocator;
    var tokens = try tokenizeCodeLine(allocator, "echo `uname -s`", "bash");
    defer tokens.deinit(allocator);

    var found_echo = false;
    var found_tick = false;
    for (tokens.items) |tok| {
        if (std.mem.eql(u8, tok.text, "echo") and tok.kind == .command) found_echo = true;
        if (std.mem.eql(u8, tok.text, "`uname -s`") and tok.kind == .keyword) found_tick = true;
    }
    try std.testing.expect(found_echo);
    try std.testing.expect(found_tick);
}

test "bash options are highlighted" {
    const allocator = std.testing.allocator;
    var tokens = try tokenizeCodeLine(allocator, "grep -n --color=always foo", "bash");
    defer tokens.deinit(allocator);

    var found_cmd = false;
    var found_short = false;
    var found_long = false;
    for (tokens.items) |tok| {
        if (std.mem.eql(u8, tok.text, "grep") and tok.kind == .command) found_cmd = true;
        if (std.mem.eql(u8, tok.text, "-n") and tok.kind == .option) found_short = true;
        if (std.mem.eql(u8, tok.text, "--color") and tok.kind == .option) found_long = true;
    }

    try std.testing.expect(found_cmd);
    try std.testing.expect(found_short);
    try std.testing.expect(found_long);
}
