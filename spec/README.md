# Specification

<img align="right" height="120" src="https://user-images.githubusercontent.com/34946442/232327201-294224c2-8502-423b-b2cb-663ca88ccfc1.png">

Format version: 1

This specification can be used by tools to parse and create Stitch executables, without using the Stitch library.

Resources and metadata are appended to the end of the original executable, according to the specification below.

Backwards- and forwards compatibility is guaranteed as long as the *eof-magic* is recognized: older parsers will be able to read what they understand from newer format versions, and newer parsers will fully understand older format versions. Any features breaking this guarantee will essentially be a new format, with a new *eof-magic*

```ebnf
stitch-executable   ::= original-exe resource* index tail
original-exe        ::= blob
resource            ::= resource-magic blob
index               ::= entry-count index-entry*
tail                ::= index-offset version eof-magic

index-entry         ::= name resource-type resource-offset byte-length scratch-bytes
name                ::= byte-length blob
resource-type       ::= u8
resource-offset     ::= u64be
scratch-bytes       ::= [8]u8

index-offset        ::= u64be
blob                ::= [*]u8
byte-length         ::= u64be
entry-count         ::= u64be

version             ::= u8
resource-magic      ::= u64be = 0x18c767a11ea80843
eof-magic           ::= u64be = 0xa2a7fdfa0533438f
```
A parser is expected to start by reading the 17-byte `tail`: index offset, version and magic.

If the index offset is 0, then the file doesn't contain any resources but is still a valid Stitch executable. A file shorter than 17 bytes is never a valid Stitch executable.

If `eof-magic` is recognized, the parser continues by reading the index, given by the index offset. Once the index is read, resources can be read either directly, or on
request by zero-based resource index or resource name.

## Notes:
* *offset* is number of bytes from the beginning of the file
* *version* is currently the value 1
* *eof-magic* indicates that this is a Stitch-compliant executable
* *resource-magic* is a marker to help tools verify the that the layout is correct
* *resource-type* is currently the value 1, denoting "blob". This field may gain additional values in the future, to support backwards- and forwards compatibility.
* *scratch-bytes* are 8 freely available bytes, whose interpretation is up to the application. If not set by the application, this field will be initialized to all-zeros. The field can be used for things like file types, permissions, etc. Additional metadata can be prepended manually in the resource.
* *u64be* mean 64-bit integer written in big endian format. Big-endian is used for 3 reasons: a) it's the defacto standard for binary formats, b) it makes debugging outputs easier, c) it prevents buggy implementation assuming native == little (as most systems are little endian)
* Resources are guaranteed to be added in same order as the API calls for adding resources

## Diagram
Below is the same specification in diagram form:
```
[0] Overall file layout:

+-------------------+
| [1] original-exe  |
+-------------------+
| [2] resource      |
+-------------------+
| [2] ...           |
+-------------------+
| [2] resource      |
+-------------------+
| [3] index         |
+-------------------+
| [6] tail          |
+-------------------+

[1] Original executable:

+-------+
| blob  |
+-------+
| [*]u8 |
+-------+

[2] Resource:

+----------------+-------+
| resource-magic | blob  |
+----------------+-------+
| u64be          | [*]u8 |
+----------------+-------+

[3] Index:

+-------------+--------------+---------------+--------------+
| entry-count | index-entry  |      ...      | index-entry  |
+-------------+--------------+---------------+--------------+
| u64be       | [4]          | [4]           | [4]          |
+-------------+--------------+---------------+--------------+

[4] Index entry:

+-------+---------------+------------------+-------------+----------------+
| name  | resource-type | resource-offset  | byte-length | scratch-bytes  |
+-------+---------------+------------------+-------------+----------------+
| [5]   | u8            | u64be            | u64be       | [8]u8          |
+-------+---------------+------------------+-------------+----------------+

[5] Name:

+-------------+-------+
| byte-length | blob  |
+-------------+-------+
| u64be       | [*]u8 |
+-------------+-------+

[6] Tail:
+---------------+----------+-----------+
| index-offset  | version  | eof-magic |
+---------------+----------+-----------+
| u64be         | u8       | u64be     |
+---------------+----------+-----------+
```