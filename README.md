 # S T I T C H <sub><sup>&nbsp;&nbsp;&nbsp;*Self-contained executables made easy*</sup></sub>

<img align="right" height="120" src="https://user-images.githubusercontent.com/34946442/232327201-294224c2-8502-423b-b2cb-663ca88ccfc1.png">

<img src="https://user-images.githubusercontent.com/34946442/230613201-60de5adc-6304-4f18-84d9-d36bb46fdc1f.svg" width="24" height="24">&nbsp;
<img src="https://user-images.githubusercontent.com/34946442/230613198-ca5c938a-613b-412f-8d97-8ce8f19aeb1f.svg" width="24" height="24">&nbsp;
<img src="https://user-images.githubusercontent.com/34946442/230613203-858cb471-2859-4e6e-8ef9-61b03c36c085.svg" width="24" height="24">

Stitch is a tool and library for Zig and C for adding and retrieving resources to and from executables.

Why not just use `@embed` / `#embed`? Stitch serves a different purpose, namely to let build systems, and *users* of your software, create self-contained executables.

For example, instead of requiring users to install an interpreter and execute `mylisp fib.lisp`, they can simply run `./fib` or `fib.exe`

Resoures can be anything, such as scripts, images, text, templates config files, other executables, and so on.

## Use case examples
* Self extracting tools, like an installer
* Create executables for scripts written in your interpreted programming language
* Include a sample config file, which is extracted on first run. The user can then edit this.
* An image in your own format that's able to display itself when executed

## Building the project
*Last tested with Zig version 0.12.0-dev.3161+377ecc6af*

`zig build` will put a `bin` and `lib` directory in your output folder (e.g. zig-out)

* bin/stitch is a standalone tool for attaching resources to executables. This can also be done programmatically using the library
* lib/libstitch is a library for reading attached resources from the current executable, and for adding resources to executables (like the standalone tool)

## Using the tool

This example adds two scripts to a Lisp interpreter that supports, through the stitch library, reading embedded scripts:

```bash
stitch ./mylisp std.lisp fib.lisp --output fib

./fib 8
21
```

Resources can be named explicitly

```bash
stitch ./mylisp std=std.lisp fibonacci=fib.lisp --output fib
```

If a name is not given, the filename (without path) is used. The stitch library supports finding resources by name or index.

The `--output` flag is optional. By default, resources are added to the original executable (first argument)
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

## Binary layout

The binary layout specification can be used by other tools that wants to parse files produced by Stitch, without using the Stitch library.

[Specification](spec/README.md)
