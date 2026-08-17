const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Ast = @import("Ast.zig");
const Syntax = @import("Syntax.zig");

const Interpreter = @This();

pub const IdentifierError = Allocator.Error || error{InvalidIdentifier};
pub const EvaluationError = IdentifierError || error{
    InvalidNumber,
    InvalidChar,
    InvalidString,
    UnexpectedType,
    ExpectedValue,
    ValuesNotComparable,
    DivisionByZero,
    MissingField,
    InvalidFieldAccess,
    NotCallable,
    UndefinedIdentifier,
    RecursiveDefinition,
    ExpectedMap,
    ExpectedArray,
    InvalidPath,
};
pub const FieldError = EvaluationError;
pub const CursorError = error{InvalidAst};
pub const GetError = CursorError || FieldError || error{EmptyPath} || EvaluationError;
pub const Error = GetError;

/// A function supplied by the embedding application.
///
/// The argument cursor can represent a scalar value, record, or array and is
/// valid for the lifetime of the interpreter. Errors returned by the callback
/// are propagated as evaluation errors.
pub const NativeFunction = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (context: ?*anyopaque, argument: TreeCursor) EvaluationError!Value,

    pub fn call(self: NativeFunction, argument: TreeCursor) EvaluationError!Value {
        return self.call_fn(self.context, argument);
    }
};

pub const Value = union(enum) {
    string: []const u8,
    atom: []const u8,
    number: f64,
    char: u21,
    boolean: bool,
    function: NativeFunction,

    pub fn format(value: Value, writer: *Writer) Writer.Error!void {
        switch (value) {
            .string => |string| try writer.printStringEscaped(string),
            .atom => |atom| {
                try writer.writeByte('.');
                try Syntax.writeIdentifier(atom, writer);
            },
            .number => |float| try writer.print("{d}", .{float}),
            .char => |char| {
                try writer.writeByte('\'');
                try std.zig.charEscape(char, writer);
                try writer.writeByte('\'');
            },
            .boolean => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
            .function => try writer.writeAll("<function>"),
        }
    }
};

pub const MaterializedField = struct {
    name: []const u8,
    value: MaterializedValue,
};

pub const MaterializedValue = union(enum) {
    string: []const u8,
    atom: []const u8,
    number: f64,
    char: u21,
    boolean: bool,
    function: NativeFunction,
    array: []const MaterializedValue,
    record: []const MaterializedField,

    fn fromValue(value: Value) MaterializedValue {
        return switch (value) {
            .string => |string| .{ .string = string },
            .atom => |atom| .{ .atom = atom },
            .number => |number| .{ .number = number },
            .char => |char| .{ .char = char },
            .boolean => |boolean| .{ .boolean = boolean },
            .function => |function| .{ .function = function },
        };
    }

    pub fn format(value: MaterializedValue, writer: *Writer) Writer.Error!void {
        switch (value) {
            .string => |string| try writer.printStringEscaped(string),
            .atom => |atom| {
                try writer.writeByte('.');
                try Syntax.writeIdentifier(atom, writer);
            },
            .number => |float| try writer.print("{d}", .{float}),
            .char => |char| {
                try writer.writeByte('\'');
                try std.zig.charEscape(char, writer);
                try writer.writeByte('\'');
            },
            .boolean => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
            .function => try writer.writeAll("<function>"),
            .array => |items| {
                try writer.writeByte('[');
                for (items, 0..) |item, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try item.format(writer);
                }
                try writer.writeByte(']');
            },
            .record => |fields| {
                try writer.writeByte('{');
                for (fields, 0..) |field, i| {
                    if (i != 0) try writer.writeAll("; ");
                    try Syntax.writeIdentifier(field.name, writer);
                    try writer.writeAll(" = ");
                    try field.value.format(writer);
                }
                try writer.writeByte('}');
            },
        }
    }
};

pub const Binding = struct {
    name: []const u8,
    value: Value,
};

const Evaluated = union(enum) {
    value: Value,
    map: Ast.Node.Index,
    array: Ast.Node.Index,
};

