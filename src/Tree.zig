const std = @import("std");

const Ast = @import("Ast.zig");
const Value = @import("Interpreter.zig").Value;

pub const Kind = enum {
    root,
    map,
    declaration,
    negation,
    scalar,
    atom,
    identifier,
    array,
    group,
    binary,
    field_access,
    apply,
};

pub const TokenContent = union(enum) {
    text: []const u8,
    value: Value,
    identifier: []const u8,
};

pub const Token = struct {
    content: TokenContent,
    range: ?Ast.SourceRange = null,
};

/// Immutable syntax tree interface consumed by the formatter.
pub const Reader = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        root: *const fn (*const anyopaque) u64,
        kind: *const fn (*const anyopaque, u64) Kind,
        childCount: *const fn (*const anyopaque, u64) usize,
        child: *const fn (*const anyopaque, u64, usize) u64,
        token: *const fn (*const anyopaque, u64, usize) ?Token,
        multiline: *const fn (*const anyopaque, u64) bool,
        source: *const fn (*const anyopaque) ?[]const u8,
        sourceRange: *const fn (*const anyopaque, u64) ?Ast.SourceRange,
        replacementRange: *const fn (*const anyopaque, u64) ?Ast.SourceRange,
    };

    pub fn root(self: Reader) Node {
        return .{ .tree = self, .id = self.vtable.root(self.ptr) };
    }

    pub fn source(self: Reader) ?[]const u8 {
        return self.vtable.source(self.ptr);
    }

    pub fn eql(a: Reader, b: Reader) bool {
        return a.ptr == b.ptr and a.vtable == b.vtable;
    }
};

pub const Node = struct {
    tree: Reader,
    id: u64,

    pub fn kind(self: Node) Kind {
        return self.tree.vtable.kind(self.tree.ptr, self.id);
    }

    pub fn childCount(self: Node) usize {
        return self.tree.vtable.childCount(self.tree.ptr, self.id);
    }

    pub fn child(self: Node, index: usize) Node {
        std.debug.assert(index < self.childCount());
        return .{ .tree = self.tree, .id = self.tree.vtable.child(self.tree.ptr, self.id, index) };
    }

    pub fn token(self: Node, index: usize) ?Token {
        return self.tree.vtable.token(self.tree.ptr, self.id, index);
    }

    pub fn multiline(self: Node) bool {
        return self.tree.vtable.multiline(self.tree.ptr, self.id);
    }

    pub fn sourceRange(self: Node) ?Ast.SourceRange {
        return self.tree.vtable.sourceRange(self.tree.ptr, self.id);
    }

    pub fn replacementRange(self: Node) ?Ast.SourceRange {
        return self.tree.vtable.replacementRange(self.tree.ptr, self.id);
    }
};

