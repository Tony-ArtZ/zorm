# ZORM

ZORM is a portable Zig ORM library with a schema generator and example usage.

## Features

- Static library for embedding in Zig projects
- Generator tool to convert `.zorm` schema files to Zig code
- Example project for quick start

## Getting Started

### 1. Add as Dependency

Add ZORM to your `build.zig.zon`:

```
.{
  .dependencies = .{
    .zorm = .{
      .url = "https://github.com/Tony-ArtZ/zorm/archive/refs/heads/main.tar.gz",
    },
  },
}
```

### 2. Build the Generator

```
zig build zorm-generator
```

### 3. Generate Schema Code

```
./zig-out/bin/zorm-generator schema.zorm generated_schema.zig
```

- `schema.zorm`: Your schema definition file
- `generated_schema.zig`: Output Zig file to import in your project

### 4. Use in Your Zig Project

In your `build.zig`:

```zig
const zorm_dep = b.dependency("zorm", .{});
exe.root_module.addImport("zorm", zorm_dep.module("zorm"));
exe.linkLibrary(zorm_dep.artifact("zorm"));
```

In your Zig code:

```zig
const zorm = @import("zorm");
const schema = @import("generated_schema.zig");
```

### 5. Example Usage

Below is a minimal example using SQLite (see `examples/example.zig` for more):

```zig
const std = @import("std");
const zorm = @import("zorm");
const schema = @import("generated_schema.zig");
const SQLITE = zorm.SQLITE;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize SQLite backend
    var db = SQLITE.init(allocator);
    defer db.disconnect();

    // Connect to SQLite database file
    const conninfo = "test.db";
    try db.connect(conninfo);

    // Create the User table from generated schema
    try db.createTable(schema.UserMeta);

    // Create a user instance
    const user = schema.User{
        .id = "1",
        .name = "John Doe",
        .email = "john@example.com",
        .age = "30",
    };

    // Insert the user
    try db.insert(schema.User, user);

    std.debug.print("User inserted successfully!\n", .{});
}
```

- You can switch to PostgreSQL by using `const PG = zorm.pg.PG;` and updating the backend initialization and connection string.
- The generated schema file will provide types like `User` and `UserMeta`.

## License

MIT