pub const TreeCursor = struct {
    interpreter: *Interpreter,
    at: Evaluated,

    pub const Tag = std.meta.Tag(Evaluated);
    pub const MapError = error{ExpectedMap};
    pub const ArrayError = error{ExpectedArray};
    pub const ValueError = EvaluationError;

    pub fn tag(self: TreeCursor) Tag {
        return std.meta.activeTag(self.at);
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

    /// Eagerly evaluates this cursor and all descendants.
    pub fn materialize(self: TreeCursor) ValueError!MaterializedValue {
        return self.interpreter.materializeValue(self.at);
    }

    pub fn map(self: TreeCursor) MapError!MapCursor {
        return .{
            .interpreter = self.interpreter,
            .at = switch (self.at) {
                .map => |at| at,
                .array, .value => return error.ExpectedMap,
            },
        };
    }

    pub fn array(self: TreeCursor) ArrayError!ArrayCursor {
        return .{
            .interpreter = self.interpreter,
            .at = switch (self.at) {
                .array => |at| at,
                .map, .value => return error.ExpectedArray,
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
            .at = try self.interpreter.getField(.{ .map = self.at }, name),
        };
    }

    /// Return the unevaluated syntax node for a field value. The reference is
    /// valid only for the AST owned by this interpreter.
    pub fn fieldNode(self: MapCursor, name: []const u8) FieldError!Ast.NodeRef {
        if (name.len == 0) return error.InvalidPath;
        return .{ .index = try self.interpreter.findDeclaration(self.at, name) orelse error.MissingField };
    }
    pub fn fields(self: MapCursor) MapFieldIterator {
        return .{ .interpreter = self.interpreter, .at = self.at, .index = 0 };
    }
    pub fn len(self: MapCursor) usize {
        const declarations = switch (self.interpreter.ast.nodeData(self.at)) {
            .map => |declarations| declarations[0],
            else => unreachable,
        };
        return declarations.len;
    }

    const MapFieldIterator = struct {
        interpreter: *Interpreter,
        at: Ast.Node.Index,
        index: usize,
        pub fn next(self: *MapFieldIterator) IdentifierError!?[]const u8 {
            const declarations = switch (self.interpreter.ast.nodeData(self.at)) {
                .map => |declarations| declarations[0],
                else => unreachable,
            };
            if (self.index >= declarations.len) return null;
            const declaration = self.interpreter.ast.nodeData(declarations[self.index]).declaration;
            self.index += 1;
            return try self.interpreter.identifierName(declaration.lhs);
        }
    };
};

pub const ArrayCursor = struct {
    interpreter: *Interpreter,
    at: Ast.Node.Index,

    pub const ItemError = EvaluationError || error{IndexOutOfBounds};

    pub fn item(self: ArrayCursor, index: usize) ItemError!TreeCursor {
        const source_items = switch (self.interpreter.ast.nodeData(self.at)) {
            .array => |array| array[0],
            else => unreachable,
        };
        if (index >= source_items.len) return error.IndexOutOfBounds;
        return .{
            .interpreter = self.interpreter,
            .at = try self.interpreter.evaluateNode(
                source_items[index].value,
                self.interpreter.parent_scopes.get(self.at) orelse unreachable,
            ),
        };
    }

    pub fn items(self: ArrayCursor) ArrayItemIterator {
        return .{ .array = self, .index = 0 };
    }

    pub fn len(self: ArrayCursor) usize {
        return switch (self.interpreter.ast.nodeData(self.at)) {
            .array => |array| array[0].len,
            else => unreachable,
        };
    }

    const ArrayItemIterator = struct {
        array: ArrayCursor,
        index: usize,

        pub fn next(self: *ArrayItemIterator) EvaluationError!?TreeCursor {
            if (self.index >= self.array.len()) return null;
            const index = self.index;
            self.index += 1;
            return self.array.item(index) catch |err| switch (err) {
                error.IndexOutOfBounds => unreachable,
                else => |evaluation_error| evaluation_error,
            };
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
parent_scopes: std.AutoHashMap(Ast.Node.Index, Ast.Node.Index),
decoded_identifiers: std.AutoHashMap(Ast.TokenIndex, []const u8),
arena: std.heap.ArenaAllocator,

pub fn init(gpa: Allocator, ast: Ast) Interpreter {
    return initWithBindings(gpa, ast, &.{});
}

pub fn initWithBindings(gpa: Allocator, ast: Ast, bindings: []const Binding) Interpreter {
    return .{
        .ast = ast,
        .bindings = bindings,
        .node_states = .init(gpa),
        .parent_scopes = .init(gpa),
        .decoded_identifiers = .init(gpa),
        .arena = .init(gpa),
    };
}

pub fn deinit(self: *Interpreter) void {
    self.node_states.deinit();
    self.parent_scopes.deinit();
    self.decoded_identifiers.deinit();
    self.arena.deinit();
    self.* = undefined;
}

fn nodeSlice(self: *Interpreter, node: Ast.Node.Index) []const u8 {
    return self.ast.tokenSlice(self.ast.nodeMainToken(node));
}

fn identifierName(self: *Interpreter, token: Ast.TokenIndex) IdentifierError![]const u8 {
    const spelling = self.ast.tokenSlice(token);
    if (!std.mem.startsWith(u8, spelling, "@\"")) return spelling;
    if (self.decoded_identifiers.get(token)) |name| return name;

    const name = std.zig.string_literal.parseAlloc(self.arena.allocator(), spelling[1..]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLiteral => return error.InvalidIdentifier,
    };
    if (name.len == 0 or std.mem.findScalar(u8, name, 0) != null) return error.InvalidIdentifier;
    try self.decoded_identifiers.put(token, name);
    return name;
}

fn evaluateNode(
    self: *Interpreter,
    node: Ast.Node.Index,
    parent_scope: Ast.Node.Index,
) EvaluationError!Evaluated {
    if (self.node_states.get(node)) |state| switch (state) {
        .waiting => return error.RecursiveDefinition,
        .value => |value| return value,
    };

    try self.node_states.put(node, .waiting);
    errdefer _ = self.node_states.remove(node);

    const result: Evaluated = result: switch (self.ast.nodeData(node)) {
        .map => {
            try self.parent_scopes.putNoClobber(node, parent_scope);
            break :result .{ .map = node };
        },
        .array => {
            try self.parent_scopes.putNoClobber(node, parent_scope);
            break :result .{ .array = node };
        },
        .declaration => unreachable,
        .boolean_literal => break :result .{ .value = .{
            .boolean = self.ast.tokenTag(self.ast.nodeMainToken(node)) == .keyword_true,
        } },
        .char_literal => {
            const spelling = self.nodeSlice(node);
            break :result .{ .value = .{ .char = switch (std.zig.parseCharLiteral(spelling)) {
                .success => |char| char,
                .failure => return error.InvalidChar,
            } } };
        },
        .number_literal => {
            const spelling = self.nodeSlice(node);
            const val: Value = .{ .number = std.fmt.parseFloat(f64, spelling) catch return error.InvalidNumber };

            break :result .{ .value = val };
        },
        .string_literal => {
            const spelling = self.nodeSlice(node);
            break :result .{ .value = .{ .string = std.zig.string_literal.parseAlloc(
                self.arena.allocator(),
                spelling,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidLiteral => return error.InvalidString,
            } } };
        },
        .atom_literal => |name_token| break :result .{ .value = .{
            .atom = try self.identifierName(name_token),
        } },
        .identifier => {
            const name = try self.identifierName(self.ast.nodeMainToken(node));
            if (try self.findDeclarationInScope(parent_scope, name)) |declaration| {
                break :result try self.evaluateNode(declaration.rhs, declaration.parent_scope);
            }
            for (self.bindings) |binding| {
                if (std.mem.eql(u8, binding.name, name)) {
                    break :result .{ .value = binding.value };
                }
            }
            return error.UndefinedIdentifier;
        },
        .group => |group| break :result try self.evaluateNode(group[0], parent_scope),
        .negation => |operand| .{ .value = .{ .number = -try self.evaluateNodeOfType(operand, parent_scope, .number) } },
        .add => |binary| .{ .value = .{ .number = try self.evaluateNodeOfType(binary.lhs, parent_scope, .number) + try self.evaluateNodeOfType(binary.rhs, parent_scope, .number) } },
        .sub => |binary| .{ .value = .{ .number = try self.evaluateNodeOfType(binary.lhs, parent_scope, .number) - try self.evaluateNodeOfType(binary.rhs, parent_scope, .number) } },
        .mul => |binary| .{ .value = .{ .number = try self.evaluateNodeOfType(binary.lhs, parent_scope, .number) * try self.evaluateNodeOfType(binary.rhs, parent_scope, .number) } },
        .div => |binary| {
            const lhs = try self.evaluateNodeOfType(binary.lhs, parent_scope, .number);
            const rhs = try self.evaluateNodeOfType(binary.rhs, parent_scope, .number);
            break :result if (rhs == 0) return error.DivisionByZero else .{ .value = .{ .number = lhs / rhs } };
        },
        .bool_and => |binary| {
            const lhs = try self.evaluateNodeOfType(binary.lhs, parent_scope, .boolean);
            if (!lhs) break :result .{ .value = .{ .boolean = false } };
            break :result .{ .value = .{ .boolean = try self.evaluateNodeOfType(binary.rhs, parent_scope, .boolean) } };
        },
        .bool_or => |binary| {
            const lhs = try self.evaluateNodeOfType(binary.lhs, parent_scope, .boolean);
            if (lhs) break :result .{ .value = .{ .boolean = true } };
            break :result .{ .value = .{ .boolean = try self.evaluateNodeOfType(binary.rhs, parent_scope, .boolean) } };
        },
        .equal => unreachable,
        .equal_equal => |binary| .{ .value = .{ .boolean = try valuesEqual(
            try expectValue(try self.evaluateNode(binary.lhs, parent_scope)),
            try expectValue(try self.evaluateNode(binary.rhs, parent_scope)),
        ) } },
        .field_access => |field| {
            const parent = try self.evaluateNode(field.parent, parent_scope);
            const child = try self.identifierName(field.child);
            break :result try self.getField(parent, child);
        },
        .apply => |application| {
            const function = switch (try expectValue(try self.evaluateNode(application.func, parent_scope))) {
                .function => |function| function,
                else => return error.NotCallable,
            };
            const argument = TreeCursor{
                .interpreter = self,
                .at = try self.evaluateNode(application.arg, parent_scope),
            };
            break :result .{ .value = try function.call(argument) };
        },
    };

    try self.node_states.put(node, .{ .value = result });
    return result;
}

fn materializeValue(self: *Interpreter, evaluated: Evaluated) EvaluationError!MaterializedValue {
    return switch (evaluated) {
        .value => |value| MaterializedValue.fromValue(value),
        .map => |map| {
            const declarations, _ = self.ast.nodeData(map).map;
            const fields = try self.arena.allocator().alloc(MaterializedField, declarations.len);

            const previous_state = self.node_states.get(map);
            if (previous_state) |state| switch (state) {
                .waiting => return error.RecursiveDefinition,
                .value => {},
            };
            try self.node_states.put(map, .waiting);
            defer {
                if (previous_state) |state|
                    self.node_states.put(map, state) catch unreachable
                else
                    _ = self.node_states.remove(map);
            }

            for (declarations, fields) |declaration_index, *field| {
                const declaration = self.ast.nodeData(declaration_index).declaration;
                field.* = .{
                    .name = try self.identifierName(declaration.lhs),
                    .value = try self.materializeValue(try self.evaluateNode(declaration.rhs, map)),
                };
            }
            return .{ .record = fields };
        },
        .array => |array| {
            const source_items, _ = self.ast.nodeData(array).array;
            const items = try self.arena.allocator().alloc(MaterializedValue, source_items.len);

            const previous_state = self.node_states.get(array);
            if (previous_state) |state| switch (state) {
                .waiting => return error.RecursiveDefinition,
                .value => {},
            };
            try self.node_states.put(array, .waiting);
            defer {
                if (previous_state) |state|
                    self.node_states.put(array, state) catch unreachable
                else
                    _ = self.node_states.remove(array);
            }

            for (source_items, items) |source_item, *item| {
                item.* = try self.materializeValue(try self.evaluateNode(
                    source_item.value,
                    self.parent_scopes.get(array) orelse unreachable,
                ));
            }
            return .{ .array = items };
        },
    };
}

fn getField(self: *Interpreter, parent: Evaluated, field: []const u8) EvaluationError!Evaluated {
    return switch (parent) {
        .map => |map| if (try self.findDeclaration(map, field)) |rhs|
            self.evaluateNode(rhs, map)
        else
            error.MissingField,
        .array => |array| {
            const index = std.fmt.parseInt(usize, field, 10) catch return error.MissingField;
            const source_items = self.ast.nodeData(array).array[0];
            if (index >= source_items.len) return error.MissingField;
            return self.evaluateNode(
                source_items[index].value,
                self.parent_scopes.get(array) orelse unreachable,
            );
        },
        .value => error.InvalidFieldAccess,
    };
}

const ScopedDeclaration = struct {
    rhs: Ast.Node.Index,
    parent_scope: Ast.Node.Index,
};

fn findDeclarationInScope(self: *Interpreter, starting_scope: Ast.Node.Index, name: []const u8) IdentifierError!?ScopedDeclaration {
    var parent_scope = starting_scope;
    while (true) {
        if (try self.findDeclaration(parent_scope, name)) |rhs| return .{
            .rhs = rhs,
            .parent_scope = parent_scope,
        };
        if (parent_scope == .root) return null;
        parent_scope = self.parent_scopes.get(parent_scope) orelse unreachable;
    }
}

fn findDeclaration(self: *Interpreter, map: Ast.Node.Index, name: []const u8) IdentifierError!?Ast.Node.Index {
    const declarations = switch (self.ast.nodeData(map)) {
        .map => |declarations| declarations[0],
        else => return null,
    };
    for (declarations) |declaration_index| {
        const declaration = self.ast.nodeData(declaration_index).declaration;
        if (std.mem.eql(u8, name, try self.identifierName(declaration.lhs))) return declaration.rhs;
    }
    return null;
}

fn expectValue(evaluated: Evaluated) error{ExpectedValue}!Value {
    return switch (evaluated) {
        .value => |value| value,
        .map, .array => error.ExpectedValue,
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
fn evaluateNodeOfType(
    self: *Interpreter,
    node: Ast.Node.Index,
    parent_scope: Ast.Node.Index,
    comptime kind: std.meta.Tag(Value),
) EvaluationError!@FieldType(Value, @tagName(kind)) {
    return expectValueOfType(try self.evaluateNode(node, parent_scope), kind);
}

pub fn cursor(self: *Interpreter) CursorError!TreeCursor {
    if (self.ast.errors.len != 0) return error.InvalidAst;
    return .{ .interpreter = self, .at = .{ .map = .root } };
}

pub fn get(self: *Interpreter, path: []const u8) GetError!MaterializedValue {
    if (path.len == 0) return error.EmptyPath;
    var c = try self.cursor();
    if (std.mem.eql(u8, path, ".")) return c.materialize();

    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |segment|
        c = try c.field(segment);

    return try c.materialize();
}

fn valuesEqual(lhs: Value, rhs: Value) error{ValuesNotComparable}!bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return error.ValuesNotComparable;
    return switch (lhs) {
        .string => |string| std.mem.eql(u8, string, rhs.string),
        .atom => |atom| std.mem.eql(u8, atom, rhs.atom),
        .char => |char| char == rhs.char,
        .boolean => |boolean| boolean == rhs.boolean,
        .number => |float| float == rhs.number,
        .function => error.ValuesNotComparable,
    };
}

test "format scalar and materialized values" {
    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try (Value{ .atom = "if" }).format(&output.writer);
    try std.testing.expectEqualStrings(".@\"if\"", output.written());

    output.clearRetainingCapacity();
    const fields = [_]MaterializedField{
        .{ .name = "plain", .value = .{ .number = 1 } },
        .{ .name = "if", .value = .{ .boolean = true } },
    };
    try (MaterializedValue{ .record = &fields }).format(&output.writer);
    try std.testing.expectEqualStrings("{plain = 1; @\"if\" = true}", output.written());
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
        \\enabled = true
        \\disabled = false
        \\literal_logic = enabled and disabled or true
        \\message = "hello"
        \\letter = 'x'
        \\status = .ready
        \\quoted_atom = .@"if"
        \\same_atom = .ready == .ready
        \\items = [base, nested.answer + 1, [true, false]]
        \\first_item = items.0
        \\records = [{ name = "first"; nested = { enabled = true } }, { name = "second" }]
        \\projected = { answer = 42 }.answer
        \\empty = []
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    var interpreter = init(std.testing.allocator, ast);
    defer interpreter.deinit();

    try std.testing.expectEqual(MaterializedValue{ .number = 6 }, try interpreter.get("forward"));
    try std.testing.expectEqual(MaterializedValue{ .number = 6 }, try interpreter.get("nested.answer"));
    try std.testing.expectEqual(MaterializedValue{ .number = 2.5 }, try interpreter.get("fraction"));
    try std.testing.expectEqual(MaterializedValue{ .boolean = true }, try interpreter.get("short"));
    try std.testing.expectEqual(MaterializedValue{ .boolean = true }, try interpreter.get("enabled"));
    try std.testing.expectEqual(MaterializedValue{ .boolean = false }, try interpreter.get("disabled"));
    try std.testing.expectEqual(MaterializedValue{ .boolean = true }, try interpreter.get("literal_logic"));
    try std.testing.expectEqualStrings("hello", (try interpreter.get("message")).string);
    try std.testing.expectEqual(@as(u21, 'x'), (try interpreter.get("letter")).char);
    try std.testing.expectEqualStrings("ready", (try interpreter.get("status")).atom);
    try std.testing.expectEqualStrings("if", (try interpreter.get("quoted_atom")).atom);
    try std.testing.expectEqual(MaterializedValue{ .number = 2 }, try interpreter.get("first_item"));
    try std.testing.expectEqual(MaterializedValue{ .number = 2 }, try interpreter.get("items.0"));
    try std.testing.expectEqual(MaterializedValue{ .boolean = true }, try interpreter.get("same_atom"));
    const root_cursor = try interpreter.cursor();
    const items = try (try root_cursor.field("items")).array();
    try std.testing.expectEqual(@as(usize, 3), items.len());
    try std.testing.expectEqual(Value{ .number = 2 }, try (try items.item(0)).value());
    try std.testing.expectEqual(Value{ .number = 7 }, try (try items.item(1)).value());
    const nested_items = try (try items.item(2)).array();
    try std.testing.expectEqual(Value{ .boolean = true }, try (try nested_items.item(0)).value());
    try std.testing.expectEqual(Value{ .boolean = false }, try (try nested_items.item(1)).value());
    const materialized_items = (try (try root_cursor.field("items")).materialize()).array;
    try std.testing.expectEqual(MaterializedValue{ .number = 2 }, materialized_items[0]);
    try std.testing.expectEqual(MaterializedValue{ .boolean = false }, materialized_items[2].array[1]);

    const records = try (try root_cursor.field("records")).array();
    try std.testing.expectEqual(@as(usize, 2), records.len());
    const first_record = try (try records.item(0)).map();
    try std.testing.expectEqualStrings("first", (try (try first_record.field("name")).value()).string);
    try std.testing.expectEqual(
        Value{ .boolean = true },
        try (try (try first_record.field("nested")).field("enabled")).value(),
    );
    try std.testing.expectEqualStrings("second", (try (try (try records.item(1)).field("name")).value()).string);
    try std.testing.expectEqual(MaterializedValue{ .number = 42 }, try interpreter.get("projected"));
    try std.testing.expectEqual(@as(usize, 0), (try (try root_cursor.field("empty")).array()).len());

    try std.testing.expectError(error.ExpectedValue, root_cursor.value());
    const root_value = (try root_cursor.materialize()).record;
    try std.testing.expectEqualStrings("base", root_value[0].name);
    try std.testing.expectEqual(MaterializedValue{ .number = 2 }, root_value[0].value);
    const nested_cursor = try root_cursor.field("nested");
    const answer_cursor = try nested_cursor.field("answer");
    try std.testing.expectEqual(TreeCursor.Tag.map, root_cursor.tag());
    try std.testing.expectEqual(TreeCursor.Tag.map, nested_cursor.tag());
    try std.testing.expectEqual(TreeCursor.Tag.value, answer_cursor.tag());
    try std.testing.expectError(error.ExpectedValue, nested_cursor.value());
    const nested_value = (try nested_cursor.materialize()).record;
    try std.testing.expectEqualStrings("answer", nested_value[0].name);
    try std.testing.expectEqual(MaterializedValue{ .number = 6 }, nested_value[0].value);
    try std.testing.expectError(error.ExpectedMap, answer_cursor.map());
    try std.testing.expectEqual(Value{ .number = 6 }, try answer_cursor.value());
    try std.testing.expectEqual(
        Value{ .number = 6 },
        try (try (try root_cursor.field("nested")).field("answer")).value(),
    );
    try std.testing.expectError(error.InvalidPath, root_cursor.field(""));
}

test "identifiers use lexical map scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(),
        \\root_value = 5
        \\input = {
        \\  scale = 2
        \\  player = {
        \\    max_jump_height = 3.2
        \\    jump_time = 0.2
        \\    fall_time = 0.15
        \\    jump_initial_speed = [2 * max_jump_height / jump_time, scale]
        \\    gravity = -2 * max_jump_height / (fall_time * fall_time)
        \\    inherited = scale + root_value
        \\  }
        \\  items = [scale, { value = scale + root_value }]
        \\}
        \\shadow = {
        \\  root_value = 7
        \\  value = root_value
        \\}
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    var interpreter = init(std.testing.allocator, ast);
    defer interpreter.deinit();

    const input = try (try interpreter.cursor()).field("input");
    const player = try input.field("player");
    const jump = try (try player.field("jump_initial_speed")).array();
    try std.testing.expectEqual(Value{ .number = 32 }, try (try jump.item(0)).value());
    try std.testing.expectEqual(Value{ .number = 2 }, try (try jump.item(1)).value());
    try std.testing.expectApproxEqAbs(
        @as(f64, -284.44444444444446),
        (try (try player.field("gravity")).value()).number,
        0.000000000001,
    );
    try std.testing.expectEqual(Value{ .number = 7 }, try (try player.field("inherited")).value());
    const shadow = try (try interpreter.cursor()).field("shadow");
    try std.testing.expectEqual(Value{ .number = 7 }, try (try shadow.field("value")).value());

    const items = try (try input.field("items")).array();
    try std.testing.expectEqual(Value{ .number = 2 }, try (try items.item(0)).value());
    try std.testing.expectEqual(
        Value{ .number = 7 },
        try (try (try items.item(1)).field("value")).value(),
    );

    // Eager materialization keeps the same parent scopes while each container is marked as waiting.
    try std.testing.expectEqual(.record, std.meta.activeTag(try input.materialize()));
}

test "quoted identifiers can use keyword names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(),
        \\@"if" = 40
        \\@"true" = 2
        \\@"and" = @"if" + @"true"
        \\@"quote\"name" = "line\n\"two\"\\"
        \\quote = '\''
        \\nested = {
        \\  @"or\"else" = @"and"
        \\}
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    var interpreter = init(std.testing.allocator, ast);
    defer interpreter.deinit();

    try std.testing.expectEqual(MaterializedValue{ .number = 40 }, try interpreter.get("if"));
    try std.testing.expectEqual(MaterializedValue{ .number = 42 }, try interpreter.get("and"));
    try std.testing.expectEqual(MaterializedValue{ .number = 42 }, try interpreter.get("nested.or\"else"));
    try std.testing.expectEqualStrings("line\n\"two\"\\", (try interpreter.get("quote\"name")).string);
    try std.testing.expectEqual(@as(u21, '\''), (try interpreter.get("quote")).char);

    const nested_map = try (try (try interpreter.cursor()).field("nested")).map();
    var fields = nested_map.fields();
    try std.testing.expectEqualStrings("or\"else", (try fields.next()).?);
    try std.testing.expectEqual(null, try fields.next());
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
    try std.testing.expectEqualStrings("first", (try fields.next()).?);
    try std.testing.expectEqualStrings("broken", (try fields.next()).?);
    try std.testing.expectEqualStrings("last", (try fields.next()).?);
    try std.testing.expectEqual(null, try fields.next());
    try std.testing.expectEqual(evaluated_node_count, interpreter.node_states.count());
}

test "array cursor visits items without materializing the array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(),
        \\items = [
        \\  { name = "first" },
        \\  missing,
        \\  [3, missing]
        \\]
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    var interpreter = init(std.testing.allocator, ast);
    defer interpreter.deinit();

    const items_cursor = try (try interpreter.cursor()).field("items");
    try std.testing.expectEqual(TreeCursor.Tag.array, items_cursor.tag());
    try std.testing.expectError(error.ExpectedMap, items_cursor.map());

    const array_cursor = try items_cursor.array();
    const evaluated_node_count = interpreter.node_states.count();
    try std.testing.expectEqual(@as(usize, 3), array_cursor.len());
    var items = array_cursor.items();
    try std.testing.expectEqual(evaluated_node_count, interpreter.node_states.count());

    const first = (try items.next()).?;
    try std.testing.expectEqual(TreeCursor.Tag.map, first.tag());
    try std.testing.expectEqualStrings("first", (try (try first.field("name")).value()).string);

    try std.testing.expectError(error.UndefinedIdentifier, items.next());
    const nested = try (try items.next()).?.array();
    try std.testing.expectEqual(@as(usize, 2), nested.len());
    try std.testing.expectEqual(Value{ .number = 3 }, try (try nested.item(0)).value());
    try std.testing.expectEqual(null, try items.next());
    try std.testing.expectError(error.IndexOutOfBounds, array_cursor.item(3));
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
        \\recursive_map = { self = recursive_map }
        \\invalid_string = "\q"
        \\invalid_identifier = @"bad\q"
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    var interpreter = init(std.testing.allocator, ast);
    defer interpreter.deinit();

    try std.testing.expectError(error.MissingField, interpreter.get("missing"));
    const map = try (try (try interpreter.cursor()).field("map")).map();
    try std.testing.expectEqual(Value{ .number = 1 }, try (try map.field("value")).value());
    const recursive_map = try (try interpreter.cursor()).field("recursive_map");
    try std.testing.expectError(error.RecursiveDefinition, recursive_map.materialize());
    try std.testing.expectError(error.RecursiveDefinition, interpreter.get("cycle_a"));
    try std.testing.expectError(error.InvalidString, interpreter.get("invalid_string"));
    try std.testing.expectError(error.InvalidIdentifier, interpreter.get("invalid_identifier"));
}

test "host functions receive scalar cursors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(
        std.testing.allocator,
        arena.allocator(),
        "point = { value = 41 }; answer = increment point.value",
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;

    const bindings = [_]Binding{.{ .name = "increment", .value = .{ .function = .{ .call_fn = struct {
        fn increment(_: ?*anyopaque, argument: TreeCursor) EvaluationError!Value {
            return .{ .number = switch (try argument.value()) {
                .number => |number| number + 1,
                else => return error.UnexpectedType,
            } };
        }
    }.increment } } }};
    var interpreter = initWithBindings(std.testing.allocator, ast, &bindings);
    defer interpreter.deinit();

    try std.testing.expectEqual(MaterializedValue{ .number = 42 }, try interpreter.get("answer"));
}

test "host functions receive records and can return one field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(std.testing.allocator, arena.allocator(),
        \\movement = {
        \\  speed = dragFloat { value = 5; start = 0; end = 100; scale = .log }
        \\}
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;

    const DragFloat = struct {
        start: f64 = undefined,
        end: f64 = undefined,
        logarithmic: bool = undefined,

        fn call(context: ?*anyopaque, argument: TreeCursor) EvaluationError!Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const options = try argument.map();
            self.start = try numberField(options, "start");
            self.end = try numberField(options, "end");
            self.logarithmic = switch (try (try options.field("scale")).value()) {
                .atom => |atom| std.mem.eql(u8, atom, "log"),
                else => return error.UnexpectedType,
            };
            return .{ .number = try numberField(options, "value") };
        }

        fn numberField(options: MapCursor, name: []const u8) EvaluationError!f64 {
            return switch (try (try options.field(name)).value()) {
                .number => |number| number,
                else => error.UnexpectedType,
            };
        }
    };

    var drag_float: DragFloat = .{};
    const bindings = [_]Binding{.{ .name = "dragFloat", .value = .{ .function = .{
        .context = &drag_float,
        .call_fn = DragFloat.call,
    } } }};
    var interpreter = initWithBindings(std.testing.allocator, ast, &bindings);
    defer interpreter.deinit();

    try std.testing.expectEqual(MaterializedValue{ .number = 5 }, try interpreter.get("movement.speed"));
    try std.testing.expectEqual(@as(f64, 0), drag_float.start);
    try std.testing.expectEqual(@as(f64, 100), drag_float.end);
    try std.testing.expect(drag_float.logarithmic);
}

test "host function errors propagate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = try @import("Parse.zig").parse(
        std.testing.allocator,
        arena.allocator(),
        "value = requiredField {}",
    );
    defer ast.deinit(std.testing.allocator) catch unreachable;

    const bindings = [_]Binding{.{ .name = "requiredField", .value = .{ .function = .{ .call_fn = struct {
        fn call(_: ?*anyopaque, argument: TreeCursor) EvaluationError!Value {
            return (try (try argument.map()).field("missing")).value();
        }
    }.call } } }};
    var interpreter = initWithBindings(std.testing.allocator, ast, &bindings);
    defer interpreter.deinit();

    try std.testing.expectError(error.MissingField, interpreter.get("value"));
}
