const std = @import("std");
const Writer = std.Io.Writer;

const Ast = @import("Ast.zig");

pub fn text(ast: *const Ast, writer: *Writer) Writer.Error!void {
    try writeTextNode(ast, writer, .root, 0, false);
    try writer.writeByte('\n');
}

fn writeTextNode(
    ast: *const Ast,
    writer: *Writer,
    index: Ast.Node.Index,
    depth: usize,
    trailing_newline: bool,
) Writer.Error!void {
    try writeTextIndent(writer, depth);

    const node_i: usize = @intCast(@backingInt(index));
    const data = ast.nodes.items(.data)[node_i];
    try writer.writeByte('(');
    try writer.writeAll(@tagName(std.meta.activeTag(data)));
    switch (data) {
        .declaration => |declaration| try writeTextTokenLabel(ast, writer, declaration.lhs),
        .char_literal, .number_literal, .string_literal, .identifier => {
            try writeTextTokenLabel(ast, writer, ast.nodes.items(.main_token)[node_i]);
        },
        .field_access => |field| try writeTextTokenLabel(ast, writer, field.child),
        else => {},
    }

    switch (data) {
        .map => |declarations| if (declarations.len != 0) {
            if (depth != 0) try writer.writeByte('{');
            try writer.writeByte('\n');
            for (declarations, 0..) |declaration, i| {
                try writeTextNode(ast, writer, declaration, depth + 1, i + 1 < declarations.len);
            }
            if (depth != 0) try writer.writeByte('}');
        },
        .declaration => |declaration| {
            try writer.writeByte('\n');
            try writeTextNode(ast, writer, declaration.rhs, depth + 1, false);
        },
        .negation => |operand| {
            try writer.writeByte('\n');
            try writeTextNode(ast, writer, operand, depth + 1, false);
        },
        .group => |group| {
            try writer.writeByte('\n');
            try writeTextNode(ast, writer, group[0], depth + 1, false);
        },
        inline .bool_or, .bool_and, .equal, .equal_equal, .add, .sub, .mul, .div => |binary| {
            try writer.writeByte('\n');
            try writeTextNode(ast, writer, binary.lhs, depth + 1, true);
            try writeTextNode(ast, writer, binary.rhs, depth + 1, false);
        },
        .field_access => |field| {
            try writer.writeByte('\n');
            try writeTextNode(ast, writer, field.parent, depth + 1, false);
        },
        .apply => |apply| {
            try writer.writeByte('\n');
            try writeTextNode(ast, writer, apply.func, depth + 1, true);
            try writeTextNode(ast, writer, apply.arg, depth + 1, false);
        },
        .char_literal, .number_literal, .string_literal, .identifier => {},
    }
    try writer.writeByte(')');
    if (trailing_newline) try writer.writeByte('\n');
}

fn writeTextIndent(writer: *Writer, depth: usize) Writer.Error!void {
    for (0..depth) |_| try writer.writeAll("  ");
}

fn writeTextTokenLabel(ast: *const Ast, writer: *Writer, token_index: Ast.TokenIndex) Writer.Error!void {
    try writer.writeByte(' ');
    try writer.printStringEscaped(ast.tokenSlice(token_index));
}

test "text AST dump" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(), "value = a + 2");
    defer ast.deinit(std.testing.allocator) catch unreachable;

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try text(&ast, &output.writer);

    try std.testing.expectEqualStrings(
        \\(map
        \\  (declaration "value"
        \\    (add
        \\      (identifier "a")
        \\      (number_literal "2"))))
        \\
    , output.written());
}
