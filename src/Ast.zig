const std = @import("std");
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
pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: u32,
});

pub const Node = struct {
    data: Data,
    main_token: TokenIndex,

    pub const Tag = @typeInfo(Data).@"union".tag_type.?;
    pub const Data = union(enum) {
        map: []Index,
        declaration: struct { lhs: TokenIndex, rhs: Index },
        negation: Index,
        char_literal,
        number_literal,
        string_literal,
        identifier,
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

pub fn deinit(self: *Ast, gpa: Allocator) Allocator.Error!void {
    self.tokens.deinit(gpa);
    gpa.free(self.errors);
    self.nodes.deinit(gpa);
}

source: [:0]const u8,
tokens: Ast.TokenList.Slice,

errors: []Error,
nodes: NodeList.Slice,
