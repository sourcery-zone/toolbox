const std = @import("std");
const clap = @import("clap");

const VERSION = "v0.0.1";

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
        \\<FILE>
        // TODO accept directory to generate report for all of the
        // files inside it, and maybe also traverse it recursively.
    );

    const when = enum { auto, always, only, never };
    const parser = comptime .{
        .STR = clap.parsers.string,
        .WHEN = clap.parsers.enumeration(when),
        .FILE = clap.parsers.string,
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
        const char_count = try getCharCount(file);
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

fn getCharCount(file: std.fs.File) !usize {
    var buf: [4096]u8 = undefined;
    var char_count: usize = 0;

    while (true) {
        const size = try file.read(&buf);
        if (size == 0) {
            break;
        }

        // TODO feature: add glyphs count too!
        char_count += try std.unicode.utf8CountCodepoints(buf[0..size]);
    }

    return char_count;
}
