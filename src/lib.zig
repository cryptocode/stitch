//! The Stitch library and C wrapper
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Self = @This();

arena: std.heap.ArenaAllocator,
rw: union(enum) {
    writer: StitchWriter,
    reader: StitchReader,
} = undefined,

/// This is set whenever a StitchError is returned
diagnostics: ?Diagnostic = null,

/// The executable to read from, or write to if stitching to the original
org_exe_file: std.fs.File = undefined,

/// The output executable. If this is null, the resources will be stitched to the original
output_exe_file: ?std.fs.File = null,

pub const ResourceMagic: u64 = 0x18c767a11ea80843;
pub const EofMagic: u64 = 0xa2a7fdfa0533438f;
pub const StitchVersion: u8 = 0x1;

const StitchExecutable = struct {
    resources: std.ArrayList(Resource),
    index: Index,
    tail: Tail,
};

const Index = struct {
    entries: std.ArrayList(IndexEntry),
};

const IndexEntry = struct {
    name: []const u8,
    resource_type: u8,
    resource_offset: u64,
    byte_length: u64,
    scratch_bytes: [8]u8,
};

const Tail = struct {
    index_offset: u64,
    version: u8,
    eof_magic: u64,
};

const ResourceType = enum {
    bytes,
    path,
    reader,
};

const Resource = struct {
    magic: u64,
    data: union(ResourceType) {
        bytes: []const u8,
        path: []const u8,
        reader: *std.Io.Reader,
    },
};

/// This is the type of error returned by all API functions. No other errors are ever returned.
pub const StitchError = error{ OutputFileAlreadyExists, CouldNotOpenInputFile, CouldNotOpenOutputFile, InvalidExecutableFormat, ResourceNotFound, IoError };

/// Diagnostic is available through `getDiagnostics` whenever an error is returned.
pub const Diagnostic = union(std.meta.FieldEnum(StitchError)) {
    /// Path to output file that already exists
    OutputFileAlreadyExists: []const u8,
    /// Could not open input file, typically due to not existing, or lack of read permissions
    CouldNotOpenInputFile: []const u8,
    /// Could not open output file, typically due to lack of write permissions
    CouldNotOpenOutputFile: []const u8,
    /// Reason for invalid format
    InvalidExecutableFormat: []const u8,
    // No resource can be found by the given name or index
    ResourceNotFound: union(enum) {
        name: []const u8,
        index: u64,
    },
    // IO error description
    IoError: []const u8,

    /// Print a diagnostic error to stderr
    pub fn print(self: Diagnostic, str_alloc: std.mem.Allocator) !void {
        std.debug.print("{s}\n", .{try self.toOwnedString(str_alloc)});
    }

    /// Return the diagnostic as a string. Caller must free the string.
    pub fn toOwnedString(self: Diagnostic, str_alloc: std.mem.Allocator) ![]const u8 {
        switch (self) {
            .OutputFileAlreadyExists => return try std.fmt.allocPrint(str_alloc, "Output file already exists: {s}\n", .{self.OutputFileAlreadyExists}),
            .CouldNotOpenInputFile => return try std.fmt.allocPrint(str_alloc, "Could not open input file: {s}\n", .{self.CouldNotOpenInputFile}),
            .CouldNotOpenOutputFile => return try std.fmt.allocPrint(str_alloc, "Could not open output file: {s}\n", .{self.CouldNotOpenOutputFile}),
            .InvalidExecutableFormat => return try std.fmt.allocPrint(str_alloc, "Invalid executable format: {s}\n", .{self.InvalidExecutableFormat}),
            .ResourceNotFound => switch (self.ResourceNotFound) {
                .name => return try std.fmt.allocPrint(str_alloc, "Resource name not found: {s}\n", .{self.ResourceNotFound.name}),
                .index => return try std.fmt.allocPrint(str_alloc, "Resource index not found: {d}\n", .{self.ResourceNotFound.index}),
            },
            .IoError => return try std.fmt.allocPrint(str_alloc, "IO error: {s}\n", .{self.IoError}),
        }
    }

    /// Determine if an error is a diagnostic error
    pub fn isDiagnostic(err: anyerror) bool {
        inline for (std.meta.fields(Diagnostic)) |field| {
            if (std.mem.eql(u8, field.name, @errorName(err))) {
                return true;
            }
        }
        return false;
    }
};

