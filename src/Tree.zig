const std = @import("std");

const Ast = @import("Ast.zig");
const Value = @import("Interpreter.zig").Value;

/// A parsed syntax tree. Its nodes and source locations are owned by `ast`.
pub const Parsed = struct {
    ast: *const Ast,
};

/// A source-less tree containing nodes synthesized by an embedding
/// application. String and atom payloads are borrowed for the lifetime of the
/// virtual tree.
pub const Virtual = struct {
    pub const Node = union(enum) {
        value: Value,
    };

    nodes: std.ArrayList(Node) = .empty,

    pub const NodeRef = enum(u32) { _ };

    pub fn deinit(self: *Virtual, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.* = undefined;
    }

    pub fn addValue(self: *Virtual, allocator: std.mem.Allocator, value: Value) !NodeRef {
        const index = self.nodes.items.len;
        try self.nodes.append(allocator, .{ .value = value });
        return @fromBackingInt(@intCast(index));
    }

    pub fn node(self: *const Virtual, ref: NodeRef) Node {
        return self.nodes.items[@backingInt(ref)];
    }
};

/// A union mount of a parsed tree and a source-less virtual tree. A mount
/// replaces one parsed subtree with one virtual subtree while retaining the
/// parsed node as the source/trivia anchor used by the formatter.
pub const Merge = struct {
    parsed: Parsed,
    virtual: *const Virtual,
    mounts: std.AutoHashMapUnmanaged(Ast.Node.Index, Virtual.NodeRef) = .empty,

    pub fn init(ast: *const Ast, virtual: *const Virtual) Merge {
        return .{ .parsed = .{ .ast = ast }, .virtual = virtual };
    }

    pub fn deinit(self: *Merge, allocator: std.mem.Allocator) void {
        self.mounts.deinit(allocator);
        self.* = undefined;
    }

    pub fn mount(
        self: *Merge,
        allocator: std.mem.Allocator,
        target: Ast.NodeRef,
        mounted_node: Virtual.NodeRef,
    ) !void {
        try self.mounts.put(allocator, target.index, mounted_node);
    }

    pub fn replacement(self: *const Merge, target: Ast.Node.Index) ?Virtual.Node {
        const mounted = self.mounts.get(target) orelse return null;
        return self.virtual.node(mounted);
    }
};

test "merge mounts virtual values over parsed nodes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(), "value = 1");
    defer ast.deinit(std.testing.allocator) catch unreachable;

    const declaration = ast.nodeData(.root).map[0][0];
    const target = Ast.NodeRef{ .index = ast.nodeData(declaration).declaration.rhs };
    var virtual: Virtual = .{};
    defer virtual.deinit(std.testing.allocator);
    const replacement = try virtual.addValue(std.testing.allocator, .{ .number = 2 });
    var merge = Merge.init(&ast, &virtual);
    defer merge.deinit(std.testing.allocator);
    try merge.mount(std.testing.allocator, target, replacement);

    try std.testing.expectEqual(Value{ .number = 2 }, merge.replacement(target.index).?.value);
}
