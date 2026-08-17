const std = @import("std");
const Writer = std.Io.Writer;

const Ast = @import("Ast.zig");
const Syntax = @import("Syntax.zig");
const Tree = @import("Tree.zig");

const indent_width = 2;

pub const RenderError = Writer.Error || error{UnsupportedVirtualNode};

pub fn render(ast: *const Ast, writer: *Writer) Writer.Error!void {
    var parsed = Tree.Parsed{ .ast = ast };
    renderTree(parsed.reader(), writer) catch |err| switch (err) {
        error.UnsupportedVirtualNode => unreachable,
        else => |write_error| return write_error,
    };
}

pub fn renderTree(tree: Tree.Reader, writer: *Writer) RenderError!void {
    var renderer = Render{ .tree = tree, .writer = writer };
    try renderer.renderRoot();
}

pub fn renderMerged(tree: *const Tree.Merge, writer: *Writer) RenderError!void {
    return renderTree(tree.reader(), writer);
}

const Space = enum {
    none,
    space,
    newline,
};

const Render = struct {
    tree: Tree.Reader,
    writer: *Writer,
    source_cursor: usize = 0,
    pending_space: Space = .none,
    indent: usize = 0,
    line_start: bool = true,
    wrote_anything: bool = false,

    fn renderRoot(r: *Render) RenderError!void {
        const root = r.tree.root();
        std.debug.assert(root.kind() == .root);
        for (0..root.childCount()) |i| try r.renderNode(root.child(i), .newline);
        try r.renderGap(if (r.tree.source()) |source| source.len else 0);
    }

    fn renderNode(r: *Render, node: Tree.Node, space: Space) RenderError!void {
        if (node.replacementRange()) |range| {
            std.debug.assert(range.start >= r.source_cursor);
            try r.renderGap(range.start);
            try r.renderNodeBody(node, space);
            r.source_cursor = range.end;
            r.pending_space = space;
            return;
        }
        return r.renderNodeBody(node, space);
    }

    fn renderNodeBody(r: *Render, node: Tree.Node, space: Space) RenderError!void {
        switch (node.kind()) {
            .root => unreachable,
            .map => {
                const multiline = node.multiline();
                try r.renderTokenRequired(node, 0, if (multiline) .newline else if (node.childCount() == 0) .none else .space);

                if (multiline) r.indent += 1;
                for (0..node.childCount()) |i| {
                    const last = i + 1 == node.childCount();
                    try r.renderNode(node.child(i), if (multiline) .newline else if (last) .space else .none);
                    if (!multiline and !last) {
                        try r.writeAll(";");
                        r.pending_space = .space;
                    }
                }

                const closing = node.token(1).?;
                try r.prepareToken(closing);
                if (multiline) r.indent -= 1;
                try r.writePreparedToken(closing, space);
            },
            .declaration => {
                try r.renderTokenRequired(node, 0, .space);
                try r.renderTokenRequired(node, 1, .space);
                try r.renderNode(node.child(0), space);
            },
            .negation => {
                try r.renderTokenRequired(node, 0, .none);
                try r.renderNode(node.child(0), space);
            },
            .scalar, .identifier => try r.renderTokenRequired(node, 0, space),
            .atom => {
                try r.renderTokenRequired(node, 0, .none);
                try r.renderTokenRequired(node, 1, space);
            },
            .array => {
                const multiline = node.multiline();
                try r.renderTokenRequired(node, 0, if (multiline) .newline else .none);
                if (multiline) r.indent += 1;

                for (0..node.childCount()) |i| {
                    try r.renderNode(node.child(i), .none);
                    if (node.token(2 + i)) |comma|
                        try r.renderToken(comma, if (multiline) .newline else .space);
                }

                const closing = node.token(1).?;
                if (multiline) {
                    try r.prepareToken(closing);
                    r.indent -= 1;
                    try r.writePreparedToken(closing, space);
                } else {
                    try r.renderToken(closing, space);
                }
            },
            .group => {
                try r.renderTokenRequired(node, 0, .none);
                try r.renderNode(node.child(0), .none);
                try r.renderTokenRequired(node, 1, space);
            },
            .binary => {
                try r.renderNode(node.child(0), .space);
                try r.renderTokenRequired(node, 0, .space);
                try r.renderNode(node.child(1), space);
            },
            .field_access => {
                try r.renderNode(node.child(0), .none);
                try r.renderTokenRequired(node, 0, .none);
                try r.renderTokenRequired(node, 1, space);
            },
            .apply => {
                try r.renderNode(node.child(0), .space);
                try r.renderNode(node.child(1), space);
            },
        }
    }

    fn renderTokenRequired(r: *Render, node: Tree.Node, slot: usize, space: Space) RenderError!void {
        return r.renderToken(node.token(slot).?, space);
    }

    fn renderToken(r: *Render, token: Tree.Token, space: Space) RenderError!void {
        try r.prepareToken(token);
        try r.writePreparedToken(token, space);
    }

    fn prepareToken(r: *Render, token: Tree.Token) RenderError!void {
        if (token.range) |range| {
            std.debug.assert(range.start >= r.source_cursor);
            try r.renderGap(range.start);
        } else {
            try r.applyPendingSpace();
        }
    }

    fn writePreparedToken(r: *Render, token: Tree.Token, space: Space) RenderError!void {
        if (token.range) |range| std.debug.assert(r.source_cursor == range.start);
        switch (token.content) {
            .text => |text| try r.writeAll(text),
            .identifier => |identifier| {
                try r.beginDirectWrite();
                try Syntax.writeIdentifier(identifier, r.writer);
            },
            .value => |value| {
                switch (value) {
                    .function => return error.UnsupportedVirtualNode,
                    .number => |number| if (!std.math.isFinite(number)) return error.UnsupportedVirtualNode,
                    else => {},
                }
                try r.beginDirectWrite();
                try value.format(r.writer);
            },
        }
        if (token.range) |range| r.source_cursor = range.end;
        r.pending_space = space;
    }

    /// Canonicalize whitespace while preserving line comments supplied by a
    /// source-backed tree. Source-less trees simply apply pending whitespace.
    fn renderGap(r: *Render, end: usize) RenderError!void {
        const source = r.tree.source() orelse {
            try r.applyPendingSpace();
            return;
        };
        std.debug.assert(end >= r.source_cursor);
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
                if (r.wrote_anything and breaks_before >= blank_line_threshold) try r.insertBlankLine();
            }

            const comment_end = findLineEnd(source, comment_start, end);
            const comment = std.mem.trimEnd(u8, source[comment_start..comment_end], &std.ascii.whitespace);
            try r.writeAll(comment);
            try r.ensureNewline();

            index = skipLineEnding(source, comment_end, end);
            found_comment = true;
        }

        const remaining = source[index..end];
        if (found_comment) {
            r.pending_space = .none;
            if (end != source.len and lineBreakCount(remaining) != 0) try r.insertBlankLine();
        } else {
            const wanted_space = r.pending_space;
            try r.applyPendingSpace();
            if (wanted_space == .newline and end != source.len and lineBreakCount(remaining) >= 2)
                try r.insertBlankLine();
        }

        r.source_cursor = end;
    }

    fn applyPendingSpace(r: *Render) RenderError!void {
        const space = r.pending_space;
        r.pending_space = .none;
        switch (space) {
            .none => {},
            .space => if (!r.line_start) try r.writer.writeByte(' '),
            .newline => try r.ensureNewline(),
        }
    }

    fn beginDirectWrite(r: *Render) RenderError!void {
        if (r.line_start) {
            try r.writer.splatByteAll(' ', r.indent * indent_width);
            r.line_start = false;
        }
        r.wrote_anything = true;
    }

    fn writeAll(r: *Render, bytes: []const u8) RenderError!void {
        if (bytes.len == 0) return;
        try r.beginDirectWrite();
        try r.writer.writeAll(bytes);
    }

    fn ensureNewline(r: *Render) RenderError!void {
        if (r.line_start) return;
        try r.writer.writeByte('\n');
        r.line_start = true;
        r.wrote_anything = true;
    }

    fn insertBlankLine(r: *Render) RenderError!void {
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

test "merged formatting replaces a subtree with a virtual value" {
    const source =
        \\speed = 5 * 2 // retained
        \\other = 3
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(), source);
    defer ast.deinit(std.testing.allocator) catch unreachable;

    var parsed = Tree.Parsed{ .ast = &ast };
    const value_node = parsed.reader().root().child(0).child(0);
    var virtual: Tree.Virtual = .{};
    defer virtual.deinit(std.testing.allocator);
    const replacement = try virtual.addValue(std.testing.allocator, .{ .number = 42.5 });
    virtual.setRoot(replacement);
    const overlay = virtual.reader();
    var merge = Tree.Merge.init(parsed.reader(), overlay);
    defer merge.deinit(std.testing.allocator);
    try merge.mount(std.testing.allocator, value_node, overlay.root());

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderMerged(&merge, &output.writer);

    try std.testing.expectEqualStrings(
        \\speed = 42.5 // retained
        \\other = 3
        \\
    , output.written());
}

test "canonical formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(
        std.testing.allocator,
        arena.allocator(),
        "test={first=1;second=test.first*2;};status=.ready",
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
        \\status = .ready
        \\
    , output.written());
}

test "array trailing comma selects multiline formatting" {
    const source =
        \\inline=[1,base+1]
        \\collapsed=[
        \\  1,
        \\  2
        \\]
        \\multiline=[1,base+1,]
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
        \\inline = [1, base + 1]
        \\collapsed = [1, 2]
        \\multiline = [
        \\  1,
        \\  base + 1,
        \\]
        \\
    , output.written());
}

test "map trailing separator selects multiline formatting" {
    const source =
        \\compact={first=1;second={nested=true}}
        \\newline={first=1;second={nested=true
        \\}
        \\}
        \\semicolon={first=1;second={nested=true;};}
        \\empty={
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
        \\compact = { first = 1; second = { nested = true } }
        \\newline = {
        \\  first = 1
        \\  second = {
        \\    nested = true
        \\  }
        \\}
        \\semicolon = {
        \\  first = 1
        \\  second = {
        \\    nested = true
        \\  }
        \\}
        \\empty = {}
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
        \\items=[1,2,]
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
