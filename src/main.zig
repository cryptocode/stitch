//! The Stitch command line tool
const std = @import("std");
const Stitch = @import("lib.zig");
const StitchError = Stitch.StitchError;

/// The stitch command-line tool, implemented using the stitch library
pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    const backing_allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cmdline = try Cmdline.parseArgs(allocator);

    // Create a stitcher
    var stitcher = Stitch.initWriter(backing_allocator, cmdline.input_files_paths.values()[0], cmdline.output_file_path) catch |err| {
        switch (err) {
            StitchError.OutputFileAlreadyExists => {
                try std.io.getStdErr().writer().print("Output file already exists: {s}\n", .{cmdline.output_file_path});
                return 1;
            },
            else => return err,
        }
    };
    defer stitcher.deinit();

    // Add resources as specified on the command line
    for (cmdline.input_files_paths.values()[1..]) |path| {
        _ = try stitcher.addResourceFromPath(null, path);
    }

    // Commit changes to file
    stitcher.commit() catch |err| {
        if (stitcher.session.getDiagnostics()) |diagnostics| {
            try diagnostics.print(stitcher.session.arena.allocator());
        } else {
            try std.io.getStdErr().writer().print("Error: {s}\n", .{@errorName(err)});
        }
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
        \\
    ;

    // Input files to stitch
    input_files_paths: std.StringArrayHashMap([]const u8) = undefined,

    // If not specified, the output file will be the same as the first input file
    output_file_path: []const u8 = "",

    /// Loop through arguments and extract input files and output name
    /// The first input file is the binary onto which the rest of the files are stitched.
    /// Thus, at least two inputs must be given. The "--output <name>" argument is required
    /// and must appear at the end of the arguments.
    fn parseArgs(allocator: std.mem.Allocator) !*Cmdline {
        var cmdline = try allocator.create(Cmdline);
        cmdline.* = .{ .input_files_paths = std.StringArrayHashMap([]const u8).init(allocator), .output_file_path = "" };

        var arg_it = try std.process.argsWithAllocator(allocator);
        defer arg_it.deinit();
        if (!arg_it.skip()) @panic("Missing process argument");

        while (arg_it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--") and !std.mem.eql(u8, arg, "--output") and !std.mem.eql(u8, arg, "--version") and !std.mem.eql(u8, arg, "--help")) {
                try std.io.getStdErr().writer().print("Unknown argument: {s}\n\n", .{arg});
                try std.io.getStdErr().writer().print(help, .{});
                std.process.exit(0);
            }
            if (std.mem.eql(u8, arg, "--help")) {
                try std.io.getStdErr().writer().print(help, .{});
                std.process.exit(0);
            }
            if (std.mem.eql(u8, arg, "--version")) {
                // Format version determines the major version number
                try std.io.getStdOut().writer().print("stitch version {d}.0.0\n", .{Stitch.StitchVersion});
                std.process.exit(0);
            }
            if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
                if (arg_it.next()) |output| {
                    cmdline.output_file_path = output;
                    if (arg_it.next() != null) {
                        try std.io.getStdErr().writer().print("The last argument must be --output <filename>", .{});
                        std.process.exit(0);
                    }
                    break;
                }
            } else {
                // The filename is stored in the index, so it can be found by name. By using name=path, an alternative name can be given
                var it = std.mem.split(u8, arg, "=");
                var name = it.next();
                var second = it.next();
                const path = if (second != null) second.? else name.?;
                name = if (second == null) std.fs.path.basename(path) else name;
                std.debug.print("name: '{s}', path: '{s}'\n", .{ name.?, path });

                try cmdline.input_files_paths.put(try allocator.dupe(u8, name.?), try allocator.dupe(u8, path));
            }
        }

        if (cmdline.input_files_paths.count() < 2) {
            try std.io.getStdErr().writer().print("At least two input files are required\n", .{});
            try std.io.getStdErr().writer().print(help, .{});
            std.process.exit(0);
        }

        if (cmdline.output_file_path.len == 0) {
            cmdline.output_file_path = cmdline.input_files_paths.values()[0];
        }

        return cmdline;
    }
};
