<img align="right" height="120" src="https://user-images.githubusercontent.com/34946442/232327201-294224c2-8502-423b-b2cb-663ca88ccfc1.png">

Stitch is a tool and library for Zig and C for adding and retrieving resources to and from executables.

Why not just use `@embedFile` / `#embed`? Stitch serves a different purpose, namely to let build systems, and *users* of your software, create self-contained executables.

For example, instead of requiring users to install an interpreter and execute `mylisp fib.lisp`, they can simply run `./fib` or `fib.exe`

Resources can be anything, such as scripts, images, text, templates, config files, and other executables.

## Some use cases
* Self extracting tools, like an installer
* Create executables for scripts written in your interpreted programming language
* Include a sample config file, which is extracted on first run. The user can then edit this.
* An image in your own format that's able to display itself when executed

## Building the project
To build with a specific Zig version, use the `zig-<version>` tag.
To build with Zig master, use the main branch.

`zig build` will put a `bin` and `lib` directory in your output folder (for example `zig-out`)

* `bin/stitch` is a standalone tool for attaching resources to executables. This can also be done programmatically using the library.
* `lib/libstitch` is a library for reading attached resources from the current executable, and for adding resources to executables like the standalone tool.

## Using the tool

This example adds two scripts to a Lisp interpreter that supports, through the stitch library, reading embedded scripts:

```bash
stitch ./mylisp std.lisp fib.lisp --output fib

./fib 8
21
```

Resources can be named explicitly:

```bash
stitch ./mylisp std=std.lisp fibonacci=fib.lisp --output fib
```

If a name is not given, the basename of the input path is used. The stitch library supports finding resources by name or index.

The `--output` flag is optional. If it is omitted, resources are added to the original executable in place.

## Stitching programmatically
Let's say you want your interpreted programming language to support producing binaries.

An easy way to do this is to create an interpreter executable that reads scripts attached to itself using stitch.

You can provide interpreter binaries for all the OS'es you wanna support, or have the Zig build file do this if your user is building the interpreter.

In the example below, a Lisp interpreter uses the stitch library to support creating self-contained executables:

```bash
./mylisp --create-exe sql-client.lisp --output sql-client
```
The resulting binary can now be executed:

```
./sql-client
```

You can make the `mylisp` binary understand stitch attachments and then make a copy of it and stitch it with the scripts. Alternatively, you can have separate interpreter binaries specifically for reading stitched scripts.
## Using the library from C

Include the `stitch.h` header and link to the library. Here's an example, using the included C test program:

```bash
zig build-exe c-api/test/c-test.c -Lzig-out/lib -lstitch -Ic-api/include
./c-test
```

To read resources from the currently running executable, call `stitch_init_reader(NULL, &error_code)`.

## Binary layout

The binary layout specification can be used by other tools that want to parse files produced by Stitch without using the Stitch library.

[Specification](spec/README.md)