/// It is guaranteed that if an error is returned by a public reader or writer session function,
/// the diagnostic will be set. The diagnostic is reset to null at the beginning of each public function.
pub fn getDiagnostics(session: *Self) ?Diagnostic {
    return session.diagnostics orelse null;
}

// Called by all API functions to ensure that diagnostics is set only if a StitchError occurs
fn resetDiagnostics(session: *Self) void {
    session.diagnostics = null;
}

/// Intialize a stitch session for writing.
/// This returns a `StitchWriter`, which can be used to add resources to the input executable.
/// The input and output paths can be the same, in which case resources are appended to the original executable.
pub fn initWriter(allocator: std.mem.Allocator, input_executable_path: []const u8, output_executable_path: []const u8) !StitchWriter {
    var session = try allocator.create(Self);
    errdefer allocator.destroy(session);
    session.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    const arena_allocator = session.arena.allocator();
    errdefer session.arena.deinit();

    const absolute_input_path = std.fs.realpathAlloc(arena_allocator, input_executable_path) catch return StitchError.CouldNotOpenInputFile;
    session.org_exe_file = std.fs.openFileAbsolute(absolute_input_path, .{ .mode = .read_write }) catch return StitchError.CouldNotOpenInputFile;

    // Output path does not need to exists; since we use cwd().createFile, path doesn't need to be absolute
    // We still attempt realpath to detect if we're stitching on the original
    const absolute_output_path = realpathOrOriginal(arena_allocator, output_executable_path) catch return StitchError.CouldNotOpenOutputFile;
    const stitch_to_original = std.mem.eql(u8, absolute_input_path, absolute_output_path);

    if (!stitch_to_original) {
        session.output_exe_file = std.fs.cwd().createFile(absolute_output_path, .{ .exclusive = true, .truncate = false }) catch |err| switch (err) {
            std.fs.File.OpenError.PathAlreadyExists => {
                return StitchError.OutputFileAlreadyExists;
            },
            else => return err,
        };
    }

    session.rw = .{ .writer = StitchWriter.init(session) };
    return session.rw.writer;
}

/// Same as realpathAlloc, except it returns the original path if the path
/// doesn't exist rather than an error
fn realpathOrOriginal(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fs.realpathAlloc(allocator, path) catch |err| {
        if (err == error.FileNotFound) {
            return path;
        } else {
            return err;
        }
    };
}

/// Intialize a stitch session for reading
/// This returns a StitchReader, which can be used to read resources from the executable
/// If path is null, the currently running executable will be used
pub fn initReader(allocator: std.mem.Allocator, path: ?[]const u8) !StitchReader {
    var session = try allocator.create(Self);
    errdefer allocator.destroy(session);
    session.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .rw = .{ .reader = StitchReader.init(session) },
    };
    errdefer session.arena.deinit();

    if (path) |_| {
        session.org_exe_file = try std.fs.openFileAbsolute(
            try std.fs.realpathAlloc(allocator, path.?),
            .{ .mode = .read_only },
        );
    } else {
        session.org_exe_file = try std.fs.openSelfExe(.{ .mode = .read_only });
    }

    try session.rw.reader.readMetadata();
    return session.rw.reader;
}

// Called by a reader or writer's deinit function to free the session resources
fn deinit(session: *Self) void {
    session.org_exe_file.close();
    if (session.output_exe_file) |f| f.close();
    var child_allocator = session.arena.child_allocator;
    session.arena.deinit();
    child_allocator.destroy(session);
}

