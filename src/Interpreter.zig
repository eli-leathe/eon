const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Ast = @import("Ast.zig");

const Interpreter = @This();

pub const EvaluationError = Allocator.Error || error{
    InvalidNumber,
    InvalidChar,
    UnexpectedType,
    ExpectedValue,
    ValuesNotComparable,
    DivisionByZero,
    MissingField,
    InvalidFieldAccess,
    NotCallable,
    UndefinedIdentifier,
    RecursiveDefinition,
};
pub const FieldError = EvaluationError || error{InvalidPath};
pub const CursorError = error{InvalidAst};
pub const GetError = CursorError || FieldError || error{EmptyPath};
pub const Error = GetError;

pub const NativeFunction = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (context: ?*anyopaque, argument: Value) Value,

    pub fn call(self: NativeFunction, argument: Value) Value {
        return self.call_fn(self.context, argument);
    }
};

pub const Field = struct {
    name: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    string: []const u8,
    number: f64,
    char: u21,
    boolean: bool,
    record: []const Field,
    function: NativeFunction,

    /// Formats a value using source-like syntax.
    pub fn format(value: Value, writer: *Writer) Writer.Error!void {
        switch (value) {
            .string => |string| try writer.printStringEscaped(string),
            .number => |float| try writer.print("{d}", .{float}),
            .char => |char| {
                try writer.writeByte('\'');
                try writer.printUnicodeCodepoint(char);
                try writer.writeByte('\'');
            },
            .boolean => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
            .record => |fields| {
                try writer.writeAll("{");
                for (fields, 0..) |field, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try writer.writeAll(field.name);
                    try writer.writeAll(" = ");
                    try field.value.format(writer);
                }
                try writer.writeAll("}");
            },
            .function => try writer.writeAll("<function>"),
        }
    }
};

pub const Binding = struct {
    name: []const u8,
    value: Value,
};

const Evaluated = union(enum) {
    value: Value,
    source_map: Ast.Node.Index,
};

pub const TreeCursor = struct {
    interpreter: *Interpreter,
    at: Evaluated,

    pub const Tag = enum { map, value };
    pub const MapError = error{ExpectedMap};
    pub const ValueError = error{ExpectedValue};

    pub fn tag(self: TreeCursor) Tag {
        return switch (self.at) {
            .source_map => .map,
            .value => .value,
        };
    }

    pub fn field(self: TreeCursor, name: []const u8) FieldError!TreeCursor {
        if (name.len == 0) return error.InvalidPath;
        return .{
            .interpreter = self.interpreter,
            .at = try self.interpreter.getField(self.at, name),
        };
    }

    pub fn value(self: TreeCursor) ValueError!Value {
        return expectValue(self.at);
    }

    pub fn map(self: TreeCursor) MapError!MapCursor {
        return .{
            .interpreter = self.interpreter,
            .at = switch (self.at) {
                .source_map => |at| at,
                .value => return error.ExpectedMap,
            },
        };
    }
};
pub const MapCursor = struct {
    interpreter: *Interpreter,
    at: Ast.Node.Index,

    pub fn field(self: MapCursor, name: []const u8) FieldError!TreeCursor {
        if (name.len == 0) return error.InvalidPath;
        return .{
            .interpreter = self.interpreter,
            .at = try self.interpreter.getField(.{ .source_map = self.at }, name),
        };
    }
    pub fn fields(self: MapCursor) MapFieldIterator {
        return .{ .interpreter = self.interpreter, .at = self.at, .index = 0 };
    }

    const MapFieldIterator = struct {
        interpreter: *Interpreter,
        at: Ast.Node.Index,
        index: usize,
        pub fn next(self: *MapFieldIterator) ?[]const u8 {
            const declarations = switch (self.interpreter.ast.nodeData(self.at)) {
                .map => |declarations| declarations[0],
                else => unreachable,
            };
            if (self.index >= declarations.len) return null;
            const declaration = self.interpreter.ast.nodeData(declarations[self.index]).declaration;
            self.index += 1;
            return self.interpreter.ast.identifierSlice(declaration.lhs);
        }
    };
};

const NodeState = union(enum) {
    waiting,
    value: Evaluated,
};

