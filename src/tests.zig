//! Stitch test suite
const std = @import("std");
const Stitch = @import("stitch");
const StitchError = Stitch.StitchError;

test "write to new file, but it exists" {
    try Stitch.testSetup();
    defer Stitch.testTeardown();

    const allocator = std.heap.page_allocator;
    try std.testing.expectError(error.OutputFileAlreadyExists, Stitch.initWriter(allocator, ".stitch/one.txt", ".stitch/two.txt"));
}

test "append resources to new file and read them back" {
    try Stitch.testSetup();
    defer Stitch.testTeardown();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a temporary file, with a random name, and delete it when we're done.
    const random_name = try Stitch.generateUniqueFileName(arena.allocator());
    defer std.fs.cwd().deleteFile(random_name) catch unreachable;

    // Create stitch file
    {
        var writer = try Stitch.initWriter(allocator, ".stitch/executable", random_name);
        defer writer.deinit();
        _ = try writer.addResourceFromPath("one", ".stitch/one.txt");
        const index = try writer.addResourceFromPath(null, ".stitch/two.txt");
        try writer.setScratchBytes(index, [8]u8{ 0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00 });

        var file = try std.fs.cwd().openFile(".stitch/three.txt", .{});
        defer file.close();
        _ = try writer.addResourceFromReader("from-reader", file.reader());
        _ = try writer.addResourceFromSlice(".stitch/two.txt", "Hello world");
        try writer.commit();
    }

    // Read it back and verify
    {
        var reader = try Stitch.initReader(allocator, random_name);
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
        data = try rr.reader().readAllAlloc(allocator, std.math.maxInt(u64));
        try std.testing.expectEqualSlices(u8, data, "Hello\nWorld");
    }
}

test "write executable with no resources" {
    try Stitch.testSetup();
    defer Stitch.testTeardown();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Create a temporary file, with a random name, and delete it when we're done.
    const random_name = try Stitch.generateUniqueFileName(arena.allocator());
    defer std.fs.cwd().deleteFile(random_name) catch unreachable;

    // Create stitch file
    {
        const allocator = std.heap.page_allocator;
        var writer = try Stitch.initWriter(allocator, ".stitch/one.txt", random_name);
        defer writer.deinit();
        try writer.commit();
    }

    // Read it back and verify
    {
        var reader = try Stitch.initReader(arena.allocator(), random_name);
        defer reader.deinit();
        try std.testing.expectEqual(reader.getFormatVersion(), Stitch.StitchVersion);
        try std.testing.expectEqual(reader.getResourceCount(), 0);
    }

    // Test session utility functions
    {
        var reader = try Stitch.initReader(arena.allocator(), random_name);
        defer reader.deinit();

        const content = try reader.session.readEntireFile(".stitch/one.txt");
        try std.testing.expectEqualSlices(u8, content, "Hello world");
        try std.testing.expect((try reader.session.getSelfPath()).len > 0);
    }
}

test "read invalid exe, too small" {
    try Stitch.testSetup();
    defer Stitch.testTeardown();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Input file too small
    {
        const random_name = try Stitch.generateUniqueFileName(arena.allocator());
        defer std.fs.cwd().deleteFile(random_name) catch unreachable;

        {
            var file = try std.fs.cwd().createFile(random_name, .{});
            defer file.close();
            try file.writer().print("abc", .{});
        }
        try std.testing.expectError(StitchError.InvalidExecutableFormat, Stitch.initReader(arena.allocator(), random_name));
    }

    // Bad magic
    {
        const random_name = try Stitch.generateUniqueFileName(arena.allocator());
        defer std.fs.cwd().deleteFile(random_name) catch unreachable;

        {
            var file = try std.fs.cwd().createFile(random_name, .{});
            defer file.close();
            try file.writer().print("1234567890123456712345678901234567", .{});
        }
        try std.testing.expectError(StitchError.InvalidExecutableFormat, Stitch.initReader(arena.allocator(), random_name));
    }
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Stitch.StitchReader);
    std.testing.refAllDecls(Stitch.StitchResourceReader);
    std.testing.refAllDecls(Stitch.StitchWriter);
    std.testing.refAllDecls(Stitch.C_ABI);
}
