const std = @import("std");
const md_pdf = @import("md_pdf");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2 or args.len > 3) {
        try printUsage(args[0]);
        return;
    }

    const input_path = args[1];
    const computed_output_path = if (args.len == 3)
        null
    else
        try md_pdf.defaultOutputPath(allocator, input_path);
    defer if (computed_output_path) |path| allocator.free(path);

    const output_path = if (computed_output_path) |path| path else args[2];
    try md_pdf.convertMarkdownToPdf(allocator, input_path, output_path);

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("wrote {s}\n", .{output_path});
    try stderr.flush();
}

fn printUsage(argv0: []const u8) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("Usage: {s} <input.md> [output.pdf]\n", .{argv0});
    try stderr.print("If [output.pdf] is omitted, output is derived from input path.\n", .{});
    try stderr.flush();
}
