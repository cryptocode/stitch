// C ABI interface for the stitch library
// Link with libstitch
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// If a function succeeds, the `error_code` argument is set to STITCH_SUCCESS, otherwise it is set to
// one of the error codes below. The numeric values are guaranteed to not change between
// versions of the library.
// Do not rely on return values for error checking; only check against `error_code`
#define STITCH_SUCCESS 0
#define STITCH_ERROR_UKNOWN 1
#define STITCH_ERROR_OUTPUT_FILE_ALREADY_EXISTS 2
#define STITCH_ERROR_INPUT_FILE_COULD_NOT_OPEN 3
#define STITCH_ERROR_OUTPUT_FILE_COULD_NOT_OPEN 4
#define STITCH_ERROR_INVALID_EXECUTABLE_FORMAT 5
#define STITCH_ERROR_RESOURCE_NOT_FOUND 6
#define STITCH_ERROR_IO_ERROR 7

// Start a new stitch session for appending resources to an executable. No file writes occur until stitch_writer_commit is called.
// The returned writer session is passed to all other writer functions.
// You must call stitch_deinit to close the session, which also frees memory allocated by the session (including resources)
// Note that `original_executable_path` and `output_executable_path` can be the same, in which case metadata and resources are
// appended to the original executable. The same applies if `output_executable_path` is NULL.
// On error, `error_code` is set to the error code and NULL is returned.
void* stitch_init_writer(const char* original_executable_path, const char* output_executable_path, uint64_t* error_code);

// Start a new stitch session for reading resources. The returned session is passed to all other applicable functions.
// You must call stitch_deinit to close the session, and free allocated memory.
// If `executable_path` is NULL, the currently running executable is used. This enables executables to read resources from themselves.
// On error, `error_code` is set to the error code and NULL is returned.
void* stitch_init_reader(const char* executable_path, uint64_t* error_code);

// Close a stitch session returned by `stitch_init_writer` or `stitch_init_reader`.
// Not calling this function will result in memory leaks.
// Calling this function with a NULL pointer is a safe no-op.
void stitch_deinit(void* session);

// Returns the number of resources in the executable. This may be zero.
uint64_t stitch_reader_get_resource_count(void* reader);

// Returns the format version of the executable. This is useful for detecting incompatible changes to the stitch format.
uint8_t stitch_reader_get_format_version(void* reader);

// Returns the index of the resource with the given name.
// On error, `error_code` is set to the error code and UINT64_MAX is returned.
// Error code is STITCH_ERROR_RESOURCE_NOT_FOUND if the resource is not found.
uint64_t stitch_reader_get_resource_index(void* reader, const char* name, uint64_t* error_code);

// Returns the length in bytes of the resource at the given index
// On error, `error_code` is set to the error code and UINT64_MAX is returned.
// Error code is STITCH_ERROR_RESOURCE_NOT_FOUND if the resource is not found.
uint64_t stitch_reader_get_resource_byte_len(void* reader, uint64_t index, uint64_t* error_code);

// Returns the data of the resource at the given index
// Use `stitch_reader_get_resource_byte_len` to get the size of the returned resource
// On error, `error_code` is set to the error code and NULL is returned.
// Error code is STITCH_ERROR_RESOURCE_NOT_FOUND if the resource index is invalid.
const char* stitch_reader_get_resource_bytes(void* reader, uint64_t index, uint64_t* error_code);

// Returns the scratch bytes for the resource, which is all-zeros if not set specifically.
// On error, `error_code` is set to the error code and NULL is returned.
// Error code is STITCH_ERROR_RESOURCE_NOT_FOUND if the resource index is invalid.
const char* stitch_reader_get_scratch_bytes(void* reader, uint64_t index, uint64_t* error_code);

// Write executable and resources to file.
void stitch_writer_commit(void* writer, uint64_t* error_code);

// Add a resource to the executable given a relative or absolute path. 
// The resource is not written to disk until stitch_writer_commit is called.
// This option reqiores minimal memory usage.
// Returns the index of the resource.
// On error, `error_code` is set to the error code and UINT64_MAX is returned.
uint64_t stitch_writer_add_resource_from_path(void* writer, const char* name, const char* path, uint64_t* error_code);

// Add a resource to the executable given a buffer of data. 
// The buffer is not written to disk until stitch_writer_commit is called.
// The buffer must remain valid until stitch_writer_commit is called.
// Returns the index of the resource.
// On error, `error_code` is set to the error code and UINT64_MAX is returned.
uint64_t stitch_writer_add_resource_from_bytes(void* writer, const char* name, const char* data, uint64_t len, uint64_t* error_code);

// Set the scratch bytes for a resource, using the index returned by the add_resource... functions.
// The length of `bytes` must be exactly 8 bytes.
// The default scratch bytes is all-zero.
// Returns true if the scratch bytes were set successfully, or false if an error occurs.
void stitch_writer_set_scratch_bytes(void* writer, uint64_t resource_index, const char* bytes, uint64_t* error_code);

// If an error is produced by an API function, the returned string is a human-readable diagnostic message,
// otherwise NULL is returned. Every API function resets the diagnostic.
// The memory for the returned string is owned by the session and is freed when `stitch_deinit` is called.
char* stitch_get_last_error_diagnostic(void* session);

// Returns a human-readable diagnostic message for the given error code
// If a valid session is available, use `stitch_get_last_error_diagnostic` instead to get more detailed information.
// The main use case for this function is when a session is not available, i.e when an init function fail.
// The memory for the returned string is owned by the library.
char* stitch_get_error_diagnostic(uint64_t error_code);

#ifdef __cplusplus
}
#endif