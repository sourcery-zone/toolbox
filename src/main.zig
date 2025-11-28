const std = @import("std");
const clap = @import("clap");
const testing = std.testing;

const VERSION = "v0.0.1";

const Encoding = enum { utf8, ascii };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("Memory leak");
    }
    const params = comptime clap.parseParamsComptime(
        \\-h, --help    print this message
        \\-c, --bytes   print the byte count
        \\-m, --chars   print the character counts
        \\-l, --lines   print the newline counts
        \\--files0-from <STR>   read input from files specified by NUL-terminated
        \\                      names in file F; If F is - then read names from standard input
        \\-L, --max-line-length   print the maximum display width
        \\-w, --words   print the word counts
        \\--total <WHEN>   when to print a line with total counts; WHEN can be: auto, always, only, never
        \\--version   output version information and exit
        \\--encoding <ENCODING>   set the file's encoding, used for character count
        \\--keep-bom   if set and the BOM character exists, also count it as a character
        \\<FILE>
        // TODO accept directory to generate report for all of the
        // files inside it, and maybe also traverse it recursively.
    );

    const when = enum { auto, always, only, never };
    const parser = comptime .{
        .STR = clap.parsers.string,
        .WHEN = clap.parsers.enumeration(when),
        .FILE = clap.parsers.string,
        .ENCODING = clap.parsers.enumeration(Encoding),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parser, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    const encoding = res.args.encoding orelse Encoding.utf8;
    const keep_bom = if (res.args.@"keep-bom" == 0) false else true;

    if (res.args.help != 0)
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});

    if (res.args.version != 0) {
        std.debug.print("{s}\n", .{VERSION});
        std.process.exit(0);
    }

    const file_path = res.positionals[0] orelse {
        std.debug.print("<FILE> is required!\n", .{});
        std.process.exit(1);
    };

    // const basename = std.fs.path.basename(file_path);

    // NOTE when using cwd(), it's also supporting the absolute path,
    // simply because, an absolute path relative to current working
    // directory, is equal to the absolute path itself.
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("Failed to read {s}: {}\n", .{ file_path, err });
        std.process.exit(2);
    };
    defer file.close();

    // -c: print bytes count
    if (res.args.bytes != 0) {
        const byte_count = getBytesCount(file);
        std.debug.print("bytes: {d}\n", .{byte_count});
    }

    // -m: print character count
    if (res.args.chars != 0) {
        const char_count = try getCharCount(file, encoding, keep_bom);
        std.debug.print("chars: {d}\n", .{char_count});
    }

    // TODO optimize by preferring byte count, when the maximum number
    // of bytes per character is equal to one:
    // https://github.com/coreutils/coreutils/blob/master/src/wc.c#L335
}

fn getBytesCount(file: std.fs.File) usize {
    return file.getEndPos() catch |err| {
        // TODO add file path to the error
        std.debug.print("Failed to get byte counts for: {}\n", .{err});
        std.process.exit(3);
    };
}

fn getCharCount(file: std.fs.File, encoding: Encoding, keep_bom: bool) !usize {
    var buf: [4096]u8 = undefined;
    var char_count: usize = 0;
    var first_chunk = true;
    var tail: [1024]u8 = undefined;
    var tail_len: usize = 0;

    while (true) {
        // TODO subject to error, for boundary split on chunk
        const size = try file.read(&buf);

        var input: [4096 + 4]u8 = undefined;

        // TODO what happens if size is 0
        if (tail_len != 0) {
            @memcpy(input[0..tail_len], tail[0..tail_len]);
            @memcpy(input[tail_len .. size + tail_len], buf[0..size]);
            tail_len = 0;
        } else {
            @memcpy(input[0..size], buf[0..size]);
        }

        if (size == 0) {
            break;
        }
        const sequence_length = try std.unicode.utf8ByteSequenceLength(input[0]);

        var start: u8 = 0;
        if (first_chunk and !keep_bom and encoding == .utf8) {
            if (input.len >= 3 and input[0] == 0xEF and input[1] == 0xBB and input[2] == 0xBF) {
                start = 3;
            }

            first_chunk = false;
        } else if (first_chunk) {
            first_chunk = false;
        }

        // check if the slice is containing a set of full characters,
        // if not, reserve it for the next iteration
        const remainder = (size - start) % sequence_length;
        const end = blk: {
            tail_len = remainder;
            const tail_start = size - remainder;
            if (remainder != 0) {
                @memcpy(tail[0..tail_len], input[tail_start..size]);
                break :blk tail_start;
            } else {
                break :blk size;
            }
        };

        // TODO feature: add glyphs count too!
        char_count += try std.unicode.utf8CountCodepoints(input[start..end]);
    }

    return char_count;
}

fn countFromBytes(bytes: []const u8, enc: Encoding, keep_bom: bool) !usize {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "f", .data = bytes });
    var f = try tmp.dir.openFile("f", .{ .mode = .read_only });
    defer f.close();

    return getCharCount(f, enc, keep_bom);
}

test "ASCII: simple count" {
    const n = try countFromBytes("Hello", .utf8, false);
    try testing.expectEqual(@as(usize, 5), n);
}

test "UTF-8: basic multibyte (emoji)" {
    // "a😀b" -> 3 code points; bytes: 61 F0 9F 98 80 62
    const n = try countFromBytes("a" ++ "\xF0\x9F\x98\x80" ++ "b", .utf8, false);
    try testing.expectEqual(@as(usize, 3), n);
}

test "UTF-8 BOM: skipped when keep_bom=false" {
    const n = try countFromBytes("\xEF\xBB\xBF" ++ "abc", .utf8, false);
    try testing.expectEqual(@as(usize, 3), n);
}

test "UTF-8 BOM: counted when keep_bom=true" {
    const n = try countFromBytes("\xEF\xBB\xBF" ++ "abc", .utf8, true);
    try testing.expectEqual(@as(usize, 4), n);
}

test "EOF with incomplete trailing sequence is ignored (current behavior)" {
    // Single leading byte 0xC2 (expects 2 bytes); current impl drops it at EOF
    // FIXME
    const n1 = try countFromBytes("\xC2", .utf8, false);
    try testing.expectEqual(@as(usize, 0), n1);

    // 'A' followed by dangling 0xC2 -> counts 'A' only
    // TODO This error for user is ugly, fix it
    const n2 = countFromBytes("A" ++ "\xC2", .utf8, false);
    try testing.expectError(error.TruncatedInput, n2);
}

test "Split multi-byte at 4096 boundary triggers InvalidUtf8 (current bug acknowledged)" {
    // Create 4096 bytes with last byte a leading 2-byte sequence
    // starter (0xC2) without its continuation.
    var buf: [4096]u8 = undefined;
    @memset(buf[0..], 'A');
    buf[4095] = 0xC2;

    // This currently passes the whole chunk to utf8CountCodepoints and errors.
    try testing.expectError(
        error.TruncatedInput,
        countFromBytes(&buf, .utf8, false),
    );
}
