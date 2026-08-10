const std = @import("std");
const Writer = std.Io.Writer;

const Ast = @import("Ast.zig");

const indent_width = 2;

pub fn render(ast: *const Ast, writer: *Writer) Writer.Error!void {
    std.debug.assert(ast.errors.len == 0);

    var r: Render = .{
        .ast = ast,
        .writer = writer,
    };
    try r.renderRoot();
}

const Space = enum {
    none,
    space,
    newline,
};

const Render = struct {
    ast: *const Ast,
    writer: *Writer,
    source_cursor: usize = 0,
    pending_space: Space = .none,
    indent: usize = 0,
    line_start: bool = true,
    wrote_anything: bool = false,

    fn renderRoot(r: *Render) Writer.Error!void {
        for (r.ast.nodeData(.root).map) |declaration| {
            _ = try r.renderNode(declaration, .newline);
        }
        try r.renderGap(r.ast.source.len);
    }

    fn renderNode(r: *Render, index: Ast.Node.Index, space: Space) Writer.Error!Ast.TokenIndex {
        const data = r.ast.nodeData(index);
        switch (data) {
            .map => |declarations| {
                var next_token = r.ast.nodeMainToken(index);
                try r.renderToken(next_token, .newline);
                r.indent += 1;
                for (declarations) |declaration| {
                    next_token = try r.renderNode(declaration, .newline);
                }

                const r_brace = blk: {
                    var token = next_token;
                    while (switch (r.ast.tokenTag(token)) {
                        .nl, .semicolon => true,
                        else => false,
                    }) token += 1;
                    break :blk token;
                };
                std.debug.assert(r.ast.tokenTag(r_brace) == .r_brace);
                // Comments before the closing brace belong to the map body and
                // therefore use the body's indentation.
                try r.prepareToken(r_brace);
                r.indent -= 1;
                try r.writePreparedToken(r_brace, space);
                return r_brace + 1;
            },
            .declaration => |declaration| {
                _ = try r.renderToken(declaration.lhs, .space);
                _ = try r.renderToken(declaration.lhs + 1, .space); // '='
                return try r.renderNode(declaration.rhs, space);
            },
            .negation => |operand| {
                _ = try r.renderToken(r.ast.nodeMainToken(index), .none);
                return try r.renderNode(operand, space);
            },
            .char_literal, .number_literal, .string_literal, .identifier => {
                const token = r.ast.nodeMainToken(index);
                try r.renderToken(token, space);
                return token + 1;
            },
            .group => |group| {
                try r.renderToken(r.ast.nodeMainToken(index), .none);
                _ = try r.renderNode(group[0], .none);
                try r.renderToken(group[1], space);
                return group[1] + 1;
            },
            inline .bool_or, .bool_and, .equal, .equal_equal, .add, .sub, .mul, .div => |binary| {
                _ = try r.renderNode(binary.lhs, .space);
                try r.renderToken(r.ast.nodeMainToken(index), .space);
                return try r.renderNode(binary.rhs, space);
            },
            .field_access => |field| {
                _ = try r.renderNode(field.parent, .none);
                _ = try r.renderToken(r.ast.nodeMainToken(index), .none);
                try r.renderToken(field.child, space);
                return field.child + 1;
            },
            .apply => |apply| {
                _ = try r.renderNode(apply.func, .space);
                return try r.renderNode(apply.arg, space);
            },
        }
    }

    fn renderToken(r: *Render, token_index: Ast.TokenIndex, space: Space) Writer.Error!void {
        try r.prepareToken(token_index);
        try r.writePreparedToken(token_index, space);
    }

    fn prepareToken(r: *Render, token_index: Ast.TokenIndex) Writer.Error!void {
        const token_start = r.ast.tokenStart(token_index);
        std.debug.assert(token_start >= r.source_cursor);
        try r.renderGap(token_start);
    }

    fn writePreparedToken(r: *Render, token_index: Ast.TokenIndex, space: Space) Writer.Error!void {
        const token_start = r.ast.tokenStart(token_index);
        std.debug.assert(r.source_cursor == token_start);

        const lexeme = r.ast.tokenSlice(token_index);
        try r.writeAll(lexeme);
        r.source_cursor = token_start + lexeme.len;
        r.pending_space = space;
    }

    /// Canonicalize whitespace while preserving every line comment in the
    /// source gap between two AST tokens. Ordinary comments intentionally do
    /// not need tokens of their own; this is the same model used by zig fmt.
    fn renderGap(r: *Render, end: usize) Writer.Error!void {
        std.debug.assert(end >= r.source_cursor);
        const source = r.ast.source;
        var index = r.source_cursor;
        var found_comment = false;

        while (std.mem.find(u8, source[index..end], "//")) |offset| {
            const comment_start = index + offset;
            const before_comment = source[index..comment_start];
            const breaks_before = lineBreakCount(before_comment);
            const same_line = !r.line_start and breaks_before == 0;

            if (same_line) {
                try r.writer.writeByte(' ');
            } else {
                try r.ensureNewline();
                const blank_line_threshold: usize = if (found_comment) 1 else 2;
                if (r.wrote_anything and breaks_before >= blank_line_threshold) {
                    try r.insertBlankLine();
                }
            }

            const comment_end = findLineEnd(source, comment_start, end);
            const comment = std.mem.trimEnd(
                u8,
                source[comment_start..comment_end],
                &std.ascii.whitespace,
            );
            try r.writeAll(comment);
            try r.ensureNewline();

            index = skipLineEnding(source, comment_end, end);
            found_comment = true;
        }

        const remaining = source[index..end];
        if (found_comment) {
            r.pending_space = .none;
            // Since the terminating newline of the final comment was already
            // consumed, one further source newline represents an empty line.
            if (end != source.len and lineBreakCount(remaining) != 0) {
                try r.insertBlankLine();
            }
        } else {
            const wanted_space = r.pending_space;
            try r.applyPendingSpace();
            if (wanted_space == .newline and
                end != source.len and
                lineBreakCount(remaining) >= 2)
            {
                try r.insertBlankLine();
            }
        }

        r.source_cursor = end;
    }

    fn applyPendingSpace(r: *Render) Writer.Error!void {
        const space = r.pending_space;
        r.pending_space = .none;
        switch (space) {
            .none => {},
            .space => if (!r.line_start) try r.writer.writeByte(' '),
            .newline => try r.ensureNewline(),
        }
    }

    fn writeAll(r: *Render, bytes: []const u8) Writer.Error!void {
        if (bytes.len == 0) return;
        if (r.line_start) {
            try r.writer.splatByteAll(' ', r.indent * indent_width);
            r.line_start = false;
        }
        try r.writer.writeAll(bytes);
        r.wrote_anything = true;
    }

    fn ensureNewline(r: *Render) Writer.Error!void {
        if (r.line_start) return;
        try r.writer.writeByte('\n');
        r.line_start = true;
        r.wrote_anything = true;
    }

    fn insertBlankLine(r: *Render) Writer.Error!void {
        if (!r.wrote_anything) return;
        try r.ensureNewline();
        try r.writer.writeByte('\n');
        r.line_start = true;
    }
};

