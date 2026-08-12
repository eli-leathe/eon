const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const TokenIndex = Ast.TokenIndex;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const Parse = @This();

pub const Error = error{ParseError} || Allocator.Error;

gpa: Allocator,
arena: Allocator,
source: []const u8,
tokens: Ast.TokenList.Slice,
tok_i: TokenIndex,

errors: std.ArrayList(Ast.Error),
nodes: Ast.NodeList,

scratch: std.ArrayListUnmanaged(Ast.Node.Index),

fn tokenTag(p: *const Parse, token_index: TokenIndex) Token.Tag {
    return p.tokens.items(.tag)[token_index];
}

fn expectToken(p: *Parse, tag: Token.Tag) Error!TokenIndex {
    if (p.tokenTag(p.tok_i) != tag) try p.failExpected(tag);
    return p.nextToken();
}
fn eatToken(p: *Parse, tag: Token.Tag) ?TokenIndex {
    return if (p.tokenTag(p.tok_i) == tag) p.nextToken() else null;
}
fn nextToken(p: *Parse) TokenIndex {
    const result = p.tok_i;
    p.tok_i += 1;
    return result;
}
fn addNode(p: *Parse, elem: Ast.Node) Allocator.Error!Ast.Node.Index {
    const result: Ast.Node.Index = @fromBackingInt(@intCast(p.nodes.len));
    try p.nodes.append(p.gpa, elem);
    return result;
}

fn failExpected(p: *Parse, expected: Token.Tag) Error!noreturn {
    return p.fail(.{ .expected_token = expected });
}
fn fail(p: *Parse, data: Ast.Error.Data) Error!noreturn {
    return p.failAt(p.tok_i, data);
}
fn failAt(p: *Parse, token: TokenIndex, data: Ast.Error.Data) Error!noreturn {
    @branchHint(.cold);
    try p.errors.append(p.gpa, .{ .token = token, .data = data });
    return error.ParseError;
}
fn parseRoot(p: *Parse) Error!void {
    p.nodes.appendAssumeCapacity(.{
        .data = .{ .map = undefined },
        .main_token = 0,
    });

    const defs = try p.parseDeclarations();

    if (p.tokenTag(p.tok_i) != .eof) try p.failExpected(.eof);
    p.nodes.items(.data)[0] = .{ .map = .{ defs, p.tok_i } };
}

const OperInfo = struct {
    prec: i8,
    tag: Ast.Node.Tag,
    assoc: enum { left, none } = .left,
};

const operTable = std.enums.directEnumArrayDefault(Token.Tag, OperInfo, .{ .prec = -1, .tag = undefined }, 0, .{
    .keyword_or = .{ .prec = 10, .tag = .bool_or },

    .keyword_and = .{ .prec = 20, .tag = .bool_and },

    .equal_equal = .{ .prec = 30, .tag = .equal_equal, .assoc = .none },

    .plus = .{ .prec = 60, .tag = .add },
    .minus = .{ .prec = 60, .tag = .sub },

    .asterisk = .{ .prec = 70, .tag = .mul },
    .slash = .{ .prec = 70, .tag = .div },
});

fn parseExprPrecedence(p: *Parse, min_prec: i32) Error!?Ast.Node.Index {
    std.debug.assert(min_prec >= 0);
    var node = try p.parsePrefixExpr() orelse return null;

    var banned_prec: i8 = -1;
    while (true) {
        const tok_tag = p.tokenTag(p.tok_i);
        const info = operTable[@as(usize, @intCast(@backingInt(tok_tag)))];
        if (info.prec < min_prec) {
            break;
        }
        if (info.prec == banned_prec) try p.fail(.chained_comparison_operators);

        const oper_token = p.nextToken();

        const rhs = try p.parseExprPrecedence(info.prec + 1) orelse {
            try p.fail(.expected_expr);
            return node;
        };

        node = switch (info.tag) {
            inline .bool_or, .bool_and, .equal_equal, .add, .sub, .mul, .div => |tag| try p.addNode(.{
                .main_token = oper_token,
                .data = @unionInit(Ast.Node.Data, @tagName(tag), .{ .lhs = node, .rhs = rhs }),
            }),
            else => unreachable,
        };

        if (info.assoc == .none) {
            banned_prec = info.prec;
        }
    }
    return node;
}
fn parsePrefixExpr(p: *Parse) Error!?Ast.Node.Index {
    return switch (p.tokenTag(p.tok_i)) {
        .minus => {
            const minus_token = p.nextToken();
            const operand = try p.expectPrefixExpr();
            const operand_i: usize = @intCast(@backingInt(operand));
            switch (p.nodes.items(.data)[operand_i]) {
                .apply => try p.failAt(minus_token, .ambiguous_negation),
                else => {},
            }
            return try p.addNode(.{
                .main_token = minus_token,
                .data = .{ .negation = operand },
            });
        },
        else => return p.parsePrimaryExpr(),
    };
}

