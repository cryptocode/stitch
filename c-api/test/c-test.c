// Tests the C API
//
// Compile this file into an executable and run it:
//     zig build-exe c-api/test/c-test.c -Lzig-out/lib -lstitch -Ic-api/include
//     ./c-test
//
// If an error occurs, the test program will print an error message and exit with a non-zero exit code

#include <stitch.h>
#include <stdio.h>
#include <inttypes.h>

void stitch_test_setup();
void stitch_test_teardown();

int main() {
    uint64_t error_code = 0;

    // Create test files
    stitch_test_setup();

    // Create a stitch writer
    void* writer = stitch_init_writer(".stitch/executable", ".stitch/new-executable", &error_code);
    if (error_code) {
        printf("Failed to initialize stitch writer: %" PRIu64 " (%s)\n", error_code, stitch_get_error_diagnostic(error_code));
        return 1;
    }

    stitch_writer_add_resource_from_path(writer, "first file", ".stitch/one.txt", &error_code);
    if (error_code) {
        printf("Failed to add resource from path: %" PRIu64 " (%s)\n", error_code, stitch_get_last_error_diagnostic(writer));
        return 1;
    }
    stitch_writer_add_resource_from_bytes(writer, "second file", "abcd", 4, &error_code);
    if (error_code) {
        printf("Failed to add resource from bytes: %" PRIu64 " (%s)\n", error_code, stitch_get_last_error_diagnostic(writer));
        return 1;
    }
    stitch_writer_set_scratch_bytes(writer, 0, "12345678", &error_code);
    if (error_code) {
        printf("Failed to set scratch bytes: %" PRIu64 " (%s)\n", error_code, stitch_get_last_error_diagnostic(writer));
        return 1;
    }
    stitch_writer_commit(writer, &error_code);
    if (error_code) {
        printf("Failed to commit: %" PRIu64 " (%s)\n", error_code, stitch_get_last_error_diagnostic(writer));
        return 1;
    }

    stitch_deinit(writer);

    // Create a stitch reader
    void* reader = stitch_init_reader(".stitch/new-executable", &error_code);
    if (error_code) {
        printf("Failed to initialize stitch. Have you attached resources to this executable yet?\n");
        return 1;
    }

    uint64_t count = stitch_reader_get_resource_count(reader);
    printf("Resource count is: %" PRIu64 "\n", count);

    uint8_t format_version = stitch_reader_get_format_version(reader);
    printf("Format version is: %" PRIu8 "\n", format_version);

    uint64_t index = stitch_reader_get_resource_index(reader, "second file", &error_code);
    if (error_code) {
        printf("Failed to get index of resource named \"second file\"\n");
        return 1;
    }
    printf("Index of resource named \"second file\" is: %" PRIu64 "\n", index);

    const char* bytes = stitch_reader_get_resource_bytes(reader, 0, &error_code);
    if (error_code) {
        printf("Failed to get bytes for resource 0\n");
        return 1;
    }
    uint64_t len = stitch_reader_get_resource_byte_len(reader, 0, &error_code);
    if (error_code) {
        printf("Failed to get length of resource 0\n");
        return 1;
    }
    printf("Resource 0 has length: %" PRIu64 "\n", len);
    printf("Bytes: %.*s\n", (int)len, bytes);
    
    // Get scratch bytes for resource 0
    const char* scratch_bytes = stitch_reader_get_scratch_bytes(reader, 0, &error_code);
    if (error_code) {
        printf("Failed to get scratch bytes for resource 0\n");
        return 1;
    }
    printf("Scratch bytes for resource 0 are: %.*s\n", 8, scratch_bytes);

    // Clear memory allocated by stitch, including all resource data
    // If you need to keep the resources around after deinitializing stitch, you need to copy them first
    stitch_deinit(reader);

    // Remove test files
    stitch_test_teardown();

    return 0;
}