fn findLineEnd(source: []const u8, start: usize, limit: usize) usize {
    var index = start;
    while (index < limit) : (index += 1) {
        if (source[index] == '\n' or source[index] == '\r') return index;
    }
    return limit;
}

fn skipLineEnding(source: []const u8, start: usize, limit: usize) usize {
    if (start == limit) return start;
    if (source[start] == '\r' and start + 1 < limit and source[start + 1] == '\n') {
        return start + 2;
    }
    return start + 1;
}

fn lineBreakCount(bytes: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        switch (bytes[index]) {
            '\n' => count += 1,
            '\r' => {
                count += 1;
                if (index + 1 < bytes.len and bytes[index + 1] == '\n') index += 1;
            },
            else => {},
        }
    }
    return count;
}

test "canonical formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(
        std.testing.allocator,
        arena.allocator(),
        "test={first=1;second=test.first*2;}",
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try render(&ast, &output.writer);

    try std.testing.expectEqualStrings(
        \\test = {
        \\  first = 1
        \\  second = test.first * 2
        \\}
        \\
    , output.written());
}

test "comments are recovered from source gaps" {
    const source =
        \\// header
        \\a=1;// one
        \\b={// map
        \\// child
        \\c=2
        \\// end
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(), source);
    defer ast.deinit(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try render(&ast, &output.writer);

    try std.testing.expectEqualStrings(
        \\// header
        \\a = 1 // one
        \\b = { // map
        \\  // child
        \\  c = 2
        \\  // end
        \\}
        \\
    , output.written());
}

test "formatting is idempotent" {
    const source =
        \\// heading
        \\value=-(measure sample)+fallback
    ;

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    var first_ast = try @import("Parse.zig").parse(std.testing.allocator, first_arena.allocator(), source);
    defer first_ast.deinit(std.testing.allocator) catch unreachable;

    var first_output: Writer.Allocating = .init(std.testing.allocator);
    defer first_output.deinit();
    try render(&first_ast, &first_output.writer);

    const formatted = try std.testing.allocator.dupeSentinel(u8, first_output.written(), 0);
    defer std.testing.allocator.free(formatted);

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    var second_ast = try @import("Parse.zig").parse(std.testing.allocator, second_arena.allocator(), formatted);
    defer second_ast.deinit(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), second_ast.errors.len);

    var second_output: Writer.Allocating = .init(std.testing.allocator);
    defer second_output.deinit();
    try render(&second_ast, &second_output.writer);

    try std.testing.expectEqualStrings(first_output.written(), second_output.written());
}