ast: Ast,
bindings: []const Binding,
node_states: std.AutoHashMap(Ast.Node.Index, NodeState),

pub fn init(gpa: Allocator, ast: Ast) Interpreter {
    return initWithBindings(gpa, ast, &.{});
}

pub fn initWithBindings(gpa: Allocator, ast: Ast, bindings: []const Binding) Interpreter {
    return .{
        .ast = ast,
        .bindings = bindings,
        .node_states = .init(gpa),
    };
}

pub fn deinit(self: *Interpreter) void {
    self.node_states.deinit();
    self.* = undefined;
}

fn nodeSlice(self: *Interpreter, node: Ast.Node.Index) []const u8 {
    return self.ast.tokenSlice(self.ast.nodeMainToken(node));
}
fn evaluateNode(self: *Interpreter, node: Ast.Node.Index) EvaluationError!Evaluated {
    if (self.node_states.get(node)) |state| switch (state) {
        .waiting => return error.RecursiveDefinition,
        .value => |value| return value,
    };

    try self.node_states.put(node, .waiting);
    errdefer _ = self.node_states.remove(node);

    const result: Evaluated = result: switch (self.ast.nodeData(node)) {
        .map => break :result .{ .source_map = node },
        .declaration => unreachable,
        .char_literal => {
            const spelling = self.nodeSlice(node);
            if (spelling.len < 2) return error.InvalidChar;
            const contents = spelling[1 .. spelling.len - 1];
            const char = std.unicode.utf8Decode(contents) catch return error.InvalidChar;
            const encoded_len = std.unicode.utf8CodepointSequenceLength(char) catch return error.InvalidChar;
            if (encoded_len != contents.len) return error.InvalidChar;
            break :result .{ .value = .{ .char = char } };
        },
        .number_literal => {
            const spelling = self.nodeSlice(node);
            const val: Value = .{ .number = std.fmt.parseFloat(f64, spelling) catch return error.InvalidNumber };

            break :result .{ .value = val };
        },
        .string_literal => {
            const spelling = self.nodeSlice(node);
            break :result .{ .value = .{
                .string = if (spelling.len >= 2) spelling[1 .. spelling.len - 1] else "",
            } };
        },
        .identifier => {
            const name = self.ast.identifierSlice(self.ast.nodeMainToken(node));
            if (self.findDeclaration(.root, name)) |rhs| break :result try self.evaluateNode(rhs);
            for (self.bindings) |binding| {
                if (std.mem.eql(u8, binding.name, name)) {
                    break :result .{ .value = binding.value };
                }
            }
            return error.UndefinedIdentifier;
        },
        .group => |group| break :result try self.evaluateNode(group[0]),
        .negation => |operand| .{ .value = .{ .number = -try self.evaluateNodeOfType(operand, .number) } },
        .add => |binary| .{ .value = .{ .number = try self.evaluateNodeOfType(binary.lhs, .number) + try self.evaluateNodeOfType(binary.rhs, .number) } },
        .sub => |binary| .{ .value = .{ .number = try self.evaluateNodeOfType(binary.lhs, .number) - try self.evaluateNodeOfType(binary.rhs, .number) } },
        .mul => |binary| .{ .value = .{ .number = try self.evaluateNodeOfType(binary.lhs, .number) * try self.evaluateNodeOfType(binary.rhs, .number) } },
        .div => |binary| {
            const lhs = try self.evaluateNodeOfType(binary.lhs, .number);
            const rhs = try self.evaluateNodeOfType(binary.rhs, .number);
            break :result if (rhs == 0) return error.DivisionByZero else .{ .value = .{ .number = lhs / rhs } };
        },
        .bool_and => |binary| {
            const lhs = try self.evaluateNodeOfType(binary.lhs, .boolean);
            if (!lhs) break :result .{ .value = .{ .boolean = false } };
            break :result .{ .value = .{ .boolean = try self.evaluateNodeOfType(binary.rhs, .boolean) } };
        },
        .bool_or => |binary| {
            const lhs = try self.evaluateNodeOfType(binary.lhs, .boolean);
            if (lhs) break :result .{ .value = .{ .boolean = true } };
            break :result .{ .value = .{ .boolean = try self.evaluateNodeOfType(binary.rhs, .boolean) } };
        },
        .equal => unreachable,
        .equal_equal => |binary| .{ .value = .{ .boolean = try valuesEqual(
            try expectValue(try self.evaluateNode(binary.lhs)),
            try expectValue(try self.evaluateNode(binary.rhs)),
        ) } },
        .field_access => |field| {
            const parent = try self.evaluateNode(field.parent);
            const child = self.ast.tokenSlice(field.child);
            break :result try self.getField(parent, child);
        },
        .apply => |application| {
            const function = switch (try expectValue(try self.evaluateNode(application.func))) {
                .function => |function| function,
                else => return error.NotCallable,
            };
            const argument = try expectValue(try self.evaluateNode(application.arg));
            break :result .{ .value = function.call(argument) };
        },
    };

    try self.node_states.put(node, .{ .value = result });
    return result;
}