/// Use `initWriter` to create this writer, which allows you to append resources to an executable in
/// a format recognized by `StitchReader`
pub const StitchWriter = struct {
    session: *Self = undefined,
    exe: StitchExecutable = undefined,

    fn init(session: *Self) StitchWriter {
        return .{
            .session = session,
            .exe = .{
                .resources = std.ArrayList(Resource).empty,
                .index = .{ .entries = std.ArrayList(IndexEntry).empty },
                .tail = .{ .index_offset = 0, .version = 0, .eof_magic = EofMagic },
            },
        };
    }

    /// Closes the stitch session and frees all resources.
    /// This must be called to ensure the writer session is properly closed.
    pub fn deinit(writer: *StitchWriter) void {
        writer.session.deinit();
    }

    /// Write original executable, index, resources, and tail to output file.
    pub fn commit(writer: *StitchWriter) StitchError!void {
        // Wrapper to reclassify errors into StitchError.IoError
        return commitImpl(writer) catch |err| {
            if (!Diagnostic.isDiagnostic(err)) {
                writer.session.diagnostics = .{ .IoError = "Unable to commit resources to output file" };
                return StitchError.IoError;
            }
            return @as(StitchError, @errorCast(err));
        };
    }

    fn commitImpl(writer: *StitchWriter) !void {
        writer.session.resetDiagnostics();
        var outfile = writer.session.output_exe_file orelse writer.session.org_exe_file;
        var out_buff: [4096]u8 = undefined;
        var file_writer = outfile.writer(&out_buff);
        var stream = &file_writer.interface;

        // Write original executable if we're not stitching to the original, otherwise seek to the end of original
        if (writer.session.output_exe_file != null) {
            var rbuf: [4096]u8 = undefined;
            var r = writer.session.org_exe_file.reader(&rbuf);
            const ri = &r.interface;

            _ = try ri.streamRemaining(stream);

            // Flush to ensure the file length is correct when queried
            try stream.flush();
        } else {
            file_writer.pos = try outfile.getEndPos();
        }

        // No resources = write empty tail
        if (writer.exe.resources.items.len == 0) {
            try stream.writeInt(u64, 0, .big);
            try stream.writeByte(StitchVersion);
            try stream.writeInt(u64, EofMagic, .big);
            try stream.flush();
            return;
        }

        const arena_allocator = writer.session.arena.allocator();

        // Keeps track of offsets relative to the end of th original executable
        // This is used to compute resource indices
        var resource_offsets = std.ArrayList(u64).empty;
        var resource_lengths = std.ArrayList(u64).empty;

        // Append resources, each prefixed with resource magic
        for (writer.exe.resources.items) |*item| {
            const before_pos = file_writer.pos;
            try resource_offsets.append(arena_allocator, before_pos);

            try stream.writeInt(u64, ResourceMagic, .big);
            switch (item.data) {
                .bytes => {
                    try stream.writeAll(item.data.bytes);
                },
                .reader => {
                    _ = try item.data.reader.streamRemaining(stream);
                },
                .path => {
                    var file = std.fs.cwd().openFile(item.data.path, .{ .mode = .read_only }) catch |err| switch (err) {
                        std.fs.File.OpenError.FileNotFound => {
                            writer.session.diagnostics = .{ .CouldNotOpenInputFile = item.data.path };
                            return StitchError.CouldNotOpenInputFile;
                        },
                        else => return err,
                    };
                    defer file.close();

                    var rbuf: [4096]u8 = undefined;
                    var r = file.reader(&rbuf);
                    const ri = &r.interface;
                    _ = try ri.streamRemaining(stream);
                },
            }

            // Flush to update position, then compute and write the length of the resource
            try stream.flush();
            try resource_lengths.append(arena_allocator, file_writer.pos - before_pos - 8);
        }

        try stream.flush();
        const index_offset = file_writer.pos;

        // Write the index
        try stream.writeInt(u64, writer.exe.index.entries.items.len, .big);
        for (writer.exe.index.entries.items, 0..) |*entry, i| {
            try stream.writeInt(u64, entry.name.len, .big);
            try stream.writeAll(entry.name);
            try stream.writeByte(entry.resource_type);
            try stream.writeInt(u64, resource_offsets.items[i], .big);
            try stream.writeInt(u64, resource_lengths.items[i], .big);
            try stream.writeAll(&entry.scratch_bytes);
        }

        // Write the tail
        try stream.writeInt(u64, index_offset, .big);
        try stream.writeByte(StitchVersion);
        try stream.writeInt(u64, EofMagic, .big);
        try stream.flush();
    }

    /// Set the scratch bytes for a resource, using the index returned by the addResource... functions.
    /// The default scratch bytes is all-zero.
    pub fn setScratchBytes(writer: *StitchWriter, resource_index: u64, bytes: [8]u8) StitchError!void {
        writer.session.resetDiagnostics();
        if (resource_index >= writer.exe.index.entries.items.len) {
            writer.session.diagnostics = .{ .ResourceNotFound = .{ .index = resource_index } };
            return StitchError.ResourceNotFound;
        }
        writer.exe.index.entries.items[resource_index].scratch_bytes = bytes;
    }

    /// Reads the file at `path` and adds it to the list of resources to be written
    /// This option has minimal memory overhead
    /// If name is null, the name of the resource will be the basename of the path
    /// Returns the zero-based resource index
    pub fn addResourceFromPath(writer: *StitchWriter, name: ?[]const u8, path: []const u8) !u64 {
        const arena_allocator = writer.session.arena.allocator();
        writer.session.resetDiagnostics();
        try writer.exe.resources.append(arena_allocator, Resource{ .magic = ResourceMagic, .data = .{ .path = path } });
        try writer.exe.index.entries.append(arena_allocator, IndexEntry{
            .name = if (name != null) name.? else std.fs.path.basename(path),
            .resource_type = 0,
            .resource_offset = 0,
            .byte_length = 0,
            .scratch_bytes = [_]u8{0} ** 8,
        });

        return writer.exe.resources.items.len - 1;
    }

    /// Adds the reader to the list of resources
    /// This option has minimal memory overhead
    /// The reader must stay valid until the the Stitch session is closed
    /// Returns the zero-based resource index
    pub fn addResourceFromReader(writer: *StitchWriter, name: []const u8, reader: *std.Io.Reader) !u64 {
        writer.session.resetDiagnostics();

        const arena_allocator = writer.session.arena.allocator();
        try writer.exe.resources.append(arena_allocator, Resource{ .magic = ResourceMagic, .data = .{ .reader = reader } });
        try writer.exe.index.entries.append(arena_allocator, IndexEntry{
            .name = name,
            .resource_type = 0,
            .resource_offset = 0,
            .byte_length = 0,
            .scratch_bytes = [_]u8{0} ** 8,
        });

        return writer.exe.resources.items.len - 1;
    }

    /// Adds the slice to the list of resources
    /// The provided `data` buffer must stay valid until `commit` is called
    /// Returns the zero-based resource index
    pub fn addResourceFromSlice(writer: *StitchWriter, name: []const u8, data: []const u8) !u64 {
        writer.session.resetDiagnostics();

        const arena_allocator = writer.session.arena.allocator();
        try writer.exe.resources.append(arena_allocator, Resource{ .magic = ResourceMagic, .data = .{ .bytes = data } });
        try writer.exe.index.entries.append(arena_allocator, IndexEntry{
            .name = name,
            .resource_type = 0,
            .resource_offset = 0,
            .byte_length = data.len,
            .scratch_bytes = [_]u8{0} ** 8,
        });

        return writer.exe.resources.items.len - 1;
    }
};

