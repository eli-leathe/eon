const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const Ast = @This();

pub const Error = struct {
    token: TokenIndex,
    data: Data,
    pub const Data = union(enum) {
        expected_token: Token.Tag,
        expected_expr,
        expected_prefix_expr,
        chained_comparison_operators,
        expected_suffix_op,
        ambiguous_negation,
        expected_declaration_separator,
    };
};

pub const TokenIndex = u32;

/// A node identity that is stable for the lifetime of one parsed AST.
pub const NodeRef = struct {
    index: Node.Index,
};

pub const SourceRange = struct {
    start: usize,
    end: usize,
};
pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: u32,
});

pub const Node = struct {
    data: Data,
    main_token: TokenIndex,

    pub const ArrayItem = struct {
        value: Index,
        comma: ?TokenIndex,
    };

    pub const Tag = @typeInfo(Data).@"union".tag_type.?;
    pub const Data = union(enum) {
        map: struct { []Index, TokenIndex },
        declaration: struct { lhs: TokenIndex, rhs: Index },
        negation: Index,
        boolean_literal,
        char_literal,
        number_literal,
        string_literal,
        atom_literal: TokenIndex,
        identifier,
        array: struct { []ArrayItem, TokenIndex },
        group: struct { Index, TokenIndex },
        bool_or: struct { lhs: Index, rhs: Index },
        bool_and: struct { lhs: Index, rhs: Index },
        equal: struct { lhs: Index, rhs: Index },
        equal_equal: struct { lhs: Index, rhs: Index },
        add: struct { lhs: Index, rhs: Index },
        sub: struct { lhs: Index, rhs: Index },
        mul: struct { lhs: Index, rhs: Index },
        div: struct { lhs: Index, rhs: Index },
        field_access: struct { parent: Index, child: TokenIndex },
        apply: struct { func: Index, arg: Index },
    };

    pub const Index = enum(u32) {
        root = 0,
        _,
    };
};
pub const NodeList = std.MultiArrayList(Node);

pub fn tokenTag(self: *const Ast, token_index: TokenIndex) Token.Tag {
    return self.tokens.items(.tag)[token_index];
}

pub fn tokenStart(self: *const Ast, token_index: TokenIndex) u32 {
    return self.tokens.items(.start)[token_index];
}

pub fn tokenEnd(self: *const Ast, token_index: TokenIndex) usize {
    return self.tokenStart(token_index) + self.tokenSlice(token_index).len;
}

pub fn tokenSlice(self: *const Ast, token_index: TokenIndex) []const u8 {
    const tag = self.tokenTag(token_index);
    if (tag.lexeme()) |lexeme| return lexeme;

    var tokenizer: Tokenizer = .{
        .buf = self.source,
        .index = self.tokenStart(token_index),
    };
    const token = tokenizer.next();
    std.debug.assert(token.tag == tag);
    return self.source[token.loc.start..token.loc.end];
}

pub fn nodeData(self: *const Ast, index: Node.Index) Node.Data {
    return self.nodes.items(.data)[@intCast(@backingInt(index))];
}

pub fn nodeMainToken(self: *const Ast, index: Node.Index) TokenIndex {
    return self.nodes.items(.main_token)[@intCast(@backingInt(index))];
}

pub fn nodeRange(self: *const Ast, index: Node.Index) SourceRange {
    if (index == .root) return .{ .start = 0, .end = self.source.len };
    return .{ .start = self.nodeStart(index), .end = self.nodeEnd(index) };
}

fn nodeStart(self: *const Ast, index: Node.Index) usize {
    return switch (self.nodeData(index)) {
        .declaration => |declaration| self.tokenStart(declaration.lhs),
        .negation,
        .map,
        .boolean_literal,
        .char_literal,
        .number_literal,
        .string_literal,
        .atom_literal,
        .identifier,
        .array,
        .group,
        => self.tokenStart(self.nodeMainToken(index)),
        inline .bool_or, .bool_and, .equal, .equal_equal, .add, .sub, .mul, .div => |binary| self.nodeStart(binary.lhs),
        .field_access => |field| self.nodeStart(field.parent),
        .apply => |application| self.nodeStart(application.func),
    };
}

fn nodeEnd(self: *const Ast, index: Node.Index) usize {
    return switch (self.nodeData(index)) {
        .map => |map| self.tokenEnd(map[1]),
        .declaration => |declaration| self.nodeEnd(declaration.rhs),
        .negation => |operand| self.nodeEnd(operand),
        .boolean_literal, .char_literal, .number_literal, .string_literal, .identifier => self.tokenEnd(self.nodeMainToken(index)),
        .atom_literal => |name| self.tokenEnd(name),
        .array => |array| self.tokenEnd(array[1]),
        .group => |group| self.tokenEnd(group[1]),
        inline .bool_or, .bool_and, .equal, .equal_equal, .add, .sub, .mul, .div => |binary| self.nodeEnd(binary.rhs),
        .field_access => |field| self.tokenEnd(field.child),
        .apply => |application| self.nodeEnd(application.arg),
    };
}

pub fn deinit(self: *Ast, gpa: Allocator) Allocator.Error!void {
    self.tokens.deinit(gpa);
    gpa.free(self.errors);
    self.nodes.deinit(gpa);
}

source: [:0]const u8,
tokens: Ast.TokenList.Slice,

errors: []Error,
nodes: NodeList.Slice,

pub fn format(ast: *const Ast, writer: *Writer) Writer.Error!void {
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
        .boolean_literal, .char_literal, .number_literal, .string_literal, .identifier => {
            try writeTextTokenLabel(ast, writer, ast.nodes.items(.main_token)[node_i]);
        },
        .atom_literal => |name| try writeTextTokenLabel(ast, writer, name),
        .field_access => |field| try writeTextTokenLabel(ast, writer, field.child),
        else => {},
    }

    switch (data) {
        .map => |m| {
            const declarations, _ = m;
            if (declarations.len != 0) {
                if (depth != 0) try writer.writeByte('{');
                try writer.writeByte('\n');
                for (declarations, 0..) |declaration, i| {
                    try writeTextNode(ast, writer, declaration, depth + 1, i + 1 < declarations.len);
                }
                if (depth != 0) try writer.writeByte('}');
            }
        },
        .declaration => |declaration| {
            try writer.writeByte('\n');
            try writeTextNode(ast, writer, declaration.rhs, depth + 1, false);
        },
        .negation => |operand| {
            try writer.writeByte('\n');
            try writeTextNode(ast, writer, operand, depth + 1, false);
        },
        .array => |array| {
            const items, _ = array;
            for (items) |item| {
                try writer.writeByte('\n');
                try writeTextNode(ast, writer, item.value, depth + 1, false);
            }
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
        .boolean_literal, .char_literal, .number_literal, .string_literal, .atom_literal, .identifier => {},
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
    try output.writer.print("{f}", .{ast});

    try std.testing.expectEqualStrings(
        \\(map
        \\  (declaration "value"
        \\    (add
        \\      (identifier "a")
        \\      (number_literal "2"))))
        \\
    , output.written());
}
