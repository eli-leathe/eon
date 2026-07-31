const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;

const temporal = @import("temporal");

pub fn main(init: std.process.Init) u8 {
    generate(init) catch |err| {
        var buffer: [1024]u8 = undefined;
        var stderr = Io.File.stderr().writer(init.io, &buffer);
        stderr.interface.print("snapshot generation failed: {s}\n", .{@errorName(err)}) catch {};
        stderr.interface.flush() catch {};
        return 1;
    };
    return 0;
}

fn generate(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;

    var cases_dir = try Io.Dir.cwd().openDir(init.io, args[1], .{ .iterate = true });
    defer cases_dir.close(init.io);

    var case_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (case_names.items) |name| init.gpa.free(name);
        case_names.deinit(init.gpa);
    }

    var iterator = cases_dir.iterateAssumeFirstIteration();
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".temporal")) continue;
        try case_names.append(init.gpa, try init.gpa.dupe(u8, entry.name));
    }
    std.sort.insertion([]const u8, case_names.items, {}, lessThan);

    var output: Writer.Allocating = .init(init.gpa);
    defer output.deinit();

    for (case_names.items, 0..) |name, i| {
        if (i != 0) try output.writer.writeByte('\n');
        try output.writer.print("=== {s} ===\n", .{name});

        const source = try cases_dir.readFileAllocOptions(
            init.io,
            name,
            init.gpa,
            .limited(std.math.maxInt(usize)),
            .of(u8),
            0,
        );
        defer init.gpa.free(source);

        try writeTokens(source, &output.writer);
        try writeParseResult(init.gpa, source, &output.writer);
    }

    try Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = args[2],
        .data = output.written(),
    });
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn writeTokens(source: [:0]const u8, writer: *Writer) Writer.Error!void {
    try writer.writeAll("TOKENS\n");
    var tokenizer = temporal.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try writer.print("  {s} {d}..{d} ", .{ @tagName(token.tag), token.loc.start, token.loc.end });
        try writer.printStringEscaped(source[token.loc.start..token.loc.end]);
        try writer.writeByte('\n');
        if (token.tag == .eof) break;
    }
}

fn writeParseResult(gpa: std.mem.Allocator, source: [:0]const u8, writer: *Writer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var ast = try temporal.Parse.parse(gpa, arena.allocator(), source);
    defer ast.deinit(gpa) catch unreachable;

    try writer.writeAll("AST\n");
    if (ast.errors.len == 0) {
        try temporal.AstDump.text(&ast, writer);
    } else {
        try writer.writeAll("  <unavailable after parse error>\n");
    }

    try writer.writeAll("ERRORS\n");
    if (ast.errors.len == 0) {
        try writer.writeAll("  (none)\n");
        return;
    }

    for (ast.errors) |parse_error| {
        const token_i: usize = parse_error.token;
        const tag = ast.tokens.items(.tag)[token_i];
        const start = ast.tokens.items(.start)[token_i];
        try writer.print("  token {d} ({s} at {d}): ", .{ token_i, @tagName(tag), start });
        switch (parse_error.data) {
            .expected_token => |expected| try writer.print("expected {s}\n", .{@tagName(expected)}),
            .expected_expr => try writer.writeAll("expected expression\n"),
            .expected_prefix_expr => try writer.writeAll("expected expression after prefix operator\n"),
            .chained_comparison_operators => try writer.writeAll("comparison operators cannot be chained\n"),
            .expected_suffix_op => try writer.writeAll("expected field name after '.'\n"),
            .ambiguous_negation => try writer.writeAll("parenthesize a negated function application\n"),
            .expected_declaration_separator => try writer.writeAll("expected newline or ';' between declarations\n"),
        }
    }
}