/// Reads the span of a resource, seeking to the start of the resource on first read
/// and returning EOF if reading beyond the end of the resource.
/// Use `StitchReader.getResourceReader` to create this reader.
pub const StitchResourceReader = struct {
    file: std.fs.File,
    offset: u64,
    length: u64 = 0,
    has_read_yet: bool = false,

    pub fn readResourceOwned(self: *StitchResourceReader, allocator: std.mem.Allocator) ![]const u8 {
        var buff: [4096]u8 = undefined;
        var r = self.file.reader(&buff);
        r.pos = self.offset;
        const ri = &r.interface;
        return try ri.readAlloc(allocator, self.length);
    }
};

fn stitchResourceReader(file: std.fs.File, offset: u64, length: u64) StitchResourceReader {
    return .{ .offset = offset, .file = file, .length = length };
}

/// Use `initReader` to create this reader, which allows you to read resources from a stitch file.
pub const StitchReader = struct {
    session: *Self,
    exe: StitchExecutable = undefined,

    fn init(session: *Self) StitchReader {
        return .{
            .session = session,
            .exe = .{
                .resources = std.ArrayList(Resource).empty,
                .index = .{ .entries = std.ArrayList(IndexEntry).empty },
                .tail = .{ .index_offset = 0, .version = 0, .eof_magic = EofMagic },
            },
        };
    }

    /// Closes the stitch reader session, freeing all resources
    pub fn deinit(reader: *StitchReader) void {
        reader.session.deinit();
    }

    pub fn readMetadata(reader: *StitchReader) !void {
        reader.session.resetDiagnostics();
        const len = try reader.session.org_exe_file.getEndPos();
        if (len < 17) {
            reader.session.diagnostics = .{ .InvalidExecutableFormat = "File too short to contain stitch metadata" };
            return StitchError.InvalidExecutableFormat;
        }

        // Read the tail
        var read_buffer: [8]u8 = undefined;
        var exe_reader = reader.session.org_exe_file.reader(&read_buffer);
        exe_reader.pos = try reader.session.org_exe_file.getEndPos() - 17;
        var in = &exe_reader.interface;

        const index_offset = try in.takeInt(u64, .big);
        reader.exe.tail.version = try in.takeByte();
        reader.exe.tail.eof_magic = try in.takeInt(u64, .big);
        if (reader.exe.tail.eof_magic != EofMagic) {
            reader.session.diagnostics = .{ .InvalidExecutableFormat = "Invalid stitch EOF magic" };
            return StitchError.InvalidExecutableFormat;
        }

        // No index means there are no resources
        if (index_offset == 0) return;

        // Seek to the index, and read it
        var ally = reader.session.arena.allocator();
        exe_reader.pos = index_offset;
        const entry_count = try in.takeInt(u64, .big);
        for (0..entry_count) |_| {
            const name_len = try in.takeInt(u64, .big);
            const name: []const u8 = _: {
                if (name_len == 0) break :_ "";
                const buffer = try ally.alloc(u8, name_len);
                _ = try in.readSliceAll(buffer);
                break :_ buffer;
            };
            const resource_type = try in.takeByte();
            const resource_offset = try in.takeInt(u64, .big);
            const byte_length = try in.takeInt(u64, .big);
            const scratch_bytes = _: {
                const buffer = try ally.alloc(u8, 8);
                _ = try in.readSliceAll(buffer);
                break :_ buffer;
            };

            try reader.exe.index.entries.append(reader.session.arena.allocator(), IndexEntry{
                .name = name,
                .resource_type = resource_type,
                .resource_offset = resource_offset,
                .byte_length = byte_length,
                .scratch_bytes = scratch_bytes[0..8].*,
            });
        }
    }

    /// Returns the version of the stitch format used to write the executable
    pub fn getFormatVersion(reader: *StitchReader) u8 {
        return reader.exe.tail.version;
    }

    /// Given a resource name, returns the index of the resource. This can be passed
    /// to `getResourceAsSlice` or `getResourceReader` to read the resource.
    pub fn getResourceIndex(reader: *StitchReader, name: []const u8) !usize {
        reader.session.resetDiagnostics();
        for (reader.exe.index.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.name, name)) return index;
        }

        reader.session.diagnostics = .{ .ResourceNotFound = .{ .name = "Resource not found" } };
        return StitchError.ResourceNotFound;
    }

    /// Returns the size of the resource in bytes.
    pub fn getResourceSize(reader: *StitchReader, resource_index: usize) !u64 {
        reader.session.resetDiagnostics();
        if (resource_index > reader.exe.index.entries.items.len) {
            reader.session.diagnostics = .{ .ResourceNotFound = .{ .index = resource_index } };
            return StitchError.ResourceNotFound;
        }
        return reader.exe.index.entries.items[resource_index].byte_length;
    }

    /// Fully reads the resource into memory and returns it. The memory is freed when the session is closed.
    pub fn getResourceAsSlice(reader: *StitchReader, resource_index: usize) ![]const u8 {
        reader.session.resetDiagnostics();
        if (resource_index > reader.exe.index.entries.items.len) {
            reader.session.diagnostics = .{ .ResourceNotFound = .{ .index = resource_index } };
            return StitchError.ResourceNotFound;
        }

        var arena_allocator = reader.session.arena.allocator();

        // Get the offset from the index and read the resource
        const offset = reader.exe.index.entries.items[resource_index].resource_offset;
        const length = reader.exe.index.entries.items[resource_index].byte_length;

        var buffer: [4096]u8 = undefined;
        var freader = reader.session.org_exe_file.reader(&buffer);
        var file_reader = &freader.interface;
        freader.pos = offset;

        const resource_magic = file_reader.takeInt(u64, .big) catch {
            reader.session.diagnostics = .{ .IoError = "Failed to read resource magic" };
            return StitchError.IoError;
        };

        if (resource_magic != ResourceMagic) {
            reader.session.diagnostics = .{ .InvalidExecutableFormat = "Invalid resource magic" };
            return StitchError.InvalidExecutableFormat;
        }

        const all_buffer = try arena_allocator.alloc(u8, length);
        _ = file_reader.readSliceAll(all_buffer) catch {
            reader.session.diagnostics = .{ .IoError = "Failed to read resource bytes" };
            return StitchError.IoError;
        };
        return all_buffer;
    }

    /// Returns a file reader for the resource. The reader is closed when the session is closed.
    /// This option requires the least amount of memory.
    pub fn getResourceReader(reader: *StitchReader, resource_index: usize) StitchError!StitchResourceReader {
        reader.session.resetDiagnostics();
        if (resource_index > reader.exe.index.entries.items.len) {
            reader.session.diagnostics = .{ .ResourceNotFound = .{ .index = resource_index } };
            return StitchError.ResourceNotFound;
        }

        // Get offset and length from the index
        const offset = reader.exe.index.entries.items[resource_index].resource_offset;
        const length = reader.exe.index.entries.items[resource_index].byte_length;

        var buf: [8]u8 = undefined;
        var freader = reader.session.org_exe_file.reader(&buf);
        freader.pos = offset;
        const file_reader = &freader.interface;

        const resource_magic = file_reader.takeInt(u64, .big) catch {
            reader.session.diagnostics = .{ .IoError = "Failed to read resource magic" };
            return StitchError.IoError;
        };
        if (resource_magic != ResourceMagic) {
            reader.session.diagnostics = .{ .InvalidExecutableFormat = "Invalid resource magic" };
            return StitchError.InvalidExecutableFormat;
        }

        return stitchResourceReader(reader.session.org_exe_file, offset + 8, length);
    }

    /// Returns the scratch bytes for the resource, which is all-zeros if not set specifically.
    pub fn getScratchBytes(reader: *StitchReader, resource_index: usize) ![]const u8 {
        reader.session.resetDiagnostics();
        if (resource_index > reader.exe.index.entries.items.len) {
            reader.session.diagnostics = .{ .ResourceNotFound = .{ .index = resource_index } };
            return StitchError.ResourceNotFound;
        }

        return &reader.exe.index.entries.items[resource_index].scratch_bytes;
    }

    /// Returns the total number of resources in the executable. This may be zero.
    pub fn getResourceCount(reader: *StitchReader) u64 {
        return reader.exe.index.entries.items.len;
    }
};