fn getField(self: *Interpreter, parent: Evaluated, name: []const u8) EvaluationError!Evaluated {
    return switch (parent) {
        .source_map => |map| if (self.findDeclaration(map, name)) |rhs|
            self.evaluateNode(rhs)
        else
            error.MissingField,
        .value => |value| switch (value) {
            .record => |fields| {
                for (fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) return .{ .value = field.value };
                }
                return error.MissingField;
            },
            else => error.InvalidFieldAccess,
        },
    };
}

fn findDeclaration(self: *const Interpreter, map: Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
    const declarations = switch (self.ast.nodeData(map)) {
        .map => |declarations| declarations[0],
        else => return null,
    };
    for (declarations) |declaration_index| {
        const declaration = self.ast.nodeData(declaration_index).declaration;
        if (std.mem.eql(u8, name, self.ast.identifierSlice(declaration.lhs))) return declaration.rhs;
    }
    return null;
}

fn expectValue(evaluated: Evaluated) error{ExpectedValue}!Value {
    return switch (evaluated) {
        .value => |value| value,
        .source_map => error.ExpectedValue,
    };
}
fn expectValueOfType(evaluated: Evaluated, comptime kind: std.meta.Tag(Value)) error{ ExpectedValue, UnexpectedType }!@FieldType(Value, @tagName(kind)) {
    return expectType(try expectValue(evaluated), kind);
}
fn expectType(value: Value, comptime kind: std.meta.Tag(Value)) error{UnexpectedType}!@FieldType(Value, @tagName(kind)) {
    switch (value) {
        kind => return @field(value, @tagName(kind)),
        else => return error.UnexpectedType,
    }
}
fn evaluateNodeOfType(self: *Interpreter, node: Ast.Node.Index, comptime kind: std.meta.Tag(Value)) EvaluationError!@FieldType(Value, @tagName(kind)) {
    return expectValueOfType(try self.evaluateNode(node), kind);
}

pub fn cursor(self: *Interpreter) CursorError!TreeCursor {
    if (self.ast.errors.len != 0) return error.InvalidAst;
    return .{ .interpreter = self, .at = .{ .source_map = .root } };
}

pub fn get(self: *Interpreter, path: []const u8) GetError!Value {
    if (path.len == 0) return error.EmptyPath;
    var c = try self.cursor();

    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |segment|
        c = try c.field(segment);

    return c.value();
}

fn valuesEqual(lhs: Value, rhs: Value) error{ValuesNotComparable}!bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return error.ValuesNotComparable;
    return switch (lhs) {
        .string => |string| std.mem.eql(u8, string, rhs.string),
        .char => |char| char == rhs.char,
        .boolean => |boolean| boolean == rhs.boolean,
        .number => |float| float == rhs.number,
        .record, .function => error.ValuesNotComparable,
    };
}

fn increment(_: ?*anyopaque, argument: Value) Value {
    return .{ .number = argument.number + 1 };
}

