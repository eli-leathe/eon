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

pub fn deinit(self: *Ast, gpa: Allocator) Allocator.Error!void {
    self.tokens.deinit(gpa);
    gpa.free(self.errors);
    self.nodes.deinit(gpa);
}

source: [:0]const u8,
tokens: Ast.TokenList.Slice,

errors: []Error,
nodes: NodeList.Slice,