/// Returns the path to the currently running executable.
/// It's usually not necessary to call this function directly.
pub fn getSelfPath(session: *Self) StitchError![]const u8 {
    return std.fs.selfExeDirPathAlloc(session.arena.allocator()) catch return StitchError.IoError;
}

/// Reads the entire contents of a file and returns it as a byte slice.
/// The memory is freed when the session is closed.
pub fn readEntireFile(session: *Self, path: []const u8) StitchError![]const u8 {
    var arena_allocator = session.arena.allocator();
    errdefer {
        session.diagnostics = .{ .IoError = "Failed to read file" };
    }
    const absolute_path = std.fs.realpathAlloc(arena_allocator, path) catch return StitchError.IoError;
    var file = std.fs.openFileAbsolute(absolute_path, .{ .mode = .read_write }) catch return StitchError.IoError;
    defer file.close();
    var file_reader = file.reader(&.{});
    var reader = &file_reader.interface;
    const file_size = file.getEndPos() catch return StitchError.IoError;
    const buffer = arena_allocator.alloc(u8, file_size) catch return StitchError.IoError;
    _ = reader.readSliceAll(buffer) catch return StitchError.IoError;
    return buffer;
}

// Create a tempoary directory structure with a few files for testing
pub fn testSetup() !void {
    // Clean up in case the previous test run terminated early
    testTeardown();

    // Create the directory structure
    try std.fs.cwd().makeDir(".stitch");
    try std.fs.cwd().makeDir(".stitch/subdir");

    {
        var file = try std.fs.cwd().createFile(".stitch/executable", .{});
        defer file.close();

        var file_writer = file.writer(&.{});
        const writer = &file_writer.interface;
        try writer.writeAll("Executable bytes goes here");
    }
    {
        var file = try std.fs.cwd().createFile(".stitch/one.txt", .{});
        defer file.close();

        var file_writer = file.writer(&.{});
        const writer = &file_writer.interface;
        try writer.writeAll("Hello world");
    }
    {
        var file = try std.fs.cwd().createFile(".stitch/two.txt", .{});
        defer file.close();

        var file_writer = file.writer(&.{});
        const writer = &file_writer.interface;
        try writer.writeAll("Hello\nWorld");
    }
    {
        var file = try std.fs.cwd().createFile(".stitch/three.txt", .{});
        defer file.close();

        var file_writer = file.writer(&.{});
        const writer = &file_writer.interface;
        try writer.writeAll("A third file");
    }
}

