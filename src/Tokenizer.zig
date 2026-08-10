const std = @import("std");

const Tokenizer = @This();
pub const Token = struct {
    tag: Tag,
    loc: Loc,
    pub const Loc = struct {
        start: u32 = 0,
        end: u32 = 0,
    };

    pub const Tag = enum(u8) {
        invalid,
        nl,
        whitespace,
        eof,
        identifier,

        string_literal,
        char_literal,
        number_literal,

        equal,
        equal_equal,
        plus,
        minus,
        asterisk,
        colon,
        period,
        semicolon,
        l_paren,
        r_paren,
        l_brace,
        r_bracket,
        l_bracket,
        r_brace,
        slash,

        keyword_and,
        keyword_or,
        keyword_not,
        keyword_true,
        keyword_false,
        keyword_if,

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .eof => "",
                .equal => "=",
                .equal_equal => "==",
                .plus => "+",
                .minus => "-",
                .asterisk => "*",
                .colon => ":",
                .period => ".",
                .semicolon => ";",
                .l_paren => "(",
                .r_paren => ")",
                .l_brace => "{",
                .r_bracket => "]",
                .l_bracket => "[",
                .r_brace => "}",
                .slash => "/",
                .keyword_and => "and",
                .keyword_or => "or",
                .keyword_not => "not",
                .keyword_true => "true",
                .keyword_false => "false",
                .keyword_if => "if",
                .invalid,
                .nl,
                .whitespace,
                .identifier,
                .string_literal,
                .char_literal,
                .number_literal,
                => null,
            };
        }
    };
    const all_kws = std.StaticStringMap(Tag).initComptime(.{
        .{ "and", .keyword_and },
        .{ "or", .keyword_or },
        .{ "not", .keyword_not },
        .{ "true", .keyword_true },
        .{ "false", .keyword_false },
        .{ "if", .keyword_if },
    });

    pub fn getKeyword(str: []const u8) ?Token.Tag {
        return all_kws.get(str);
    }
};

buf: [:0]const u8,
index: u32 = 0,

