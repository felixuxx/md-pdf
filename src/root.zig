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
    link,
};

const StyledWord = struct {
    text: []u8,
    style: TextStyle,
    link_dest: ?[]u8,
};

const LinkAnnotation = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    url: []const u8,
};

var g_page_link_annots: ?*std.ArrayList([]LinkAnnotation) = null;
var g_current_link_annots: ?*std.ArrayList(LinkAnnotation) = null;

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

const ReferenceDefinition = struct {
    label: []const u8,
    destination: []const u8,
};

const TableAlign = enum {
    left,
    center,
    right,
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
    var page_link_annots: std.ArrayList([]LinkAnnotation) = .empty;
    defer page_link_annots.deinit(allocator);

    var current_page: std.ArrayList(u8) = .empty;
    defer current_page.deinit(allocator);
    var current_link_annots: std.ArrayList(LinkAnnotation) = .empty;
    defer current_link_annots.deinit(allocator);
    g_page_link_annots = &page_link_annots;
    g_current_link_annots = &current_link_annots;
    defer {
        g_page_link_annots = null;
        g_current_link_annots = null;
    }

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

    var pending_table_header: ?[]const u8 = null;
    var in_table_block = false;
    var table_rows: std.ArrayList([]const u8) = .empty;
    defer table_rows.deinit(allocator);
    var table_aligns: std.ArrayList(TableAlign) = .empty;
    defer table_aligns.deinit(allocator);

    var reference_defs: std.StringHashMap([]const u8) = .init(allocator);
    defer reference_defs.deinit();

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

        if (in_table_block) {
            if (trimmed.len > 0 and looksLikeTableRow(line)) {
                try table_rows.append(allocator, line);
                continue;
            }

            try drawTableBlock(
                allocator,
                &page_streams,
                &current_page,
                &has_page,
                &cursor_y,
                table_rows.items,
                table_aligns.items,
                margin_left,
                margin_top,
                margin_bottom,
                page_height,
            );
            try table_rows.resize(allocator, 0);
            try table_aligns.resize(allocator, 0);
            in_table_block = false;
        }

        if (pending_table_header) |header| {
            if (isTableDelimiterLine(trimmed)) {
                try table_rows.append(allocator, header);
                try table_aligns.resize(allocator, 0);
                var header_cells = try splitTableCells(allocator, header);
                defer header_cells.deinit(allocator);
                var aligns = try parseTableAlignments(allocator, trimmed, header_cells.items.len);
                defer aligns.deinit(allocator);
                try table_aligns.appendSlice(allocator, aligns.items);
                in_table_block = true;
                pending_table_header = null;
                continue;
            }

            if (paragraph.items.len != 0) {
                try paragraph.append(allocator, ' ');
            }
            try paragraph.appendSlice(allocator, std.mem.trim(u8, header, " \t"));
            pending_table_header = null;
        }

        if (paragraph.items.len == 0) {
            if (parseReferenceDefinition(line)) |def| {
                const norm_label = try normalizeReferenceLabel(allocator, def.label);
                try reference_defs.put(norm_label, def.destination);
                continue;
            }
        }

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
            pending_table_header = null;
            if (paragraph.items.len > 0) {
                try drawWrappedWithRefs(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    &reference_defs,
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
            pending_table_header = null;
            if (in_list_block) {
                pending_list_blank = true;
                active_list_level = null;
            } else {
                active_list_level = null;
                list_loose = false;
                pending_list_blank = false;
            }
            if (paragraph.items.len > 0) {
                try drawWrappedWithRefs(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    &reference_defs,
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
                pending_table_header = null;
                const heading_size: i32 = switch (setext_level) {
                    1 => 24,
                    else => 18,
                };
                const heading_max: usize = switch (heading_size) {
                    24 => 40,
                    else => 55,
                };
                const heading_line: i32 = heading_size + 6;

                try drawWrappedWithRefs(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    &reference_defs,
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
            pending_table_header = null;
            active_list_level = null;
            in_list_block = false;
            list_loose = false;
            pending_list_blank = false;
            if (paragraph.items.len > 0) {
                try drawWrappedWithRefs(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    &reference_defs,
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
            pending_table_header = null;
            active_list_level = null;
            in_list_block = false;
            list_loose = false;
            pending_list_blank = false;

            if (paragraph.items.len > 0) {
                try drawWrappedWithRefs(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    &reference_defs,
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

            try drawWrappedWithRefs(
                allocator,
                &page_streams,
                &current_page,
                &has_page,
                &cursor_y,
                &reference_defs,
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
            pending_table_header = null;
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
                try drawWrappedWithRefs(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    &reference_defs,
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

            try drawWrappedWithRefs(
                allocator,
                &page_streams,
                &current_page,
                &has_page,
                &cursor_y,
                &reference_defs,
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
                pending_table_header = null;
                if (paragraph.items.len > 0) {
                    try drawWrappedWithRefs(
                        allocator,
                        &page_streams,
                        &current_page,
                        &has_page,
                        &cursor_y,
                        &reference_defs,
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
                try drawWrappedWithRefs(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    &reference_defs,
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
            pending_table_header = null;
            if (paragraph.items.len > 0) {
                try drawWrappedWithRefs(
                    allocator,
                    &page_streams,
                    &current_page,
                    &has_page,
                    &cursor_y,
                    &reference_defs,
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

            try drawWrappedWithRefs(
                allocator,
                &page_streams,
                &current_page,
                &has_page,
                &cursor_y,
                &reference_defs,
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

        if (!in_list_block and paragraph.items.len == 0 and looksLikeTableRow(line)) {
            pending_table_header = line;
            continue;
        }

        if (paragraph.items.len != 0) {
            try paragraph.append(allocator, ' ');
        }
        try paragraph.appendSlice(allocator, trimmed);
    }

    if (pending_table_header) |header| {
        if (paragraph.items.len != 0) {
            try paragraph.append(allocator, ' ');
        }
        try paragraph.appendSlice(allocator, std.mem.trim(u8, header, " \t"));
    }

    if (in_table_block and table_rows.items.len > 0) {
        try drawTableBlock(
            allocator,
            &page_streams,
            &current_page,
            &has_page,
            &cursor_y,
            table_rows.items,
            table_aligns.items,
            margin_left,
            margin_top,
            margin_bottom,
            page_height,
        );
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
        try drawWrappedWithRefs(
            allocator,
            &page_streams,
            &current_page,
            &has_page,
            &cursor_y,
            &reference_defs,
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
    const last_annots = try current_link_annots.toOwnedSlice(allocator);
    try page_link_annots.append(allocator, last_annots);

    return try buildPdf(allocator, page_streams.items, page_link_annots.items);
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

fn drawWrappedWithRefs(
    allocator: std.mem.Allocator,
    page_streams: *std.ArrayList([]u8),
    current_page: *std.ArrayList(u8),
    has_page: *bool,
    cursor_y: *i32,
    refs: *const std.StringHashMap([]const u8),
    text: []const u8,
    x: i32,
    font_size: i32,
    line_height: i32,
    max_chars: usize,
    margin_top: i32,
    margin_bottom: i32,
    page_height: i32,
) !void {
    const resolved = try resolveReferenceLinks(allocator, text, refs);
    try drawWrapped(
        allocator,
        page_streams,
        current_page,
        has_page,
        cursor_y,
        resolved,
        x,
        font_size,
        line_height,
        max_chars,
        margin_top,
        margin_bottom,
        page_height,
    );
}

fn resolveReferenceLinks(
    allocator: std.mem.Allocator,
    text: []const u8,
    refs: *const std.StringHashMap([]const u8),
) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '[') == null and std.mem.indexOfScalar(u8, text, '<') == null) return text;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '<') {
            const close_angle = std.mem.indexOfScalarPos(u8, text, i + 1, '>') orelse {
                try out.append(allocator, text[i]);
                i += 1;
                continue;
            };

            const target = text[i + 1 .. close_angle];
            if (isLikelyAutolinkTarget(target)) {
                try out.appendSlice(allocator, target);
                try out.appendSlice(allocator, " (");
                try out.appendSlice(allocator, target);
                try out.append(allocator, ')');
                i = close_angle + 1;
                continue;
            }

            try out.appendSlice(allocator, text[i .. close_angle + 1]);
            i = close_angle + 1;
            continue;
        }

        if (text[i] != '[') {
            try out.append(allocator, text[i]);
            i += 1;
            continue;
        }

        const close_first = std.mem.indexOfScalarPos(u8, text, i + 1, ']') orelse {
            try out.append(allocator, text[i]);
            i += 1;
            continue;
        };

        const display = text[i + 1 .. close_first];
        const next_idx = close_first + 1;

        if (next_idx < text.len and text[next_idx] == '(') {
            const close_paren = std.mem.indexOfScalarPos(u8, text, next_idx + 1, ')') orelse {
                try out.appendSlice(allocator, text[i .. close_first + 1]);
                i = close_first + 1;
                continue;
            };

            const destination = std.mem.trim(u8, text[next_idx + 1 .. close_paren], " \t");
            if (destination.len > 0) {
                if (embeddedLinkLabel(display)) |name| {
                    try out.appendSlice(allocator, name);
                    try out.appendSlice(allocator, "<<@");
                    try out.appendSlice(allocator, destination);
                    try out.appendSlice(allocator, "@>>");
                } else {
                    try out.appendSlice(allocator, display);
                    try out.appendSlice(allocator, " (");
                    try out.appendSlice(allocator, destination);
                    try out.append(allocator, ')');
                }
                i = close_paren + 1;
                continue;
            }

            try out.appendSlice(allocator, text[i .. close_paren + 1]);
            i = close_paren + 1;
            continue;
        }

        if (next_idx < text.len and text[next_idx] == '[') {
            const close_second = std.mem.indexOfScalarPos(u8, text, next_idx + 1, ']') orelse {
                try out.appendSlice(allocator, text[i .. close_first + 1]);
                i = close_first + 1;
                continue;
            };

            const explicit_label = text[next_idx + 1 .. close_second];
            const label = if (explicit_label.len == 0) display else explicit_label;
            if (lookupReferenceDestination(refs, label)) |dest| {
                if (embeddedLinkLabel(display)) |name| {
                    try out.appendSlice(allocator, name);
                    try out.appendSlice(allocator, "<<@");
                    try out.appendSlice(allocator, dest);
                    try out.appendSlice(allocator, "@>>");
                } else {
                    try out.appendSlice(allocator, display);
                    try out.appendSlice(allocator, " (");
                    try out.appendSlice(allocator, dest);
                    try out.append(allocator, ')');
                }
                i = close_second + 1;
                continue;
            }

            try out.appendSlice(allocator, text[i .. close_second + 1]);
            i = close_second + 1;
            continue;
        }

        if (lookupReferenceDestination(refs, display)) |dest| {
            if (embeddedLinkLabel(display)) |name| {
                try out.appendSlice(allocator, name);
                try out.appendSlice(allocator, "<<@");
                try out.appendSlice(allocator, dest);
                try out.appendSlice(allocator, "@>>");
            } else {
                try out.appendSlice(allocator, display);
                try out.appendSlice(allocator, " (");
                try out.appendSlice(allocator, dest);
                try out.append(allocator, ')');
            }
            i = close_first + 1;
            continue;
        }

        try out.appendSlice(allocator, text[i .. close_first + 1]);
        i = close_first + 1;
    }

    return out.toOwnedSlice(allocator);
}

fn isLikelyAutolinkTarget(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "http://") or
        std.mem.startsWith(u8, target, "https://") or
        std.mem.startsWith(u8, target, "mailto:");
}

fn embeddedLinkLabel(display: []const u8) ?[]const u8 {
    if (display.len < 2) return null;
    if (display[0] != '!') return null;
    const name = std.mem.trim(u8, display[1..], " \t");
    if (name.len == 0) return null;
    return name;
}

fn lookupReferenceDestination(
    refs: *const std.StringHashMap([]const u8),
    label: []const u8,
) ?[]const u8 {
    var it = refs.iterator();
    while (it.next()) |entry| {
        if (referenceLabelEqualsStored(entry.key_ptr.*, label)) {
            return entry.value_ptr.*;
        }
    }
    return null;
}

fn referenceLabelEqualsStored(stored_normalized: []const u8, raw_label: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw_label, " \t");
    if (stored_normalized.len != trimmed.len) return false;
    for (trimmed, 0..) |c, idx| {
        if (stored_normalized[idx] != std.ascii.toLower(c)) return false;
    }
    return true;
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
        if (g_page_link_annots) |all_annots| {
            if (g_current_link_annots) |cur_annots| {
                const page_annots = try cur_annots.toOwnedSlice(allocator);
                try all_annots.append(allocator, page_annots);
                cur_annots.* = .empty;
            }
        }
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

fn drawTableBlock(
    allocator: std.mem.Allocator,
    page_streams: *std.ArrayList([]u8),
    current_page: *std.ArrayList(u8),
    has_page: *bool,
    cursor_y: *i32,
    rows: []const []const u8,
    aligns: []const TableAlign,
    x: i32,
    margin_top: i32,
    margin_bottom: i32,
    page_height: i32,
) !void {
    if (rows.len == 0) return;

    var header_cells = try splitTableCells(allocator, rows[0]);
    defer header_cells.deinit(allocator);
    if (header_cells.items.len == 0) return;

    const cols = header_cells.items.len;
    var widths = try allocator.alloc(usize, cols);
    defer allocator.free(widths);
    for (widths, 0..) |*w, i| w.* = @max(@as(usize, 3), header_cells.items[i].len);

    for (rows[1..]) |row| {
        var cells = try splitTableCells(allocator, row);
        defer cells.deinit(allocator);
        var i: usize = 0;
        while (i < cols and i < cells.items.len) : (i += 1) {
            widths[i] = @max(widths[i], cells.items[i].len);
        }
    }

    const sep_and_border = cols * 3 + 1;
    var content_space: usize = 84;
    if (sep_and_border < content_space) content_space -= sep_and_border else content_space = cols * 3;
    const per_col = @max(@as(usize, 4), content_space / cols);
    for (widths) |*w| w.* = @min(w.*, per_col);

    cursor_y.* -= 2;
    const line_height: i32 = 14;

    const header_line = try buildTableDisplayLine(allocator, header_cells.items, widths, aligns);
    try ensureSpace(allocator, page_streams, current_page, has_page, cursor_y, line_height, margin_top, margin_bottom, page_height);
    try drawTextLineWithStyle(allocator, current_page, header_line, x, cursor_y.*, 11, .mono);
    cursor_y.* -= line_height;

    const rule_line = try buildTableRuleLine(allocator, widths);
    try ensureSpace(allocator, page_streams, current_page, has_page, cursor_y, line_height, margin_top, margin_bottom, page_height);
    try drawTextLineWithStyle(allocator, current_page, rule_line, x, cursor_y.*, 11, .mono);
    cursor_y.* -= line_height;

    for (rows[1..]) |row| {
        var cells = try splitTableCells(allocator, row);
        defer cells.deinit(allocator);
        const display = try buildTableDisplayLine(allocator, cells.items, widths, aligns);
        try ensureSpace(allocator, page_streams, current_page, has_page, cursor_y, line_height, margin_top, margin_bottom, page_height);
        try drawTextLineWithStyle(allocator, current_page, display, x, cursor_y.*, 11, .mono);
        cursor_y.* -= line_height;
    }

    cursor_y.* -= 4;
}

fn buildTableDisplayLine(
    allocator: std.mem.Allocator,
    cells: []const []const u8,
    widths: []const usize,
    aligns: []const TableAlign,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '|');
    for (widths, 0..) |w, i| {
        try out.append(allocator, ' ');
        const text = if (i < cells.len) cells[i] else "";
        const clipped_len = @min(text.len, w);

        const alignment = if (i < aligns.len) aligns[i] else TableAlign.left;
        const pad_total = w - clipped_len;
        const left_pad: usize = switch (alignment) {
            .left => 0,
            .right => pad_total,
            .center => pad_total / 2,
        };
        const right_pad = pad_total - left_pad;

        var lp: usize = 0;
        while (lp < left_pad) : (lp += 1) try out.append(allocator, ' ');
        try out.appendSlice(allocator, text[0..clipped_len]);
        var rp: usize = 0;
        while (rp < right_pad) : (rp += 1) try out.append(allocator, ' ');
        try out.appendSlice(allocator, " |");
    }

    return out.toOwnedSlice(allocator);
}

fn buildTableRuleLine(allocator: std.mem.Allocator, widths: []const usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '|');
    for (widths) |w| {
        var i: usize = 0;
        while (i < w + 2) : (i += 1) try out.append(allocator, '-');
        try out.append(allocator, '|');
    }
    return out.toOwnedSlice(allocator);
}

fn splitTableCells(allocator: std.mem.Allocator, line: []const u8) !std.ArrayList([]const u8) {
    var cells: std.ArrayList([]const u8) = .empty;
    errdefer cells.deinit(allocator);

    const trimmed = std.mem.trim(u8, line, " \t");
    var work = trimmed;
    if (work.len > 0 and work[0] == '|') work = work[1..];
    if (work.len > 0 and work[work.len - 1] == '|') work = work[0 .. work.len - 1];

    var it = std.mem.splitScalar(u8, work, '|');
    while (it.next()) |part| {
        try cells.append(allocator, std.mem.trim(u8, part, " \t"));
    }
    return cells;
}

fn parseTableAlignments(
    allocator: std.mem.Allocator,
    delimiter_line: []const u8,
    col_count: usize,
) !std.ArrayList(TableAlign) {
    var aligns: std.ArrayList(TableAlign) = .empty;
    errdefer aligns.deinit(allocator);

    var cells = try splitTableCells(allocator, delimiter_line);
    defer cells.deinit(allocator);

    var i: usize = 0;
    while (i < col_count) : (i += 1) {
        const cell = if (i < cells.items.len) cells.items[i] else "---";
        try aligns.append(allocator, tableCellAlign(cell));
    }
    return aligns;
}

fn tableCellAlign(cell: []const u8) TableAlign {
    const trimmed = std.mem.trim(u8, cell, " \t");
    if (trimmed.len == 0) return .left;
    const left = trimmed[0] == ':';
    const right = trimmed[trimmed.len - 1] == ':';
    if (left and right) return .center;
    if (right) return .right;
    return .left;
}

fn looksLikeTableRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '|') == null) return false;
    return true;
}

fn isTableDelimiterLine(trimmed_line: []const u8) bool {
    if (trimmed_line.len == 0) return false;
    var has_dash = false;
    var has_pipe = false;
    for (trimmed_line) |c| {
        if (c == '-') {
            has_dash = true;
            continue;
        }
        if (c == '|') {
            has_pipe = true;
            continue;
        }
        if (c == ':' or c == ' ' or c == '\t') continue;
        return false;
    }
    return has_dash and has_pipe;
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

fn parseReferenceDefinition(line: []const u8) ?ReferenceDefinition {
    var i: usize = 0;
    var leading_spaces: usize = 0;
    while (i < line.len and line[i] == ' ' and leading_spaces < 4) : (i += 1) leading_spaces += 1;
    if (i < line.len and line[i] == '\t') return null;
    if (i >= line.len or line[i] != '[') return null;

    const label_start = i + 1;
    const label_end = std.mem.indexOfScalarPos(u8, line, label_start, ']') orelse return null;
    if (label_end == label_start) return null;

    i = label_end + 1;
    if (i >= line.len or line[i] != ':') return null;
    i += 1;

    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len) return null;

    const dest_start = i;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
    const destination = line[dest_start..i];
    if (destination.len == 0) return null;

    return .{
        .label = line[label_start..label_end],
        .destination = destination,
    };
}

fn normalizeReferenceLabel(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, label, " \t");
    const out = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |c, idx| {
        out[idx] = std.ascii.toLower(c);
    }
    return out;
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

    var pen_x = x;
    const char_w: i32 = @max(1, @divTrunc(font_size * 6, 10));

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
                try command.appendSlice(allocator, textColorCommandForStyle(word.style));
                current_style = word.style;
            }
            try command.appendSlice(allocator, "( ) Tj\n");
            pen_x += char_w;
        }

        if (current_style == null or current_style.? != word.style) {
            const set_font = try std.fmt.allocPrint(
                allocator,
                "{s} {d} Tf\n",
                .{ fontNameForStyle(word.style), font_size },
            );
            try command.appendSlice(allocator, set_font);
            try command.appendSlice(allocator, textColorCommandForStyle(word.style));
            current_style = word.style;
        }

        const escaped = try escapePdfText(allocator, word.text);
        const text_cmd = try std.fmt.allocPrint(allocator, "({s}) Tj\n", .{escaped});
        try command.appendSlice(allocator, text_cmd);

        const word_w: i32 = @intCast(word.text.len);
        if (word.link_dest) |dest| {
            if (g_current_link_annots) |cur_annots| {
                const url_copy = try allocator.alloc(u8, dest.len);
                std.mem.copyForwards(u8, url_copy, dest);
                try cur_annots.append(allocator, .{
                    .x1 = pen_x,
                    .y1 = y - font_size,
                    .x2 = pen_x + word_w * char_w,
                    .y2 = y + 2,
                    .url = url_copy,
                });
            }
        }
        pen_x += word_w * char_w;
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
        .link => "/F1",
    };
}

fn textColorCommandForStyle(style: TextStyle) []const u8 {
    return switch (style) {
        .link => "0.06 0.20 0.72 rg\n",
        else => "0 0 0 rg\n",
    };
}

fn styleFromFlags(bold: bool, italic: bool) TextStyle {
    if (bold and italic) return .bold_italic;
    if (bold) return .bold;
    if (italic) return .italic;
    return .regular;
}

fn deinitStyledWords(allocator: std.mem.Allocator, words: *std.ArrayList(StyledWord)) void {
    for (words.items) |word| {
        allocator.free(word.text);
        if (word.link_dest) |dest| allocator.free(dest);
    }
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
    var link_dest: ?[]u8 = null;
    var copy: []u8 = undefined;

    if (extractEmbeddedLinkMarker(text)) |m| {
        const url = text[m.url_start..m.url_end];
        const url_copy = try allocator.alloc(u8, url.len);
        std.mem.copyForwards(u8, url_copy, url);
        link_dest = url_copy;

        const left = text[0..m.marker_start];
        const right = text[m.marker_end..];
        copy = try allocator.alloc(u8, left.len + right.len);
        std.mem.copyForwards(u8, copy[0..left.len], left);
        std.mem.copyForwards(u8, copy[left.len..], right);
    } else {
        copy = try allocator.alloc(u8, text.len);
        std.mem.copyForwards(u8, copy, text);
    }

    const final_style: TextStyle = if (link_dest != null) .link else styleForWord(style, copy);
    try out.append(allocator, .{ .text = copy, .style = final_style, .link_dest = link_dest });
}

fn extractEmbeddedLinkMarker(text: []const u8) ?struct {
    marker_start: usize,
    marker_end: usize,
    url_start: usize,
    url_end: usize,
} {
    const marker_start = std.mem.lastIndexOf(u8, text, "<<@") orelse return null;
    const marker_end_incl = std.mem.indexOfPos(u8, text, marker_start + 3, "@>>") orelse return null;
    const url_start = marker_start + 3;
    const url_end = marker_end_incl;
    if (marker_start == 0 or url_end <= url_start) return null;
    return .{
        .marker_start = marker_start,
        .marker_end = marker_end_incl + 3,
        .url_start = url_start,
        .url_end = url_end,
    };
}

fn styleForWord(base: TextStyle, text: []const u8) TextStyle {
    if (base != .regular) return base;
    return if (isUrlLikeWord(text) or isBracketDisplayLinkWord(text)) .link else base;
}

fn isUrlLikeWord(word: []const u8) bool {
    var start: usize = 0;
    var end: usize = word.len;

    while (start < end and (word[start] == '(' or word[start] == '<' or word[start] == '[')) : (start += 1) {}
    while (end > start and (word[end - 1] == ')' or word[end - 1] == '>' or word[end - 1] == ']' or word[end - 1] == '.' or word[end - 1] == ',')) : (end -= 1) {}

    if (end <= start) return false;
    const core = word[start..end];
    return isLikelyAutolinkTarget(core);
}

fn isBracketDisplayLinkWord(word: []const u8) bool {
    var start: usize = 0;
    var end: usize = word.len;

    while (start < end and (word[start] == '(' or word[start] == '<')) : (start += 1) {}
    while (end > start and (word[end - 1] == ')' or word[end - 1] == '>' or word[end - 1] == '.' or word[end - 1] == ',')) : (end -= 1) {}
    if (end <= start + 2) return false;

    const core = word[start..end];
    if (core[0] != '[' or core[core.len - 1] != ']') return false;
    const inner = std.mem.trim(u8, core[1 .. core.len - 1], " \t");
    if (inner.len == 0) return false;
    if (std.mem.indexOfScalar(u8, inner, '[') != null) return false;
    if (std.mem.indexOfScalar(u8, inner, ']') != null) return false;
    return true;
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

fn buildPdf(
    allocator: std.mem.Allocator,
    page_streams: []const []const u8,
    page_link_annots: []const []LinkAnnotation,
) ![]u8 {
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

    var page_annots_refs: std.ArrayList(?[]const u8) = .empty;
    defer page_annots_refs.deinit(allocator);
    var page_idx: usize = 0;
    while (page_idx < page_streams.len) : (page_idx += 1) {
        const annots = if (page_idx < page_link_annots.len) page_link_annots[page_idx] else &.{};
        if (annots.len == 0) {
            try page_annots_refs.append(allocator, null);
            continue;
        }

        var ids: std.ArrayList(usize) = .empty;
        defer ids.deinit(allocator);
        for (annots) |a| {
            const escaped_url = try escapePdfText(allocator, a.url);
            const annot_obj = try std.fmt.allocPrint(
                allocator,
                "<< /Type /Annot /Subtype /Link /Rect [{d} {d} {d} {d}] /Border [0 0 0] /A << /S /URI /URI ({s}) >> >>",
                .{ a.x1, a.y1, a.x2, a.y2, escaped_url },
            );
            try objects.append(allocator, annot_obj);
            try ids.append(allocator, objects.items.len);
        }

        var refs: std.ArrayList(u8) = .empty;
        defer refs.deinit(allocator);
        try refs.append(allocator, '[');
        for (ids.items) |id| {
            const item = try std.fmt.allocPrint(allocator, "{d} 0 R ", .{id});
            try refs.appendSlice(allocator, item);
        }
        try refs.append(allocator, ']');
        try page_annots_refs.append(allocator, try refs.toOwnedSlice(allocator));
    }

    var page_ids: std.ArrayList(usize) = .empty;
    defer page_ids.deinit(allocator);
    for (content_ids.items, 0..) |content_id, idx| {
        const annots_part = if (idx < page_annots_refs.items.len and page_annots_refs.items[idx] != null)
            try std.fmt.allocPrint(allocator, " /Annots {s}", .{page_annots_refs.items[idx].?})
        else
            "";
        const page_obj = try std.fmt.allocPrint(
            allocator,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R /F4 6 0 R /F5 7 0 R >> >> /Contents {d} 0 R{s} >>",
            .{ content_id, annots_part },
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

test "table delimiter detection" {
    try std.testing.expect(isTableDelimiterLine("| --- | :---: |"));
    try std.testing.expect(isTableDelimiterLine("---|---"));
    try std.testing.expect(!isTableDelimiterLine("| a | b |"));
    try std.testing.expect(!isTableDelimiterLine("---"));
}

test "table row split" {
    const allocator = std.testing.allocator;
    var cells = try splitTableCells(allocator, "| name | age | city |");
    defer cells.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), cells.items.len);
    try std.testing.expectEqualStrings("name", cells.items[0]);
    try std.testing.expectEqualStrings("age", cells.items[1]);
    try std.testing.expectEqualStrings("city", cells.items[2]);
}

test "table alignment parsing" {
    const allocator = std.testing.allocator;
    var aligns = try parseTableAlignments(allocator, "| :--- | :---: | ---: |", 3);
    defer aligns.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), aligns.items.len);
    try std.testing.expect(aligns.items[0] == .left);
    try std.testing.expect(aligns.items[1] == .center);
    try std.testing.expect(aligns.items[2] == .right);
}

test "reference definition parsing" {
    const def = parseReferenceDefinition("[docs]: https://example.com/docs \"title\"").?;
    try std.testing.expectEqualStrings("docs", def.label);
    try std.testing.expectEqualStrings("https://example.com/docs", def.destination);
    try std.testing.expect(parseReferenceDefinition("not a ref") == null);
}

test "reference label normalization" {
    const allocator = std.testing.allocator;
    const norm = try normalizeReferenceLabel(allocator, "  MyLabel\t");
    defer allocator.free(norm);
    try std.testing.expectEqualStrings("mylabel", norm);
}

test "reference link resolution" {
    const allocator = std.testing.allocator;
    var refs = std.StringHashMap([]const u8).init(allocator);

    const label = try normalizeReferenceLabel(allocator, "Docs");
    defer allocator.free(label);
    defer refs.deinit();
    try refs.put(label, "https://example.com/docs");

    const resolved = try resolveReferenceLinks(allocator, "See [API][Docs] and [Docs].", &refs);
    defer if (resolved.ptr != "See [API][Docs] and [Docs].".ptr) allocator.free(resolved);
    try std.testing.expectEqualStrings("See API (https://example.com/docs) and Docs (https://example.com/docs).", resolved);
}

test "inline link and autolink resolution" {
    const allocator = std.testing.allocator;
    var refs = std.StringHashMap([]const u8).init(allocator);
    defer refs.deinit();

    const input = "Read [guide](https://example.com/guide) and <https://example.com/api>.";
    const resolved = try resolveReferenceLinks(allocator, input, &refs);
    defer if (resolved.ptr != input.ptr) allocator.free(resolved);
    try std.testing.expectEqualStrings(
        "Read guide (https://example.com/guide) and https://example.com/api (https://example.com/api).",
        resolved,
    );
}

test "embedded display link syntax" {
    const allocator = std.testing.allocator;
    var refs = std.StringHashMap([]const u8).init(allocator);
    defer refs.deinit();

    const label = try normalizeReferenceLabel(allocator, "docs");
    defer allocator.free(label);
    try refs.put(label, "https://example.com/docs");

    const input = "Use [!Guide](https://example.com/guide) and [!Docs][docs].";
    const resolved = try resolveReferenceLinks(allocator, input, &refs);
    defer if (resolved.ptr != input.ptr) allocator.free(resolved);
    try std.testing.expectEqualStrings(
        "Use Guide<<@https://example.com/guide@>> and Docs<<@https://example.com/docs@>>.",
        resolved,
    );
}

test "url words are styled as links" {
    const allocator = std.testing.allocator;
    var words = try inlineStyledWords(allocator, "see https://example.com and (mailto:a@b.com)");
    defer deinitStyledWords(allocator, &words);

    try std.testing.expect(words.items.len >= 3);
    try std.testing.expect(words.items[1].style == .link);
    try std.testing.expect(words.items[3].style == .link);
}

test "bracket display links are styled as links" {
    const allocator = std.testing.allocator;
    var words = try inlineStyledWords(allocator, "See [Guide]. and [Docs]");
    defer deinitStyledWords(allocator, &words);

    try std.testing.expect(words.items.len >= 3);
    try std.testing.expect(words.items[1].style == .link);
    try std.testing.expect(words.items[3].style == .link);
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