// Delete the temporary directory structure
pub fn testTeardown() void {
    std.fs.cwd().deleteFile(".stitch/executable") catch {};
    std.fs.cwd().deleteFile(".stitch/new-executable") catch {};
    std.fs.cwd().deleteFile(".stitch/one.txt") catch {};
    std.fs.cwd().deleteFile(".stitch/two.txt") catch {};
    std.fs.cwd().deleteFile(".stitch/three.txt") catch {};
    std.fs.cwd().deleteDir(".stitch/subdir") catch {};
    std.fs.cwd().deleteDir(".stitch") catch {};
}

// Create a cryptographically unique filename; mostly useful for test purposes
pub fn generateUniqueFileName(allocator: std.mem.Allocator) ![]const u8 {
    var output: [16]u8 = undefined;
    var secret_seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    std.crypto.random.bytes(&secret_seed);
    var csprng = std.Random.DefaultCsprng.init(secret_seed);
    const random = csprng.random();
    random.bytes(&output);

    // Allocate enough for the hex string, plus the ".tmp" suffix
    const buf = try allocator.alloc(u8, output.len * 2 + 4);
    return std.fmt.bufPrint(buf, "{x}.tmp", .{output});
}

/// C ABI exported interface. See stitch.h for function-level documentation.
///
/// This follows the pthreads C API design, where a stitch session is an opaque pointer and all functions
/// are called with the session as the first argument. C ABI clients never deals with structs or enums directly.
///
/// To interact with stich from C, a writer or reader session must be created.
/// All returned data is owned by the session. Copy any data you need to keep after the session is closed,
/// or keep the session open until you are done with the data.
pub export fn stitch_init_writer(input_executable_path: ?[*:0]const u8, output_executable_path: ?[*:0]const u8, error_code: *u64) callconv(.c) ?*anyopaque {
    error_code.* = 0;
    if (input_executable_path == null) {
        error_code.* = translateError(StitchError.CouldNotOpenInputFile);
        return null;
    }
    const allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.smp_allocator;
    const writer = initWriter(allocator, std.mem.span(input_executable_path.?), if (output_executable_path) |path| std.mem.span(path) else std.mem.span(input_executable_path.?)) catch |err| {
        error_code.* = translateError(err);
        return null;
    };
    return writer.session;
}

