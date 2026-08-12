const Writer = @import("std").Io.Writer;
const Tokenizer = @import("Tokenizer.zig");

pub fn writeIdentifier(name: []const u8, writer: *Writer) Writer.Error!void {
    if (isBareIdentifier(name) and Tokenizer.Token.getKeyword(name) == null) {
        try writer.writeAll(name);
    } else {
        try writer.writeByte('@');
        try writer.printStringEscaped(name);
    }
}

fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0 or !isIdentifierStart(name[0])) return false;
    for (name[1..]) |byte| {
        if (!isIdentifierContinue(byte)) return false;
    }
    return true;
}

fn isIdentifierStart(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '_' => true,
        else => false,
    };
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or switch (byte) {
        '0'...'9' => true,
        else => false,
    };
}
