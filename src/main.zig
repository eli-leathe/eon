const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;

const eon = @import("eon");

const Mode = union(enum) {
    none,
    format,
    text,
    get: []const u8,
};

pub fn main(init: std.process.Init) u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_file_writer = Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr_file_writer = Io.File.stderr().writer(init.io, &stderr_buffer);
    const stdout = &stdout_file_writer.interface;
    const stderr = &stderr_file_writer.interface;

    const status = run(init, stdout, stderr) catch |err| status: {
        stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
        break :status 1;
    };
    stdout.flush() catch return 1;
    stderr.flush() catch return 1;
    return status;
}

fn run(init: std.process.Init, stdout: *Writer, stderr: *Writer) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var input_path: ?[]const u8 = null;
    var mode: Mode = .none;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try usage(stdout);
            return 0;
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "--fmt")) {
            mode = .format;
        } else if (std.mem.eql(u8, arg, "--ast-dump")) {
            mode = .text;
        } else if (std.mem.startsWith(u8, arg, "--get=")) {
            mode = .{ .get = arg[6..] };
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            try stderr.print("error: unrecognized argument: {s}\n", .{arg});
            try usage(stderr);
            return 1;
        } else if (input_path != null) {
            try stderr.print("error: multiple input files: {s} and {s}\n", .{ input_path.?, arg });
            try usage(stderr);
            return 1;
        } else {
            input_path = arg;
        }
    }

    const path = input_path orelse {
        try stderr.writeAll("error: no input file\n");
        try usage(stderr);
        return 1;
    };

    const source = readInput(init.io, arena, path) catch |err| {
        const input_name = if (std.mem.eql(u8, path, "-")) "stdin" else path;
        try stderr.print("error: unable to read {s}: {s}\n", .{ input_name, @errorName(err) });
        return 1;
    };

    var ast = try eon.Parse.parse(init.gpa, arena, source);
    defer ast.deinit(init.gpa) catch {};

    if (ast.errors.len != 0) {
        const input_name = if (std.mem.eql(u8, path, "-")) "<stdin>" else path;
        for (ast.errors) |parse_error| try printParseError(stderr, input_name, &ast, parse_error);
        return 1;
    }

    switch (mode) {
        .none => {},
        .format => try eon.Format.render(&ast, stdout),
        .text => try stdout.print("{f}", .{ast}),
        .get => |what| {
            var interpreter = eon.Interpreter.init(init.gpa, ast);
            defer interpreter.deinit();

            var what_path = try init.gpa.alloc([]const u8, std.mem.countScalar(u8, what, '.') + 1);
            defer init.gpa.free(what_path);
            var it = std.mem.splitScalar(u8, what, '.');
            var i: usize = 0;
            while (it.next()) |part| : (i += 1) what_path[i] = part;

            const value = try interpreter.get(what_path);
            try stdout.print("{f}\n", .{value});
        },
    }
    return 0;
}

fn readInput(io: Io, allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var read_buffer: [4096]u8 = undefined;
        var stdin_reader = Io.File.stdin().readerStreaming(io, &read_buffer);
        return stdin_reader.interface.allocRemainingAlignedSentinel(
            allocator,
            .limited(std.math.maxInt(usize)),
            .of(u8),
            0,
        );
    }

    return Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(std.math.maxInt(usize)),
        .of(u8),
        0,
    );
}

fn usage(writer: *Writer) Writer.Error!void {
    try writer.writeAll(
        \\Usage: eon [options] <file|->
        \\
        \\Use '-' as the file to read from standard input.
        \\
        \\Options:
        \\  -h, --help        Print this help and exit
        \\  --format, --fmt   Print canonically formatted source
        \\  --ast-dump        Dump the parsed AST as an S-expression
        \\  --get=PATH        Evaluate and print a dot-separated value path
        \\
    );
}

fn printParseError(writer: *Writer, path: []const u8, ast: *const eon.Ast, parse_error: eon.Ast.Error) Writer.Error!void {
    const token_tags = ast.tokens.items(.tag);
    const token_starts = ast.tokens.items(.start);
    const token_index: usize = parse_error.token;
    const location = lineColumn(ast.source, token_starts[token_index]);

    try writer.print("{s}:{d}:{d}: error: ", .{ path, location.line, location.column });
    switch (parse_error.data) {
        .expected_token => |expected| try writer.print(
            "expected {s}, found {s}",
            .{ @tagName(expected), @tagName(token_tags[token_index]) },
        ),
        .expected_expr => try writer.writeAll("expected expression"),
        .expected_prefix_expr => try writer.writeAll("expected expression after prefix operator"),
        .chained_comparison_operators => try writer.writeAll("comparison operators cannot be chained"),
        .expected_suffix_op => try writer.writeAll("expected field name after '.'"),
        .ambiguous_negation => try writer.writeAll("parenthesize a negated function application"),
        .expected_declaration_separator => try writer.writeAll("expected newline or ';' between declarations"),
    }
    try writer.writeByte('\n');
}

fn lineColumn(source: []const u8, byte_offset: usize) struct { line: usize, column: usize } {
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..byte_offset]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

test "line and column" {
    const location = lineColumn("one\ntwo", 6);
    try std.testing.expectEqual(@as(usize, 2), location.line);
    try std.testing.expectEqual(@as(usize, 3), location.column);
}