pub export fn stitch_init_reader(executable_path: ?[*:0]const u8, error_code: *u64) callconv(.c) ?*anyopaque {
    error_code.* = 0;
    if (executable_path == null) {
        error_code.* = translateError(StitchError.CouldNotOpenInputFile);
        return null;
    }
    const allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.smp_allocator;
    const reader = initReader(allocator, if (executable_path) |p| std.mem.span(p) else null) catch |err| {
        error_code.* = translateError(err);
        return null;
    };
    return reader.session;
}

pub export fn stitch_deinit(session: *anyopaque) callconv(.c) void {
    fromC(session).deinit();
}

pub export fn stitch_reader_get_resource_count(reader: *anyopaque) callconv(.c) u64 {
    return fromC(reader).rw.reader.getResourceCount();
}

pub export fn stitch_reader_get_format_version(reader: *anyopaque) callconv(.c) u8 {
    return fromC(reader).rw.reader.getFormatVersion();
}

pub export fn stitch_reader_get_resource_index(reader: *anyopaque, name: [*:0]const u8, error_code: *u64) callconv(.c) u64 {
    return fromC(reader).rw.reader.getResourceIndex(std.mem.span(name)) catch |err| {
        error_code.* = translateError(err);
        return std.math.maxInt(u64);
    };
}

pub export fn stitch_reader_get_resource_byte_len(reader: *anyopaque, resource_index: u64, error_code: *u64) callconv(.c) u64 {
    return fromC(reader).rw.reader.getResourceSize(resource_index) catch |err| {
        error_code.* = translateError(err);
        return std.math.maxInt(u64);
    };
}