/// Default tree implementation backed by a parsed AST.
pub const Parsed = struct {
    ast: *const Ast,

    pub fn reader(self: *const Parsed) Reader {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn nodeFromRef(self: *const Parsed, ref: Ast.NodeRef) Node {
        return .{ .tree = self.reader(), .id = @backingInt(ref.index) };
    }

    fn cast(ptr: *const anyopaque) *const Parsed {
        return @ptrCast(@alignCast(ptr));
    }

    fn index(node_id: u64) Ast.Node.Index {
        return @fromBackingInt(@intCast(@as(u32, @intCast(node_id))));
    }

    fn nodeId(node: Ast.Node.Index) u64 {
        return @backingInt(node);
    }

    fn root(_: *const anyopaque) u64 {
        return nodeId(.root);
    }

    fn kind(ptr: *const anyopaque, node_id: u64) Kind {
        const node = index(node_id);
        if (node == .root) return .root;
        return switch (cast(ptr).ast.nodeData(node)) {
            .map => .map,
            .declaration => .declaration,
            .negation => .negation,
            .boolean_literal, .char_literal, .number_literal, .string_literal => .scalar,
            .atom_literal => .atom,
            .identifier => .identifier,
            .array => .array,
            .group => .group,
            .bool_or, .bool_and, .equal, .equal_equal, .add, .sub, .mul, .div => .binary,
            .field_access => .field_access,
            .apply => .apply,
        };
    }

    fn childCount(ptr: *const anyopaque, node_id: u64) usize {
        return switch (cast(ptr).ast.nodeData(index(node_id))) {
            .map => |map| map[0].len,
            .declaration, .negation, .group, .field_access => 1,
            .array => |array| array[0].len,
            .bool_or, .bool_and, .equal, .equal_equal, .add, .sub, .mul, .div, .apply => 2,
            .boolean_literal, .char_literal, .number_literal, .string_literal, .atom_literal, .identifier => 0,
        };
    }

    fn child(ptr: *const anyopaque, node_id: u64, child_index: usize) u64 {
        return nodeId(switch (cast(ptr).ast.nodeData(index(node_id))) {
            .map => |map| map[0][child_index],
            .declaration => |declaration| declaration.rhs,
            .negation => |operand| operand,
            .array => |array| array[0][child_index].value,
            .group => |group| group[0],
            inline .bool_or, .bool_and, .equal, .equal_equal, .add, .sub, .mul, .div => |binary| if (child_index == 0) binary.lhs else binary.rhs,
            .field_access => |field| field.parent,
            .apply => |application| if (child_index == 0) application.func else application.arg,
            else => unreachable,
        });
    }

    fn parsedToken(ast: *const Ast, token_index: Ast.TokenIndex) Token {
        return .{
            .content = .{ .text = ast.tokenSlice(token_index) },
            .range = .{ .start = ast.tokenStart(token_index), .end = ast.tokenEnd(token_index) },
        };
    }

    fn token(ptr: *const anyopaque, node_id: u64, slot: usize) ?Token {
        const ast = cast(ptr).ast;
        const node = index(node_id);
        return switch (ast.nodeData(node)) {
            .map => |map| parsedToken(ast, if (slot == 0) ast.nodeMainToken(node) else if (slot == 1) map[1] else return null),
            .declaration => |declaration| parsedToken(ast, if (slot == 0) declaration.lhs else if (slot == 1) declaration.lhs + 1 else return null),
            .negation, .boolean_literal, .char_literal, .number_literal, .string_literal, .identifier => if (slot == 0) parsedToken(ast, ast.nodeMainToken(node)) else null,
            .atom_literal => |name| parsedToken(ast, if (slot == 0) ast.nodeMainToken(node) else if (slot == 1) name else return null),
            .array => |array| if (slot == 0)
                parsedToken(ast, ast.nodeMainToken(node))
            else if (slot == 1)
                parsedToken(ast, array[1])
            else if (slot - 2 < array[0].len)
                if (array[0][slot - 2].comma) |comma| parsedToken(ast, comma) else null
            else
                null,
            .group => |group| parsedToken(ast, if (slot == 0) ast.nodeMainToken(node) else if (slot == 1) group[1] else return null),
            .bool_or, .bool_and, .equal, .equal_equal, .add, .sub, .mul, .div => if (slot == 0) parsedToken(ast, ast.nodeMainToken(node)) else null,
            .field_access => |field| parsedToken(ast, if (slot == 0) ast.nodeMainToken(node) else if (slot == 1) field.child else return null),
            .apply => null,
        };
    }

    fn multiline(ptr: *const anyopaque, node_id: u64) bool {
        const ast = cast(ptr).ast;
        return switch (ast.nodeData(index(node_id))) {
            .map => |map| map[0].len != 0 and map[1] != 0 and switch (ast.tokenTag(map[1] - 1)) {
                .nl, .semicolon => true,
                else => false,
            },
            .array => |array| array[0].len != 0 and array[0][array[0].len - 1].comma != null,
            else => false,
        };
    }

    fn source(ptr: *const anyopaque) ?[]const u8 {
        return cast(ptr).ast.source;
    }

    fn sourceRange(ptr: *const anyopaque, node_id: u64) ?Ast.SourceRange {
        return cast(ptr).ast.nodeRange(index(node_id));
    }

    fn replacementRange(_: *const anyopaque, _: u64) ?Ast.SourceRange {
        return null;
    }

    const vtable: Reader.VTable = .{
        .root = root,
        .kind = kind,
        .childCount = childCount,
        .child = child,
        .token = token,
        .multiline = multiline,
        .source = source,
        .sourceRange = sourceRange,
        .replacementRange = replacementRange,
    };
};

/// Source-less syntax tree synthesized by an embedding application. Slices in
/// node payloads are borrowed for the lifetime of this tree.
pub const Virtual = struct {
    pub const NodeData = union(Kind) {
        root: []const NodeRef,
        map: struct { declarations: []const NodeRef, multiline: bool = false },
        declaration: struct { name: []const u8, value: NodeRef },
        negation: NodeRef,
        scalar: Value,
        atom: []const u8,
        identifier: []const u8,
        array: struct { items: []const NodeRef, multiline: bool = false },
        group: NodeRef,
        binary: struct { lhs: NodeRef, operator: []const u8, rhs: NodeRef },
        field_access: struct { parent: NodeRef, field: []const u8 },
        apply: struct { function: NodeRef, argument: NodeRef },
    };

    pub const NodeRef = enum(u32) { _ };
    nodes: std.ArrayList(NodeData) = .empty,
    root_node: ?NodeRef = null,

    pub fn reader(self: *const Virtual) Reader {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn deinit(self: *Virtual, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.* = undefined;
    }

    pub fn addNode(self: *Virtual, allocator: std.mem.Allocator, node_data: NodeData) !NodeRef {
        const node: NodeRef = @fromBackingInt(@intCast(self.nodes.items.len));
        try self.nodes.append(allocator, node_data);
        return node;
    }

    pub fn addValue(self: *Virtual, allocator: std.mem.Allocator, value: Value) !NodeRef {
        return self.addNode(allocator, .{ .scalar = value });
    }

    pub fn setRoot(self: *Virtual, node: NodeRef) void {
        self.root_node = node;
    }

    pub fn nodeFromRef(self: *const Virtual, ref: NodeRef) Node {
        return .{ .tree = self.reader(), .id = @backingInt(ref) };
    }

    fn cast(ptr: *const anyopaque) *const Virtual {
        return @ptrCast(@alignCast(ptr));
    }

    fn refFromId(id: u64) NodeRef {
        return @fromBackingInt(@intCast(@as(u32, @intCast(id))));
    }

    fn nodeId(node: NodeRef) u64 {
        return @backingInt(node);
    }

    fn data(ptr: *const anyopaque, node_id: u64) NodeData {
        return cast(ptr).nodes.items[@backingInt(refFromId(node_id))];
    }

    fn root(ptr: *const anyopaque) u64 {
        return nodeId(cast(ptr).root_node orelse @panic("virtual tree has no root"));
    }

    fn kind(ptr: *const anyopaque, node_id: u64) Kind {
        return std.meta.activeTag(data(ptr, node_id));
    }

    fn childCount(ptr: *const anyopaque, node_id: u64) usize {
        return switch (data(ptr, node_id)) {
            .root => |children| children.len,
            .map => |map| map.declarations.len,
            .declaration, .negation, .group, .field_access => 1,
            .array => |array| array.items.len,
            .binary, .apply => 2,
            .scalar, .atom, .identifier => 0,
        };
    }

    fn child(ptr: *const anyopaque, node_id: u64, child_index: usize) u64 {
        return nodeId(switch (data(ptr, node_id)) {
            .root => |children| children[child_index],
            .map => |map| map.declarations[child_index],
            .declaration => |declaration| declaration.value,
            .negation => |operand| operand,
            .array => |array| array.items[child_index],
            .group => |grouped| grouped,
            .binary => |binary| if (child_index == 0) binary.lhs else binary.rhs,
            .field_access => |field| field.parent,
            .apply => |application| if (child_index == 0) application.function else application.argument,
            else => unreachable,
        });
    }

    fn text(value: []const u8) Token {
        return .{ .content = .{ .text = value } };
    }

    fn identifier(value: []const u8) Token {
        return .{ .content = .{ .identifier = value } };
    }

    fn token(ptr: *const anyopaque, node_id: u64, slot: usize) ?Token {
        return switch (data(ptr, node_id)) {
            .root, .apply => null,
            .map => if (slot == 0) text("{") else if (slot == 1) text("}") else null,
            .declaration => |declaration| if (slot == 0) identifier(declaration.name) else if (slot == 1) text("=") else null,
            .negation => if (slot == 0) text("-") else null,
            .scalar => |value| if (slot == 0) .{ .content = .{ .value = value } } else null,
            .atom => |name| if (slot == 0) text(".") else if (slot == 1) identifier(name) else null,
            .identifier => |name| if (slot == 0) identifier(name) else null,
            .array => |array| if (slot == 0)
                text("[")
            else if (slot == 1)
                text("]")
            else if (slot - 2 < array.items.len and (slot - 2 + 1 < array.items.len or array.multiline))
                text(",")
            else
                null,
            .group => if (slot == 0) text("(") else if (slot == 1) text(")") else null,
            .binary => |binary| if (slot == 0) text(binary.operator) else null,
            .field_access => |field| if (slot == 0) text(".") else if (slot == 1) identifier(field.field) else null,
        };
    }

    fn multiline(ptr: *const anyopaque, node_id: u64) bool {
        return switch (data(ptr, node_id)) {
            .map => |map| map.multiline,
            .array => |array| array.multiline,
            else => false,
        };
    }

    fn source(_: *const anyopaque) ?[]const u8 {
        return null;
    }

    fn noRange(_: *const anyopaque, _: u64) ?Ast.SourceRange {
        return null;
    }

    const vtable: Reader.VTable = .{
        .root = root,
        .kind = kind,
        .childCount = childCount,
        .child = child,
        .token = token,
        .multiline = multiline,
        .source = source,
        .sourceRange = noRange,
        .replacementRange = noRange,
    };
};

/// Union mount of two trees. Mounted nodes from `overlay` replace nodes from
/// `base`, while the mount point retains the base node's source range.
pub const Merge = struct {
    base: Reader,
    overlay: Reader,
    mounts: std.AutoHashMapUnmanaged(u64, u64) = .empty,

    const overlay_bit: u64 = 1 << 63;

    pub fn init(base: Reader, overlay: Reader) Merge {
        return .{ .base = base, .overlay = overlay };
    }

    pub fn reader(self: *const Merge) Reader {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn deinit(self: *Merge, allocator: std.mem.Allocator) void {
        self.mounts.deinit(allocator);
        self.* = undefined;
    }

    pub fn mount(self: *Merge, allocator: std.mem.Allocator, target: Node, mounted: Node) !void {
        std.debug.assert(target.tree.eql(self.base));
        std.debug.assert(mounted.tree.eql(self.overlay));
        std.debug.assert(target.id < overlay_bit and mounted.id < overlay_bit);
        try self.mounts.put(allocator, target.id, mounted.id);
    }

    fn cast(ptr: *const anyopaque) *const Merge {
        return @ptrCast(@alignCast(ptr));
    }

    fn isOverlay(id: u64) bool {
        return id & overlay_bit != 0;
    }

    fn localId(id: u64) u64 {
        return id & ~overlay_bit;
    }

    const Resolved = struct { tree: Reader, id: u64, overlay: bool };

    fn resolve(merge: *const Merge, id: u64) Resolved {
        if (isOverlay(id)) return .{ .tree = merge.overlay, .id = localId(id), .overlay = true };
        if (merge.mounts.get(id)) |mounted| return .{ .tree = merge.overlay, .id = mounted, .overlay = true };
        return .{ .tree = merge.base, .id = id, .overlay = false };
    }

    fn wrapChild(resolved: Resolved, child_node: Node) u64 {
        std.debug.assert(child_node.tree.eql(resolved.tree));
        std.debug.assert(child_node.id < overlay_bit);
        return child_node.id | if (resolved.overlay) overlay_bit else 0;
    }

    fn root(ptr: *const anyopaque) u64 {
        const merge = cast(ptr);
        const base_root = merge.base.root();
        std.debug.assert(base_root.id < overlay_bit);
        return base_root.id;
    }

    fn kind(ptr: *const anyopaque, id: u64) Kind {
        const resolved = resolve(cast(ptr), id);
        return (Node{ .tree = resolved.tree, .id = resolved.id }).kind();
    }

    fn childCount(ptr: *const anyopaque, id: u64) usize {
        const resolved = resolve(cast(ptr), id);
        return (Node{ .tree = resolved.tree, .id = resolved.id }).childCount();
    }

    fn child(ptr: *const anyopaque, id: u64, child_index: usize) u64 {
        const merge = cast(ptr);
        const resolved = resolve(merge, id);
        const origin = Node{ .tree = resolved.tree, .id = resolved.id };
        return wrapChild(resolved, origin.child(child_index));
    }

    fn token(ptr: *const anyopaque, id: u64, slot: usize) ?Token {
        const resolved = resolve(cast(ptr), id);
        return (Node{ .tree = resolved.tree, .id = resolved.id }).token(slot);
    }

    fn multiline(ptr: *const anyopaque, id: u64) bool {
        const resolved = resolve(cast(ptr), id);
        return (Node{ .tree = resolved.tree, .id = resolved.id }).multiline();
    }

    fn source(ptr: *const anyopaque) ?[]const u8 {
        return cast(ptr).base.source();
    }

    fn sourceRange(ptr: *const anyopaque, id: u64) ?Ast.SourceRange {
        const merge = cast(ptr);
        if (!isOverlay(id) and merge.mounts.contains(id))
            return (Node{ .tree = merge.base, .id = id }).sourceRange();
        const resolved = resolve(merge, id);
        return (Node{ .tree = resolved.tree, .id = resolved.id }).sourceRange();
    }

    fn replacementRange(ptr: *const anyopaque, id: u64) ?Ast.SourceRange {
        const merge = cast(ptr);
        if (!isOverlay(id) and merge.mounts.contains(id))
            return (Node{ .tree = merge.base, .id = id }).sourceRange();
        return null;
    }

    const vtable: Reader.VTable = .{
        .root = root,
        .kind = kind,
        .childCount = childCount,
        .child = child,
        .token = token,
        .multiline = multiline,
        .source = source,
        .sourceRange = sourceRange,
        .replacementRange = replacementRange,
    };
};

test "merge presents mounted virtual nodes through the reader interface" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(), "value = 1");
    defer ast.deinit(std.testing.allocator) catch unreachable;

    var parsed = Parsed{ .ast = &ast };
    const declaration = parsed.reader().root().child(0);
    const target = declaration.child(0);
    var virtual: Virtual = .{};
    defer virtual.deinit(std.testing.allocator);
    const replacement_ref = try virtual.addValue(std.testing.allocator, .{ .number = 2 });
    virtual.setRoot(replacement_ref);
    const overlay = virtual.reader();
    var merge = Merge.init(parsed.reader(), overlay);
    defer merge.deinit(std.testing.allocator);
    try merge.mount(std.testing.allocator, target, overlay.root());

    const mounted = merge.reader().root().child(0).child(0);
    try std.testing.expectEqual(Kind.scalar, mounted.kind());
    try std.testing.expectEqual(Value{ .number = 2 }, mounted.token(0).?.content.value);
    try std.testing.expect(mounted.replacementRange() != null);
}
