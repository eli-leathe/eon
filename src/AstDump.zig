const std = @import("std");
const Writer = std.Io.Writer;

const Ast = @import("Ast.zig");
const Tokenizer = @import("Tokenizer.zig");

pub fn text(ast: *const Ast, writer: *Writer) Writer.Error!void {
    try writeTextNode(ast, writer, .root, 0, false);
    try writer.writeByte('\n');
}

pub fn dot(ast: *const Ast, writer: *Writer) Writer.Error!void {
    try writer.writeAll(
        \\digraph AST {
        \\  node [shape=box];
        \\
    );

    for (ast.nodes.items(.data), 0..) |data, i| {
        try writer.print("  n{d} [label=\"{s}", .{ i, @tagName(std.meta.activeTag(data)) });
        switch (data) {
            .declaration => |declaration| try writeDotTokenLabel(ast, writer, declaration.lhs),
            .char_literal, .number_literal, .string_literal, .identifier => {
                try writeDotTokenLabel(ast, writer, ast.nodes.items(.main_token)[i]);
            },
            .field_access => |field| try writeDotTokenLabel(ast, writer, field.child),
            else => {},
        }
        try writer.writeAll("\"];\n");
    }

    for (ast.nodes.items(.data), 0..) |data, i| {
        switch (data) {
            .map => |declarations| for (declarations) |declaration| {
                try writeDotEdge(writer, i, declaration, null);
            },
            .declaration => |declaration| try writeDotEdge(writer, i, declaration.rhs, "value"),
            .negation => |operand| try writeDotEdge(writer, i, operand, "operand"),
            .group => |group| try writeDotEdge(writer, i, group[0], "expression"),
            inline .bool_or, .bool_and, .equal, .equal_equal, .add, .sub, .mul, .div => |binary| {
                try writeDotEdge(writer, i, binary.lhs, "lhs");
                try writeDotEdge(writer, i, binary.rhs, "rhs");
            },
            .field_access => |field| try writeDotEdge(writer, i, field.parent, "parent"),
            .apply => |apply| {
                try writeDotEdge(writer, i, apply.func, "function");
                try writeDotEdge(writer, i, apply.arg, "argument");
            },
            .char_literal, .number_literal, .string_literal, .identifier => {},
        }
    }

    try writer.writeAll("}\n");
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
    try writer.printStringEscaped(tokenText(ast, token_index));
}

fn writeDotTokenLabel(ast: *const Ast, writer: *Writer, token_index: Ast.TokenIndex) Writer.Error!void {
    try writer.writeAll("\\n");
    try writeDotEscaped(writer, tokenText(ast, token_index));
}

fn writeDotEdge(writer: *Writer, from: usize, to: Ast.Node.Index, label: ?[]const u8) Writer.Error!void {
    try writer.print("  n{d} -> n{d}", .{ from, @backingInt(to) });
    if (label) |edge_label| try writer.print(" [label=\"{s}\"]", .{edge_label});
    try writer.writeAll(";\n");
}

fn writeDotEscaped(writer: *Writer, bytes: []const u8) Writer.Error!void {
    for (bytes) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20 or byte == 0x7f)
            try writer.writeByte('?')
        else
            try writer.writeByte(byte),
    };
}

fn tokenText(ast: *const Ast, wanted: Ast.TokenIndex) []const u8 {
    var tokenizer = Tokenizer.init(ast.source);
    var index: Ast.TokenIndex = 0;
    while (true) : (index += 1) {
        const token = tokenizer.next();
        if (index == wanted) return ast.source[token.loc.start..token.loc.end];
        std.debug.assert(token.tag != .eof);
    }
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

test "DOT AST dump" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(), "value = a");
    defer ast.deinit(std.testing.allocator) catch unreachable;

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try dot(&ast, &output.writer);

    try std.testing.expect(std.mem.startsWith(u8, output.written(), "digraph AST {\n"));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "n0 -> n2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "n2 [label=\"declaration\\nvalue\"];") != null);
}
