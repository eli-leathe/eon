const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;

const eon = @import("eon");

const Invocation = union(enum) {
    check: []const u8,
    format: struct {
        input_path: []const u8,
        write: bool,
    },
    ast_dump: []const u8,
    get: struct {
        path: []const u8,
        input_path: []const u8,
    },
    help,
};

const ParseArgsError = error{
    MissingCommand,
    UnknownCommand,
    InvalidArguments,
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

    const command_args = args[1..];
    const invocation = parseInvocation(command_args) catch |err| {
        switch (err) {
            error.MissingCommand => try stderr.writeAll("error: no command provided\n"),
            error.UnknownCommand => try stderr.print("error: unknown command: {s}\n", .{command_args[0]}),
            error.InvalidArguments => try stderr.print("error: invalid arguments for command: {s}\n", .{command_args[0]}),
        }
        try usage(stderr);
        return 1;
    };

    if (invocation == .help) {
        try usage(stdout);
        return 0;
    }

    const path = switch (invocation) {
        .check, .ast_dump => |input_path| input_path,
        .format => |format| format.input_path,
        .get => |get| get.input_path,
        .help => unreachable,
    };

    if (invocation == .format and invocation.format.write and std.mem.eql(u8, path, "-")) {
        try stderr.writeAll("error: cannot format standard input in place\n");
        return 1;
    }

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

    switch (invocation) {
        .check => {},
        .format => |format| if (format.write) {
            var output: Writer.Allocating = .init(init.gpa);
            defer output.deinit();
            try eon.Format.render(&ast, &output.writer);
            Io.Dir.cwd().writeFile(init.io, .{
                .sub_path = format.input_path,
                .data = output.written(),
            }) catch |err| {
                try stderr.print("error: unable to write {s}: {s}\n", .{ format.input_path, @errorName(err) });
                return 1;
            };
        } else {
            try eon.Format.render(&ast, stdout);
        },
        .ast_dump => try stdout.print("{f}", .{ast}),
        .get => |get| {
            var interpreter = eon.Interpreter.init(init.gpa, ast);
            defer interpreter.deinit();

            var value_path = try init.gpa.alloc([]const u8, std.mem.countScalar(u8, get.path, '.') + 1);
            defer init.gpa.free(value_path);
            var it = std.mem.splitScalar(u8, get.path, '.');
            var i: usize = 0;
            while (it.next()) |part| : (i += 1) value_path[i] = part;

            const value = try interpreter.get(value_path);
            try stdout.print("{f}\n", .{value});
        },
        .help => unreachable,
    }
    return 0;
}

fn parseInvocation(args: []const []const u8) ParseArgsError!Invocation {
    if (args.len == 0) return error.MissingCommand;

    const command = args[0];
    if (std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "-h") or
        std.mem.eql(u8, command, "--help"))
    {
        if (args.len != 1) return error.InvalidArguments;
        return .help;
    }

    if (std.mem.eql(u8, command, "check")) {
        if (args.len != 2) return error.InvalidArguments;
        return .{ .check = args[1] };
    }

    if (std.mem.eql(u8, command, "format") or std.mem.eql(u8, command, "fmt")) {
        if (args.len == 2) return .{ .format = .{
            .input_path = args[1],
            .write = false,
        } };
        if (args.len == 3 and std.mem.eql(u8, args[1], "-w")) return .{ .format = .{
            .input_path = args[2],
            .write = true,
        } };
        return error.InvalidArguments;
    }

    if (std.mem.eql(u8, command, "ast-dump")) {
        if (args.len != 2) return error.InvalidArguments;
        return .{ .ast_dump = args[1] };
    }

    if (std.mem.eql(u8, command, "get")) {
        if (args.len != 3) return error.InvalidArguments;
        return .{ .get = .{
            .path = args[1],
            .input_path = args[2],
        } };
    }

    return error.UnknownCommand;
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
        \\Usage: eon <command> [arguments]
        \\
        \\Commands:
        \\  check <file|->             Parse and validate a file
        \\  format [-w] <file|->       Format source (-w writes the file in place)
        \\  fmt [-w] <file|->          Alias for 'format'
        \\  ast-dump <file|->          Dump the parsed AST as an S-expression
        \\  get <path> <file|->        Evaluate and print a dot-separated value path
        \\  help                       Print this help and exit
        \\
        \\Use '-' as the file to read from standard input.
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

test "parse command invocations" {
    const format = try parseInvocation(&.{ "format", "config.eon" });
    try std.testing.expectEqualStrings("config.eon", format.format.input_path);
    try std.testing.expect(!format.format.write);

    const format_in_place = try parseInvocation(&.{ "format", "-w", "config.eon" });
    try std.testing.expectEqualStrings("config.eon", format_in_place.format.input_path);
    try std.testing.expect(format_in_place.format.write);

    const get = try parseInvocation(&.{ "get", "server.port", "config.eon" });
    try std.testing.expectEqualStrings("server.port", get.get.path);
    try std.testing.expectEqualStrings("config.eon", get.get.input_path);

    try std.testing.expectEqual(Invocation.help, try parseInvocation(&.{"help"}));
    try std.testing.expectError(error.MissingCommand, parseInvocation(&.{}));
    try std.testing.expectError(error.UnknownCommand, parseInvocation(&.{"--format"}));
    try std.testing.expectError(error.InvalidArguments, parseInvocation(&.{ "get", "server.port" }));
}

test "line and column" {
    const location = lineColumn("one\ntwo", 6);
    try std.testing.expectEqual(@as(usize, 2), location.line);
    try std.testing.expectEqual(@as(usize, 3), location.column);
}
