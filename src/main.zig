//! The Stitch command line tool
const std = @import("std");
const Stitch = @import("stitch");
const StitchError = Stitch.StitchError;

/// The stitch command-line tool, implemented using the stitch library
pub fn main(init: std.process.Init) !u8 {
    StdWriters.initIdempotent(init.io);

    var gpa = std.heap.DebugAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    const backing_allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    var args_iter = ArgsIterator{ .args = args };
    const cmdline = try Cmdline.parseArgs(&args_iter, allocator);

    // Create a stitcher
    var stitcher = Stitch.initWriter(init.io, backing_allocator, cmdline.input_files_paths.values()[0], cmdline.output_file_path) catch |err| {
        switch (err) {
            StitchError.OutputFileAlreadyExists => {
                try StdWriters.err_writer.print("Output file already exists: {s}\n", .{cmdline.output_file_path});
                return 1;
            },
            else => return err,
        }
    };
    defer stitcher.deinit();

    // Add resources as specified on the command line
    for (cmdline.input_files_paths.values()[1..], cmdline.input_files_paths.keys()[1..]) |path, name| {
        _ = try stitcher.addResourceFromPath(name, path);
    }

    // Commit changes to file
    stitcher.commit() catch |err| {
        if (stitcher.session.getDiagnostics()) |diagnostics| {
            try diagnostics.print(stitcher.session.arena.allocator());
        } else {
            try StdWriters.err_writer.print("Error: {s}\n", .{@errorName(err)});
        }
        return 1;
    };

    return 0;
}

/// Command line parser. The argument syntax is simple enough to do this without an external lib.
///
/// First argument is the executable to stitch onto. If an output file is specified, the input executable will not be touched.
/// ./stitch /path/to/myexecutable file1.txt file2.txt --output myexecutable
///
/// Resources can be given a different name than the basename of the file
/// ./stitch my.exe script=main.js lib=lib.js --output my.exe
///
/// Note that --ouput is optional. If missing, the output file will be the same as the first input file (the executable)
/// ./stitch ./myexecutable file1.txt newname=file2.txt
pub const Cmdline = struct {
    const help =
        \\Usage:
        \\    stitch <executable> <resource>... [--output <output>]
        \\    stitch <executable> <name>=<resource>... [--output <output>]
        \\    stitch --version
        \\    stitch --help
        \\
    ;

    // Input files to stitch
    input_files_paths: std.array_hash_map.String([]const u8) = undefined,

    // If not specified, the output file will be the same as the first input file
    output_file_path: []const u8 = "",

    /// Print usage
    fn usage(exit_code: u8) noreturn {
        StdWriters.out_writer.print(help, .{}) catch unreachable;
        StdWriters.out_writer.flush() catch unreachable;
        std.process.exit(exit_code);
    }

    /// Loop through arguments and extract input files and output name
    /// The first input file is the binary onto which the rest of the files are stitched.
    /// Thus, at least two inputs must be given. The "--output <name>" argument is required
    /// and must appear at the end of the arguments.
    fn parseArgs(arg_it: *ArgsIterator, allocator: std.mem.Allocator) !*Cmdline {
        var cmdline = try allocator.create(Cmdline);
        cmdline.* = .{ .input_files_paths = .empty, .output_file_path = "" };

        if (!arg_it.skip()) @panic("Missing process argument");

        while (arg_it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--") and !std.mem.eql(u8, arg, "--output") and !std.mem.eql(u8, arg, "--version") and !std.mem.eql(u8, arg, "--help")) {
                try StdWriters.err_writer.print("Unknown argument: {s}\n\n", .{arg});
                usage(1);
            }
            if (std.mem.eql(u8, arg, "--help")) {
                usage(0);
            }
            if (std.mem.eql(u8, arg, "--version")) {
                // Format version determines the major version number
                try StdWriters.out_writer.print("stitch version {d}.0.0\n", .{Stitch.StitchVersion});
                try StdWriters.out_writer.flush();
                std.process.exit(0);
            }
            if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
                if (arg_it.next()) |output| {
                    cmdline.output_file_path = output;
                    if (arg_it.next() != null) {
                        try StdWriters.err_writer.print("The last argument must be --output <filename>", .{});
                        usage(1);
                    }
                    break;
                } else {
                    try StdWriters.err_writer.print("Missing filename after --output\n", .{});
                    usage(1);
                }
            } else {
                // The filename is stored in the index, so it can be found by name. By using name=path, an alternative name can be given
                var it = std.mem.splitScalar(u8, arg, '=');
                var name = it.next();
                const second = it.next();
                const path = if (second != null) second.? else name.?;
                name = if (second == null) std.fs.path.basename(path) else name;

                try cmdline.input_files_paths.put(allocator, try allocator.dupe(u8, name.?), try allocator.dupe(u8, path));
            }
        }

        if (cmdline.input_files_paths.count() < 2) {
            try StdWriters.err_writer.print("At least two input files are required\n", .{});
            usage(1);
        }

        if (cmdline.output_file_path.len == 0) {
            cmdline.output_file_path = cmdline.input_files_paths.values()[0];
        }

        return cmdline;
    }
};

const ArgsIterator = struct {
    args: []const []const u8,
    i: usize = 0,

    fn next(it: *@This()) ?[]const u8 {
        if (it.i >= it.args.len) {
            return null;
        }
        defer it.i += 1;
        return it.args[it.i];
    }

    fn skip(it: *@This()) bool {
        return it.next() != null;
    }
};

pub const StdWriters = struct {
    pub var out_writer: *std.Io.Writer = undefined;
    pub var err_writer: *std.Io.Writer = undefined;
    pub var out_buffer: [1024]u8 = undefined;
    pub var out_file_writer: std.Io.File.Writer = undefined;
    pub var err_file_writer: std.Io.File.Writer = undefined;
    pub var initialized: bool = false;

    pub fn initIdempotent(io: std.Io) void {
        if (!initialized) {
            out_file_writer = std.Io.File.stdout().writer(io, &out_buffer);
            out_writer = &out_file_writer.interface;

            // stderr is unbuffered, no flushing required
            err_file_writer = std.Io.File.stderr().writer(io, &.{});
            err_writer = &err_file_writer.interface;
            initialized = true;
        }
    }
};