fn startsApplicationArg(tag: Token.Tag) bool {
    return switch (tag) {
        .keyword_true, .keyword_false, .char_literal, .number_literal, .string_literal, .identifier, .l_paren, .l_bracket => true,
        else => false,
    };
}

fn parsePrimaryExpr(p: *Parse) !?Ast.Node.Index {
    var func = try p.parseSuffixExpr() orelse return null;

    while (startsApplicationArg(p.tokenTag(p.tok_i))) {
        const arg_token = p.tok_i;
        const arg = (try p.parseSuffixExpr()).?;

        func = try p.addNode(.{
            // Application has no explicit operator token.
            .main_token = arg_token,
            .data = .{ .apply = .{
                .func = func,
                .arg = arg,
            } },
        });
    }

    return func;
}
fn parseSuffixExpr(p: *Parse) !?Ast.Node.Index {
    var res = try p.parsePrimaryTypeExpr() orelse return null;
    while (try p.parseSuffixOp(res)) |suffix_op| {
        res = suffix_op;
    }
    return res;
}

fn parseSuffixOp(p: *Parse, lhs: Ast.Node.Index) !?Ast.Node.Index {
    switch (p.tokenTag(p.tok_i)) {
        .period => switch (p.tokenTag(p.tok_i + 1)) {
            .identifier => return try p.addNode(.{
                .main_token = p.nextToken(),
                .data = .{ .field_access = .{ .parent = lhs, .child = p.nextToken() } },
            }),
            else => {
                p.tok_i += 1;
                try p.fail(.expected_suffix_op);
                return null;
            },
        },
        else => return null,
    }
}
fn expectArray(p: *Parse) Error!Ast.Node.Index {
    const l_bracket = try p.expectToken(.l_bracket);
    var items: std.ArrayList(Ast.Node.ArrayItem) = .empty;
    defer items.deinit(p.gpa);

    while (p.eatToken(.nl) != null) {}
    while (p.tokenTag(p.tok_i) != .r_bracket) {
        const value = try p.expectExpr();
        const comma = p.eatToken(.comma);
        try items.append(p.gpa, .{ .value = value, .comma = comma });

        while (p.eatToken(.nl) != null) {}
        if (comma == null) break;
    }

    return try p.addNode(.{
        .main_token = l_bracket,
        .data = .{ .array = .{
            try p.arena.dupe(Ast.Node.ArrayItem, items.items),
            try p.expectToken(.r_bracket),
        } },
    });
}

fn parsePrimaryTypeExpr(p: *Parse) !?Ast.Node.Index {
    switch (p.tokenTag(p.tok_i)) {
        .keyword_true, .keyword_false => return try p.addNode(.{
            .main_token = p.nextToken(),
            .data = .boolean_literal,
        }),
        .char_literal => return try p.addNode(.{ .main_token = p.nextToken(), .data = .char_literal }),
        .number_literal => return try p.addNode(.{ .main_token = p.nextToken(), .data = .number_literal }),
        .string_literal => return try p.addNode(.{ .main_token = p.nextToken(), .data = .string_literal }),
        .period => {
            const period = p.nextToken();
            return try p.addNode(.{
                .main_token = period,
                .data = .{ .atom_literal = try p.expectToken(.identifier) },
            });
        },
        .identifier => return try p.addNode(.{ .main_token = p.nextToken(), .data = .identifier }),
        .l_bracket => return try p.expectArray(),
        .l_paren => return try p.addNode(.{
            .main_token = p.nextToken(),
            .data = .{ .group = .{
                try p.expectExpr(),
                try p.expectToken(.r_paren),
            } },
        }),
        else => return null,
    }
}

