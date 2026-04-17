//! Stitch test suite
const std = @import("std");
const Stitch = @import("stitch");
const StitchError = Stitch.StitchError;

test "write to new file, but it exists" {
    try Stitch.testSetup();
    defer Stitch.testTeardown() catch {};

    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.OutputFileAlreadyExists, Stitch.initWriter(io, allocator, ".stitch/one.txt", ".stitch/two.txt"));
}

test "append resources to new file and read them back" {
    try Stitch.testSetup();
    defer Stitch.testTeardown() catch {};

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    // Create a temporary file, with a random name, and delete it when we're done.
    const random_name = try Stitch.generateUniqueFileName(arena.allocator());
    defer std.Io.Dir.cwd().deleteFile(io, random_name) catch {};

    // Create stitch file
    {
        var writer = try Stitch.initWriter(io, allocator, ".stitch/executable", random_name);
        defer writer.deinit();
        _ = try writer.addResourceFromPath("one", ".stitch/one.txt");
        const index = try writer.addResourceFromPath(null, ".stitch/two.txt");
        try writer.setScratchBytes(index, [8]u8{ 0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00 });

        var file = try std.Io.Dir.cwd().openFile(io, ".stitch/three.txt", .{});
        defer file.close(io);

        var buf: [1024]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        const reader = &file_reader.interface;
        _ = try writer.addResourceFromReader("from-reader", reader);
        _ = try writer.addResourceFromSlice(".stitch/two.txt", "Hello world");
        try writer.commit();
    }

    // Read it back and verify
    {
        var reader = try Stitch.initReader(io, allocator, random_name);
        defer reader.deinit();
        try std.testing.expectEqual(reader.getFormatVersion(), Stitch.StitchVersion);
        try std.testing.expectEqual(reader.getResourceCount(), 4);

        // Test reading a resource fully as a slice
        var data = try reader.getResourceAsSlice(0);
        try std.testing.expectEqualSlices(u8, data, "Hello world");

        const two_index = try reader.getResourceIndex("two.txt");
        const scratch_bytes = try reader.getScratchBytes(two_index);
        try std.testing.expectEqualSlices(u8, scratch_bytes, &[8]u8{ 0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00 });

        // Test reading a resource through a reader
        var rr = try reader.getResourceReader(two_index);
        data = try rr.readResourceOwned(allocator);
        try std.testing.expectEqualSlices(u8, data, "Hello\nWorld");
    }
}

test "write executable with no resources" {
    try Stitch.testSetup();
    defer Stitch.testTeardown() catch {};

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const io = std.testing.io;

    // Create a temporary file, with a random name, and delete it when we're done.
    const random_name = try Stitch.generateUniqueFileName(arena.allocator());
    defer std.Io.Dir.cwd().deleteFile(io, random_name) catch {};

    // Create stitch file
    {
        const allocator = std.heap.page_allocator;
        var writer = try Stitch.initWriter(io, allocator, ".stitch/one.txt", random_name);
        defer writer.deinit();
        try writer.commit();
    }

    // Read it back and verify
    {
        var reader = try Stitch.initReader(io, arena.allocator(), random_name);
        defer reader.deinit();
        try std.testing.expectEqual(reader.getFormatVersion(), Stitch.StitchVersion);
        try std.testing.expectEqual(reader.getResourceCount(), 0);
    }

    // Test session utility functions
    {
        var reader = try Stitch.initReader(io, arena.allocator(), random_name);
        defer reader.deinit();

        const content = try reader.session.readEntireFile(".stitch/one.txt");
        try std.testing.expectEqualSlices(u8, content, "Hello world");
        try std.testing.expect((try reader.session.getSelfPath()).len > 0);
    }
}

test "read invalid exe, too small" {
    try Stitch.testSetup();
    defer Stitch.testTeardown() catch {};

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const io = std.testing.io;

    // Input file too small
    {
        const random_name = try Stitch.generateUniqueFileName(arena.allocator());
        defer std.Io.Dir.cwd().deleteFile(io, random_name) catch {};

        {
            var file = try std.Io.Dir.cwd().createFile(io, random_name, .{});
            defer file.close(io);
            var file_writer = file.writer(io, &.{});
            try file_writer.interface.writeAll("abc");
        }
        try std.testing.expectError(StitchError.InvalidExecutableFormat, Stitch.initReader(io, arena.allocator(), random_name));
    }

    // Bad magic
    {
        const random_name = try Stitch.generateUniqueFileName(arena.allocator());
        defer std.Io.Dir.cwd().deleteFile(io, random_name) catch {};

        {
            var file = try std.Io.Dir.cwd().createFile(io, random_name, .{});
            defer file.close(io);
            var file_writer = file.writer(io, &.{});
            try file_writer.interface.writeAll("1234567890123456712345678901234567");
        }
        try std.testing.expectError(StitchError.InvalidExecutableFormat, Stitch.initReader(io, arena.allocator(), random_name));
    }
}

test "read invalid exe with out-of-range index offset" {
    try Stitch.testSetup();
    defer Stitch.testTeardown() catch {};

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const io = std.testing.io;

    const random_name = try Stitch.generateUniqueFileName(arena.allocator());
    defer std.Io.Dir.cwd().deleteFile(io, random_name) catch {};

    var file = try std.Io.Dir.cwd().createFile(io, random_name, .{});
    defer file.close(io);
    var file_writer = file.writer(io, &.{});
    try file_writer.interface.writeInt(u64, 1, .big);
    try file_writer.interface.writeByte(Stitch.StitchVersion);
    try file_writer.interface.writeInt(u64, Stitch.EofMagic, .big);
    try file_writer.interface.flush();

    try std.testing.expectError(StitchError.InvalidExecutableFormat, Stitch.initReader(io, arena.allocator(), random_name));
}

test "getSelfPath returns the current executable path" {
    try Stitch.testSetup();
    defer Stitch.testTeardown() catch {};

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const io = std.testing.io;

    const random_name = try Stitch.generateUniqueFileName(arena.allocator());
    defer std.Io.Dir.cwd().deleteFile(io, random_name) catch {};

    {
        var writer = try Stitch.initWriter(io, arena.allocator(), ".stitch/one.txt", random_name);
        defer writer.deinit();
        try writer.commit();
    }

    var reader = try Stitch.initReader(io, arena.allocator(), random_name);
    defer reader.deinit();

    const self_path = try reader.session.getSelfPath();
    const expected_path = try std.process.executablePathAlloc(io, arena.allocator());
    try std.testing.expectEqualStrings(expected_path, self_path);
}

test "c api clears error_code on success and deinit accepts null" {
    try Stitch.testSetup();
    defer Stitch.testTeardown() catch {};

    var error_code: u64 = 1234;
    const writer = Stitch.stitch_init_writer(".stitch/executable", ".stitch/new-executable", &error_code) orelse return error.UnexpectedNull;
    defer Stitch.stitch_deinit(writer);

    try std.testing.expectEqual(@as(u64, 0), error_code);

    error_code = 999;
    _ = Stitch.stitch_writer_add_resource_from_bytes(writer, "name", "abc", 3, &error_code);
    try std.testing.expectEqual(@as(u64, 0), error_code);

    Stitch.stitch_deinit(null);
}