pub fn init(buf: [:0]const u8) Tokenizer {
    return .{ .buf = buf };
}
pub fn next(self: *Tokenizer) Token {
    const State = enum {
        start,
        string_literal,
        string_literal_backslash,
        char_literal,
        char_literal_backslash,
        identifier,
        @"@",
        equal,
        slash,
        line_comment,
        int,
        invalid,
        int_exponent,
        int_period,
        float,
        float_exponent,
    };
    var result: Token = .{
        .tag = undefined,
        .loc = .{
            .start = self.index,
            .end = undefined,
        },
    };

    state: switch (State.start) {
        .start => switch (self.buf[self.index]) {
            0 => {
                if (self.index == self.buf.len) {
                    result.tag = .eof;
                    result.loc.end = self.index;
                    return result;
                } else {
                    continue :state .invalid;
                }
            },
            ' ', '\t' => {
                self.index += 1;
                result.loc.start = self.index;
                continue :state .start;
            },
            '\n' => {
                result.tag = .nl;
                self.index += 1;
            },
            '\r' => {
                result.tag = .nl;
                self.index += 1;
                if (self.buf[self.index] == '\n') self.index += 1;
            },
            '"' => {
                result.tag = .string_literal;
                continue :state .string_literal;
            },
            '\'' => {
                result.tag = .char_literal;
                continue :state .char_literal;
            },
            'a'...'z', 'A'...'Z', '_' => {
                result.tag = .identifier;
                continue :state .identifier;
            },
            '@' => continue :state .@"@",
            '0'...'9' => {
                result.tag = .number_literal;
                self.index += 1;
                continue :state .int;
            },
            '=' => {
                continue :state .equal;
            },
            '.' => {
                result.tag = .period;
                self.index += 1;
            },
            '(' => {
                result.tag = .l_paren;
                self.index += 1;
            },
            ')' => {
                result.tag = .r_paren;
                self.index += 1;
            },
            '[' => {
                result.tag = .l_bracket;
                self.index += 1;
            },
            ']' => {
                result.tag = .r_bracket;
                self.index += 1;
            },
            '{' => {
                result.tag = .l_brace;
                self.index += 1;
            },
            '}' => {
                result.tag = .r_brace;
                self.index += 1;
            },
            ':' => {
                result.tag = .colon;
                self.index += 1;
            },
            ';' => {
                result.tag = .semicolon;
                self.index += 1;
            },
            '*' => {
                result.tag = .asterisk;
                self.index += 1;
            },
            '+' => {
                result.tag = .plus;
                self.index += 1;
            },
            '-' => {
                result.tag = .minus;
                self.index += 1;
            },
            '/' => continue :state .slash,
            else => continue :state .invalid,
        },
        .invalid => {
            self.index += 1;
            switch (self.buf[self.index]) {
                0 => if (self.index == self.buf.len) {
                    result.tag = .invalid;
                } else {
                    continue :state .invalid;
                },
                '\n' => result.tag = .invalid,
                else => continue :state .invalid,
            }
        },
        .string_literal => {
            self.index += 1;
            switch (self.buf[self.index]) {
                0 => {
                    if (self.index != self.buf.len) {
                        continue :state .invalid;
                    } else {
                        result.tag = .invalid;
                    }
                },
                '\n' => result.tag = .invalid,
                '\\' => continue :state .string_literal_backslash,
                '"' => self.index += 1,
                0x01...0x09, 0x0b...0x1f, 0x7f => {
                    continue :state .invalid;
                },
                else => continue :state .string_literal,
            }
        },
        .string_literal_backslash => {
            self.index += 1;
            switch (self.buf[self.index]) {
                0, '\n' => result.tag = .invalid,
                0x01...0x09, 0x0b...0x1f, 0x7f => continue :state .invalid,
                else => continue :state .string_literal,
            }
        },
        .char_literal => {
            self.index += 1;
            switch (self.buf[self.index]) {
                0 => {
                    if (self.index != self.buf.len) {
                        continue :state .invalid;
                    } else {
                        result.tag = .invalid;
                    }
                },
                '\n' => result.tag = .invalid,
                '\\' => continue :state .char_literal_backslash,
                '\'' => self.index += 1,
                0x01...0x09, 0x0b...0x1f, 0x7f => {
                    continue :state .invalid;
                },
                else => continue :state .char_literal,
            }
        },
        .char_literal_backslash => {
            self.index += 1;
            switch (self.buf[self.index]) {
                0, '\n' => result.tag = .invalid,
                0x01...0x09, 0x0b...0x1f, 0x7f => continue :state .invalid,
                else => continue :state .char_literal,
            }
        },
        .identifier => {
            self.index += 1;
            switch (self.buf[self.index]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
                else => if (Token.getKeyword(self.buf[result.loc.start..self.index])) |tag| {
                    result.tag = tag;
                },
            }
        },
        .@"@" => {
            self.index += 1;
            switch (self.buf[self.index]) {
                0, '\n' => result.tag = .invalid,
                '"' => {
                    result.tag = .identifier;
                    continue :state .string_literal;
                },
                else => continue :state .invalid,
            }
        },
        .equal => {
            self.index += 1;
            switch (self.buf[self.index]) {
                '=' => {
                    result.tag = .equal_equal;
                    self.index += 1;
                },
                else => result.tag = .equal,
            }
        },

        .slash => {
            self.index += 1;
            switch (self.buf[self.index]) {
                '/' => continue :state .line_comment,
                else => result.tag = .slash,
            }
        },
        .line_comment => {
            self.index += 1;
            switch (self.buf[self.index]) {
                0 => {
                    if (self.index != self.buf.len) {
                        continue :state .invalid;
                    } else return .{
                        .tag = .eof,
                        .loc = .{
                            .start = self.index,
                            .end = self.index,
                        },
                    };
                },
                '\n' => {
                    result.tag = .nl;
                    result.loc.start = self.index;
                    self.index += 1;
                },
                '\r' => {
                    result.tag = .nl;
                    result.loc.start = self.index;
                    self.index += 1;
                    if (self.buf[self.index] == '\n') self.index += 1;
                },
                else => continue :state .line_comment,
            }
        },
        .int => switch (self.buf[self.index]) {
            '.' => continue :state .int_period,
            '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                self.index += 1;
                continue :state .int;
            },
            'e', 'E', 'p', 'P' => {
                continue :state .int_exponent;
            },
            else => {},
        },
        .int_exponent => {
            self.index += 1;
            switch (self.buf[self.index]) {
                '-', '+' => {
                    self.index += 1;
                    continue :state .float;
                },
                else => continue :state .int,
            }
        },
        .int_period => {
            self.index += 1;
            switch (self.buf[self.index]) {
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    self.index += 1;
                    continue :state .float;
                },
                'e', 'E', 'p', 'P' => {
                    continue :state .float_exponent;
                },
                else => self.index -= 1,
            }
        },
        .float => switch (self.buf[self.index]) {
            '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                self.index += 1;
                continue :state .float;
            },
            'e', 'E', 'p', 'P' => {
                continue :state .float_exponent;
            },
            else => {},
        },
        .float_exponent => {
            self.index += 1;
            switch (self.buf[self.index]) {
                '-', '+' => {
                    self.index += 1;
                    continue :state .float;
                },
                else => continue :state .float,
            }
        },
    }

    result.loc.end = self.index;
    return result;
}

test "tokenize" {
    try expectTokens(
        \\if x = 4.2{
        \\ }//this is a comment
        \\and or not
        \\@"and" @"or" @"not" @"true" @"false" @"if"
        \\@"quote\"name" "line\n\"two\"\\"
    , &.{
        .keyword_if,
        .identifier,
        .equal,
        .number_literal,
        .l_brace,
        .nl,
        .r_brace,
        .nl,
        .keyword_and,
        .keyword_or,
        .keyword_not,
        .nl,
        .identifier,
        .identifier,
        .identifier,
        .identifier,
        .identifier,
        .identifier,
        .nl,
        .identifier,
        .string_literal,
    });
}

fn expectTokens(contents: [:0]const u8, expected_tokens: []const Token.Tag) !void {
    var tokenizer: Tokenizer = .init(contents);
    var i: usize = 0;
    while (i < expected_tokens.len) {
        const token = tokenizer.next();
        const expected_token_id = expected_tokens[i];
        i += 1;
        if (!std.meta.eql(token.tag, expected_token_id)) {
            std.debug.print("expected {s}, found {s}\n", .{ @tagName(expected_token_id), @tagName(token.tag) });
            return error.TokensDoNotEqual;
        }
    }
    const last_token = tokenizer.next();
    try std.testing.expect(last_token.tag == .eof);
}