test "evaluate paths and expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(),
        \\base = 2
        \\forward = nested.answer
        \\nested = {
        \\  answer = base * base + 2
        \\}
        \\fraction = 5 / 2
        \\same = forward == 6
        \\short = same or 1 / 0 == 0
        \\message = "hello"
        \\letter = 'x'
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    var interpreter = init(std.testing.allocator, ast);
    defer interpreter.deinit();

    try std.testing.expectEqual(Value{ .number = 6 }, try interpreter.get("forward"));
    try std.testing.expectEqual(Value{ .number = 6 }, try interpreter.get("nested.answer"));
    try std.testing.expectEqual(Value{ .number = 2.5 }, try interpreter.get("fraction"));
    try std.testing.expectEqual(Value{ .boolean = true }, try interpreter.get("short"));
    try std.testing.expectEqualStrings("hello", (try interpreter.get("message")).string);
    try std.testing.expectEqual(@as(u21, 'x'), (try interpreter.get("letter")).char);

    const root_cursor = try interpreter.cursor();
    const nested_cursor = try root_cursor.field("nested");
    const answer_cursor = try nested_cursor.field("answer");
    try std.testing.expectEqual(TreeCursor.Tag.map, root_cursor.tag());
    try std.testing.expectEqual(TreeCursor.Tag.map, nested_cursor.tag());
    try std.testing.expectEqual(TreeCursor.Tag.value, answer_cursor.tag());
    try std.testing.expectError(error.ExpectedValue, nested_cursor.value());
    try std.testing.expectError(error.ExpectedMap, answer_cursor.map());
    try std.testing.expectEqual(Value{ .number = 6 }, try answer_cursor.value());
    try std.testing.expectEqual(
        Value{ .number = 6 },
        try (try (try root_cursor.field("nested")).field("answer")).value(),
    );
    try std.testing.expectError(error.InvalidPath, root_cursor.field(""));
}

test "quoted identifiers can use keyword names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(),
        \\@"if" = 40
        \\@"true" = 2
        \\@"and" = @"if" + @"true"
        \\nested = {
        \\  @"or" = @"and"
        \\}
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    var interpreter = init(std.testing.allocator, ast);
    defer interpreter.deinit();

    try std.testing.expectEqual(Value{ .number = 40 }, try interpreter.get("if"));
    try std.testing.expectEqual(Value{ .number = 42 }, try interpreter.get("and"));
    try std.testing.expectEqual(Value{ .number = 42 }, try interpreter.get("nested.or"));

    const nested_map = try (try (try interpreter.cursor()).field("nested")).map();
    var fields = nested_map.fields();
    try std.testing.expectEqualStrings("or", fields.next().?);
    try std.testing.expectEqual(null, fields.next());
}

test "map cursor enumerates fields without evaluating them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(),
        \\section = {
        \\  first = 1
        \\  broken = missing
        \\  last = 3
        \\}
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    var interpreter = init(std.testing.allocator, ast);
    defer interpreter.deinit();

    const section_cursor = try (try interpreter.cursor()).field("section");
    const map_cursor = try section_cursor.map();
    const evaluated_node_count = interpreter.node_states.count();
    var fields = map_cursor.fields();
    try std.testing.expectEqualStrings("first", fields.next().?);
    try std.testing.expectEqualStrings("broken", fields.next().?);
    try std.testing.expectEqualStrings("last", fields.next().?);
    try std.testing.expectEqual(null, fields.next());
    try std.testing.expectEqual(evaluated_node_count, interpreter.node_states.count());
}

test "reports lookup and evaluation errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(),
        \\cycle_a = cycle_b
        \\cycle_b = cycle_a
        \\map = {
        \\  value = 1
        \\}
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    var interpreter = init(std.testing.allocator, ast);
    defer interpreter.deinit();

    try std.testing.expectError(error.MissingField, interpreter.get("missing"));
    try std.testing.expectError(error.ExpectedValue, interpreter.get("map"));
    try std.testing.expectError(error.RecursiveDefinition, interpreter.get("cycle_a"));
}

test "host records and functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(
        std.testing.allocator,
        arena.allocator(),
        "answer = increment point.value",
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;

    const fields = [_]Field{.{ .name = "value", .value = .{ .number = 41 } }};
    const bindings = [_]Binding{
        .{ .name = "increment", .value = .{ .function = .{ .call_fn = increment } } },
        .{ .name = "point", .value = .{ .record = &fields } },
    };
    var interpreter = initWithBindings(std.testing.allocator, ast, &bindings);
    defer interpreter.deinit();

    try std.testing.expectEqual(Value{ .number = 42 }, try interpreter.get("answer"));
}
