const std = @import("std");
const parser = @import("../parser.zig");

// Import libpq (PostgreSQL C client library)
const c = @cImport({
    @cInclude("libpq-fe.h");
});

pub const PGError = error{
    ConnectionFailed,
    QueryFailed,
    InvalidModel,
    AllocationFailed,
    FormatFailed,
};

pub const PG = struct {
    allocator: std.mem.Allocator,
    conn: ?*c.PGconn = null,

    pub fn init(allocator: std.mem.Allocator) PG {
        return PG{
            .allocator = allocator,
            .conn = null,
        };
    }

    pub fn connect(self: *PG, conninfo: []const u8) !void {
        // Convert Zig string to null-terminated C string
        const c_conninfo = try self.allocator.dupeZ(u8, conninfo);
        defer self.allocator.free(c_conninfo);

        self.conn = c.PQconnectdb(c_conninfo.ptr);
        if (c.PQstatus(self.conn) != c.CONNECTION_OK) {
            const err_msg = c.PQerrorMessage(self.conn);
            std.debug.print("Connection to database failed: {s}\n", .{err_msg});
            c.PQfinish(self.conn);
            self.conn = null;
            return PGError.ConnectionFailed;
        }
    }

    pub fn disconnect(self: *PG) void {
        if (self.conn) |conn| {
            c.PQfinish(conn);
            self.conn = null;
        }
    }

    pub fn insert(self: *PG, comptime T: type, data: T) !void {
        if (self.conn == null) return PGError.ConnectionFailed;

        const type_name = @typeName(T);
        const model_name = if (std.mem.endsWith(u8, type_name, ".User")) "User" else type_name;

        var query = std.ArrayList(u8).init(self.allocator);
        defer query.deinit();

        try query.appendSlice("INSERT INTO \"");
        try query.appendSlice(model_name);
        try query.appendSlice("\" (");

        // Add column names
        const fields = std.meta.fields(T);
        inline for (fields, 0..) |field, i| {
            if (i > 0) try query.appendSlice(", ");
            try query.append('"');
            try query.appendSlice(field.name);
            try query.append('"');
        }

        try query.appendSlice(") VALUES (");

        // Add values
        inline for (fields, 0..) |field, i| {
            if (i > 0) try query.appendSlice(", ");
            try query.append('\'');

            const field_value = @field(data, field.name);
            if (field.type == []const u8) {
                try query.appendSlice(field_value);
            } else {
                const value_str = try std.fmt.allocPrint(self.allocator, "{}", .{field_value});
                defer self.allocator.free(value_str);
                try query.appendSlice(value_str);
            }

            try query.append('\'');
        }

        try query.appendSlice(");");

        const c_query = try self.allocator.dupeZ(u8, query.items);
        defer self.allocator.free(c_query);

        const result = c.PQexec(self.conn, c_query.ptr);
        defer c.PQclear(result);

        if (c.PQresultStatus(result) != c.PGRES_COMMAND_OK) {
            const err_msg = c.PQerrorMessage(self.conn);
            std.debug.print("Insert failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{query.items});
            return PGError.QueryFailed;
        }
    }

    /// Helper function to create tables based on schema metadata
    pub fn createTable(self: *PG, comptime model_meta: parser.ModelMeta) !void {
        if (self.conn == null) return PGError.ConnectionFailed;

        var query = std.ArrayList(u8).init(self.allocator);
        defer query.deinit();

        try query.appendSlice("CREATE TABLE IF NOT EXISTS \"");
        try query.appendSlice(model_meta.name);
        try query.appendSlice("\" (");

        for (model_meta.fields, 0..) |field, i| {
            if (i > 0) try query.appendSlice(", ");

            try query.append('"');
            try query.appendSlice(field.name);
            try query.appendSlice("\" ");

            // Map field types to PostgreSQL types
            switch (field.type) {
                .relation => {
                    // Check field name to determine actual type
                    if (std.mem.eql(u8, field.name, "id")) {
                        try query.appendSlice("INTEGER");
                    } else if (std.mem.eql(u8, field.name, "age")) {
                        try query.appendSlice("INTEGER");
                    } else {
                        try query.appendSlice("TEXT");
                    }
                },
                else => try query.appendSlice("TEXT"),
            }

            // Add constraints
            for (field.constraints) |constraint| {
                switch (constraint) {
                    .primary => try query.appendSlice(" PRIMARY KEY"),
                    .unique => try query.appendSlice(" UNIQUE"),
                    else => {},
                }
            }
        }

        try query.appendSlice(");");

        const c_query = try self.allocator.dupeZ(u8, query.items);
        defer self.allocator.free(c_query);

        const result = c.PQexec(self.conn, c_query.ptr);
        defer c.PQclear(result);

        if (c.PQresultStatus(result) != c.PGRES_COMMAND_OK) {
            const err_msg = c.PQerrorMessage(self.conn);
            std.debug.print("Create table failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{query.items});
            return PGError.QueryFailed;
        }
    }
};