pub export fn stitch_reader_get_resource_bytes(reader: *anyopaque, resource_index: u64, error_code: *u64) callconv(.c) ?[*]const u8 {
    const slice = fromC(reader).rw.reader.getResourceAsSlice(resource_index) catch |err| {
        error_code.* = translateError(err);
        return null;
    };
    return slice.ptr;
}

pub export fn stitch_reader_get_scratch_bytes(reader: *anyopaque, resource_index: u64, error_code: *u64) callconv(.c) ?[*]const u8 {
    error_code.* = 0;
    const slice = fromC(reader).rw.reader.getScratchBytes(resource_index) catch |err| {
        error_code.* = translateError(err);
        return null;
    };
    return slice.ptr;
}

pub export fn stitch_writer_commit(writer: *anyopaque, error_code: *u64) callconv(.c) void {
    fromC(writer).rw.writer.commit() catch |err| {
        error_code.* = translateError(err);
    };
}

pub export fn stitch_writer_add_resource_from_path(writer: *anyopaque, name: [*:0]const u8, path: [*:0]const u8, error_code: *u64) callconv(.c) u64 {
    return fromC(writer).rw.writer.addResourceFromPath(std.mem.span(name), std.mem.span(path)) catch |err| {
        error_code.* = translateError(err);
        return std.math.maxInt(u64);
    };
}

pub export fn stitch_writer_add_resource_from_bytes(writer: *anyopaque, name: [*:0]const u8, bytes: [*]const u8, len: usize, error_code: *u64) callconv(.c) u64 {
    return fromC(writer).rw.writer.addResourceFromSlice(std.mem.span(name), bytes[0..len]) catch |err| {
        error_code.* = translateError(err);
        return std.math.maxInt(u64);
    };
}

pub export fn stitch_writer_set_scratch_bytes(writer: *anyopaque, resource_index: u64, bytes: [*]const u8, error_code: *u64) callconv(.c) void {
    fromC(writer).rw.writer.setScratchBytes(resource_index, bytes[0..8].*) catch |err| {
        error_code.* = translateError(err);
    };
}

pub export fn stitch_read_entire_file(reader_or_writer: *anyopaque, path: [*:0]const u8, error_code: *u64) callconv(.c) ?[*]const u8 {
    const s = fromC(reader_or_writer);
    switch (s.rw) {
        inline else => |rw| {
            const slice = rw.session.readEntireFile(std.mem.span(path)) catch |err| {
                error_code.* = translateError(err);
                return null;
            };
            return slice.ptr;
        },
    }
    return null;
}

pub export fn stitch_get_last_error_diagnostic(session: ?*anyopaque) callconv(.c) ?[*:0]const u8 {
    if (session == null) return "Could not get diagnostic: Invalid session";
    var s = fromC(session.?);
    if (s.getDiagnostics()) |d| {
        const str = d.toOwnedString(s.arena.allocator()) catch return null;
        return s.arena.allocator().dupeZ(u8, str) catch return null;
    } else return null;
}

pub export fn stitch_get_error_diagnostic(error_code: u64) callconv(.c) ?[*:0]const u8 {
    switch (error_code) {
        2 => return "Output file already exists",
        3 => return "Could not open input file",
        4 => return "Could not open output file",
        5 => return "Invalid executable format",
        6 => return "Resource not found",
        7 => return "I/O error",
        else => return "Unknown error code",
    }
}

pub export fn stitch_test_setup() callconv(.c) void {
    testSetup() catch unreachable;
}

pub export fn stitch_test_teardown() callconv(.c) void {
    testTeardown();
}

// Convert from a C ABI pointer to a Zig pointer to self
fn fromC(session: *anyopaque) *Self {
    return @ptrCast(@alignCast(session));
}

// Map Zig errors to C error codes
fn translateError(err: anyerror) u64 {
    return switch (err) {
        StitchError.OutputFileAlreadyExists => 2,
        StitchError.CouldNotOpenInputFile => 3,
        StitchError.CouldNotOpenOutputFile => 4,
        StitchError.InvalidExecutableFormat => 5,
        StitchError.ResourceNotFound => 6,
        StitchError.IoError => 7,
        else => 1,
    };
}
