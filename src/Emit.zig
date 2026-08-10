const std = @import("std");
const Writer = std.Io.Writer;

const Interpreter = @import("Interpreter.zig");
const Tokenizer = @import("Tokenizer.zig");

pub const Field = Interpreter.Field;
pub const Value = Interpreter.Value;

pub const Error = Writer.Error || error{
    InvalidNumber,
    UnsupportedValue,
};

/// Emits a complete Eon document containing one declaration per field.
pub fn emit(fields: []const Field, writer: *Writer) Error!void {
    try emitFields(fields, writer, 0);
}

fn emitFields(fields: []const Field, writer: *Writer, depth: usize) Error!void {
    for (fields) |field| {
        try writer.splatByteAll(' ', depth * 2);
        try emitIdentifier(field.name, writer);
        try writer.writeAll(" = ");
        try emitValue(field.value, writer, depth);
        try writer.writeByte('\n');
    }
}

fn emitIdentifier(name: []const u8, writer: *Writer) Writer.Error!void {
    if (isBareIdentifier(name) and Tokenizer.Token.getKeyword(name) == null) {
        try writer.writeAll(name);
    } else {
        try writer.writeByte('@');
        try writer.printStringEscaped(name);
    }
}

fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0 or !isIdentifierStart(name[0])) return false;
    for (name[1..]) |byte| {
        if (!isIdentifierContinue(byte)) return false;
    }
    return true;
}

fn isIdentifierStart(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '_' => true,
        else => false,
    };
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or switch (byte) {
        '0'...'9' => true,
        else => false,
    };
}

fn emitValue(value: Value, writer: *Writer, depth: usize) Error!void {
    switch (value) {
        .string => |string| try writer.printStringEscaped(string),
        .number => |number| {
            if (!std.math.isFinite(number)) return error.InvalidNumber;
            try writer.print("{d}", .{number});
        },
        .char => |char| {
            try writer.writeByte('\'');
            try std.zig.charEscape(char, writer);
            try writer.writeByte('\'');
        },
        .boolean => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .array => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, i| {
                if (i != 0) try writer.writeAll(", ");
                try emitValue(item, writer, depth);
            }
            try writer.writeByte(']');
        },
        .record => |fields| {
            try writer.writeByte('{');
            if (fields.len != 0) {
                try writer.writeByte('\n');
                try emitFields(fields, writer, depth + 1);
                try writer.splatByteAll(' ', depth * 2);
            }
            try writer.writeByte('}');
        },
        .function => return error.UnsupportedValue,
    }
}

test "emit key-value document" {
    const nested_items = [_]Value{ .{ .number = 2 }, .{ .number = 3 } };
    const items = [_]Value{
        .{ .number = 1 },
        .{ .boolean = true },
        .{ .array = &nested_items },
    };
    const server_fields = [_]Field{
        .{ .name = "host", .value = .{ .string = "localhost" } },
        .{ .name = "port", .value = .{ .number = 8080 } },
    };
    const fields = [_]Field{
        .{ .name = "name", .value = .{ .string = "demo" } },
        .{ .name = "enabled", .value = .{ .boolean = true } },
        .{ .name = "if", .value = .{ .number = 3 } },
        .{ .name = "quote\"name", .value = .{ .string = "line\n\"two\"\\" } },
        .{ .name = "quote", .value = .{ .char = '\'' } },
        .{ .name = "items", .value = .{ .array = &items } },
        .{ .name = "server", .value = .{ .record = &server_fields } },
    };

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try emit(&fields, &output.writer);

    try std.testing.expectEqualStrings(
        \\name = "demo"
        \\enabled = true
        \\@"if" = 3
        \\@"quote\"name" = "line\n\"two\"\\"
        \\quote = '\''
        \\items = [1, true, [2, 3]]
        \\server = {
        \\  host = "localhost"
        \\  port = 8080
        \\}
        \\
    , output.written());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().dupeSentinel(u8, output.written(), 0);
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(), source);
    defer ast.deinit(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    var interpreter = Interpreter.init(std.testing.allocator, ast);
    defer interpreter.deinit();
    try std.testing.expectEqual(Value{ .boolean = true }, try interpreter.get("enabled"));
    try std.testing.expectEqual(Value{ .number = 3 }, try interpreter.get("if"));
    try std.testing.expectEqualStrings("line\n\"two\"\\", (try interpreter.get("quote\"name")).string);
    try std.testing.expectEqual(@as(u21, '\''), (try interpreter.get("quote")).char);
    try std.testing.expectEqual(@as(usize, 3), (try interpreter.get("items")).array.len);
    try std.testing.expectEqual(Value{ .number = 8080 }, try interpreter.get("server.port"));
}