fn expectPrefixExpr(p: *Parse) Error!Ast.Node.Index {
    return try p.parsePrefixExpr() orelse try p.fail(.expected_prefix_expr);
}

fn expectExpr(p: *Parse) Error!Ast.Node.Index {
    return try p.parseExprPrecedence(0) orelse try p.fail(.expected_expr);
}

fn expectMap(p: *Parse) Error!Ast.Node.Index {
    const map_tok = p.tok_i;
    _ = try p.expectToken(.l_brace);

    return try p.addNode(.{ .main_token = map_tok, .data = .{ .map = .{
        try p.parseDeclarations(),
        try p.expectToken(.r_brace),
    } } });
}
fn expectDeclaration(p: *Parse) Error!Ast.Node.Index {
    const id = try p.expectToken(.identifier);
    _ = try p.expectToken(.equal);
    const expr = switch (p.tokenTag(p.tok_i)) {
        .l_brace => try p.expectMap(),
        else => try p.expectExpr(),
    };

    return try p.addNode(.{ .data = .{ .declaration = .{ .lhs = id, .rhs = expr } }, .main_token = id });
}

fn parseDeclarations(p: *Parse) Error![]Ast.Node.Index {
    var defs: std.ArrayList(Ast.Node.Index) = .empty;
    defer defs.deinit(p.gpa);

    while (p.eatToken(.nl) orelse p.eatToken(.semicolon) != null) {}
    while (true) {
        switch (p.tokenTag(p.tok_i)) {
            .identifier => try defs.append(p.gpa, try p.expectDeclaration()),
            else => break,
        }

        switch (p.tokenTag(p.tok_i)) {
            .eof, .r_brace => break,
            .nl, .semicolon => while (p.eatToken(.nl) orelse p.eatToken(.semicolon) != null) {},
            else => try p.fail(.expected_declaration_separator),
        }
    }

    return p.arena.dupe(Ast.Node.Index, defs.items);
}

pub fn parse(gpa: Allocator, arena: Allocator, source: [:0]const u8) Allocator.Error!Ast {
    var tokens = Ast.TokenList{};
    defer tokens.deinit(gpa);

    try tokens.ensureTotalCapacity(gpa, source.len / 8);

    var tokenizer = Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(gpa, .{ .tag = token.tag, .start = token.loc.start });
        if (token.tag == .eof) break;
    }
    var token_slices = tokens.toOwnedSlice();
    errdefer token_slices.deinit(gpa);
    return parseTokens(gpa, arena, source, token_slices);
}

pub fn parseTokens(
    gpa: Allocator,
    arena: Allocator,
    source: [:0]const u8,
    tokens: Ast.TokenList.Slice,
) Allocator.Error!Ast {
    var parser: Parse = .{
        .source = source,
        .gpa = gpa,
        .arena = arena,
        .tokens = tokens,
        .errors = .empty,
        .nodes = .empty,
        .scratch = .empty,
        .tok_i = 0,
    };
    defer parser.errors.deinit(gpa);
    defer parser.nodes.deinit(gpa);
    defer parser.scratch.deinit(gpa);

    const estimated_node_count = (tokens.len + 2) / 2;
    try parser.nodes.ensureTotalCapacity(gpa, estimated_node_count);

    parser.parseRoot() catch |err| switch (err) {
        error.ParseError => std.debug.assert(parser.errors.items.len > 0),
        else => |r| return r,
    };
    try parser.errors.shrinkToLen(gpa);

    return .{
        .source = source,
        .tokens = tokens,
        .nodes = parser.nodes.toOwnedSlice(),
        .errors = parser.errors.toOwnedSliceAssert(),
    };
}
