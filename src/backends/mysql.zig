const std = @import("std");
const parser = @import("../parser.zig");
const query_builder = @import("../query_builder.zig");

const MySQLConn = opaque {};
const MySQLResult = opaque {};
const MySQLRow = [*c]?[*c]u8;

extern fn mysql_init(mysql: ?*MySQLConn) ?*MySQLConn;
extern fn mysql_real_connect(mysql: ?*MySQLConn, host: ?[*:0]const u8, user: ?[*:0]const u8, passwd: ?[*:0]const u8, db: ?[*:0]const u8, port: c_uint, unix_socket: ?[*:0]const u8, clientflag: c_ulong) ?*MySQLConn;
extern fn mysql_close(sock: ?*MySQLConn) void;
extern fn mysql_error(mysql: ?*MySQLConn) [*:0]const u8;
extern fn mysql_query(mysql: ?*MySQLConn, query: [*:0]const u8) c_int;
extern fn mysql_store_result(mysql: ?*MySQLConn) ?*MySQLResult;
extern fn mysql_free_result(result: ?*MySQLResult) void;
extern fn mysql_num_rows(result: ?*MySQLResult) c_ulonglong;
extern fn mysql_num_fields(result: ?*MySQLResult) c_uint;
extern fn mysql_fetch_row(result: ?*MySQLResult) ?MySQLRow;

pub const QueryBuilder = query_builder.QueryBuilder;
pub const OrderDirection = query_builder.OrderDirection;
pub const ComparisonOperator = query_builder.ComparisonOperator;

pub const MySQLError = error{
    ConnectionFailed,
    QueryFailed,
    InvalidModel,
    AllocationFailed,
    FormatFailed,
};

const ConnConfig = struct {
    host: []const u8,
    user: []const u8,
    password: []const u8,
    database: []const u8,
    port: u32,
};

pub const MYSQL = struct {
    allocator: std.mem.Allocator,
    conn: ?*MySQLConn = null,

    pub fn init(allocator: std.mem.Allocator) MYSQL {
        return MYSQL{
            .allocator = allocator,
            .conn = null,
        };
    }

    pub fn queryBuilder(self: *MYSQL, comptime model_meta: parser.ModelMeta) !QueryBuilder {
        return QueryBuilder.init(self.allocator, &model_meta);
    }

    pub fn connect(self: *MYSQL, conninfo: []const u8) !void {
        const config = try parseConnInfo(conninfo);

        const c_host = try self.allocator.dupeZ(u8, config.host);
        defer self.allocator.free(c_host);

        const c_user = try self.allocator.dupeZ(u8, config.user);
        defer self.allocator.free(c_user);

        const c_password = try self.allocator.dupeZ(u8, config.password);
        defer self.allocator.free(c_password);

        const c_database = try self.allocator.dupeZ(u8, config.database);
        defer self.allocator.free(c_database);

        const mysql_conn = mysql_init(null) orelse return MySQLError.ConnectionFailed;

        if (mysql_real_connect(
            mysql_conn,
            c_host.ptr,
            c_user.ptr,
            c_password.ptr,
            c_database.ptr,
            @as(c_uint, @intCast(config.port)),
            null,
            0,
        ) == null) {
            const err_msg = mysql_error(mysql_conn);
            std.debug.print("Connection to database failed: {s}\n", .{err_msg});
            mysql_close(mysql_conn);
            return MySQLError.ConnectionFailed;
        }

        self.conn = mysql_conn;
    }

    pub fn disconnect(self: *MYSQL) void {
        if (self.conn) |conn| {
            mysql_close(conn);
            self.conn = null;
        }
    }

    pub fn createTable(self: *MYSQL, comptime model_meta: parser.ModelMeta) !void {
        if (self.conn == null) return MySQLError.ConnectionFailed;

        var query = std.ArrayList(u8).init(self.allocator);
        defer query.deinit();

        try query.appendSlice("CREATE TABLE IF NOT EXISTS `");
        try query.appendSlice(model_meta.name);
        try query.appendSlice("` (");

        for (model_meta.fields, 0..) |field, i| {
            if (i > 0) try query.appendSlice(", ");

            try query.append('`');
            try query.appendSlice(field.name);
            try query.appendSlice("` ");
            try query.appendSlice(mysqlTypeFromField(field));

            for (field.constraints) |constraint| {
                switch (constraint) {
                    .primary => try query.appendSlice(" PRIMARY KEY"),
                    .unique => try query.appendSlice(" UNIQUE"),
                    else => {},
                }
            }
        }

        try query.appendSlice(");");
        try self.execQuery(query.items, "Create table");
    }

    pub fn insert(self: *MYSQL, comptime T: type, value: T) !void {
        if (self.conn == null) return MySQLError.ConnectionFailed;

        const type_name = @typeName(T);
        const model_name = if (std.mem.endsWith(u8, type_name, ".User")) "User" else type_name;

        var query = std.ArrayList(u8).init(self.allocator);
        defer query.deinit();

        try query.appendSlice("INSERT INTO `");
        try query.appendSlice(model_name);
        try query.appendSlice("` (");

        const fields = std.meta.fields(T);
        inline for (fields, 0..) |field, i| {
            if (i > 0) try query.appendSlice(", ");
            try query.append('`');
            try query.appendSlice(field.name);
            try query.append('`');
        }

        try query.appendSlice(") VALUES (");

        inline for (fields, 0..) |field, i| {
            if (i > 0) try query.appendSlice(", ");
            try query.append('\'');

            const field_value = @field(value, field.name);
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
        try self.execQuery(query.items, "Insert");
    }

    pub fn update(self: *MYSQL, builder: *QueryBuilder) !void {
        if (self.conn == null) return MySQLError.ConnectionFailed;

        var query_text = std.ArrayList(u8).init(self.allocator);
        defer query_text.deinit();

        try builder.buildUpdateQuery(&query_text);

        const normalized_query = try self.normalizeQuery(query_text.items);
        defer self.allocator.free(normalized_query);

        try self.execQuery(normalized_query, "Update");
    }

    pub fn delete(self: *MYSQL, builder: *QueryBuilder) !void {
        if (self.conn == null) return MySQLError.ConnectionFailed;

        var query_text = std.ArrayList(u8).init(self.allocator);
        defer query_text.deinit();

        try builder.buildDeleteQuery(&query_text);

        const normalized_query = try self.normalizeQuery(query_text.items);
        defer self.allocator.free(normalized_query);

        try self.execQuery(normalized_query, "Delete");
    }

    pub fn select(self: *MYSQL, comptime T: type, builder: *QueryBuilder) ![]T {
        const conn = self.conn orelse return MySQLError.ConnectionFailed;

        var query_text = std.ArrayList(u8).init(self.allocator);
        defer query_text.deinit();

        try builder.buildSelectQuery(&query_text);

        const normalized_query = try self.normalizeQuery(query_text.items);
        defer self.allocator.free(normalized_query);

        const c_query = try self.allocator.dupeZ(u8, normalized_query);
        defer self.allocator.free(c_query);

        if (mysql_query(conn, c_query.ptr) != 0) {
            const err_msg = mysql_error(conn);
            std.debug.print("SELECT query failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{normalized_query});
            return MySQLError.QueryFailed;
        }

        const result = mysql_store_result(conn) orelse {
            const err_msg = mysql_error(conn);
            std.debug.print("SELECT query result retrieval failed: {s}\n", .{err_msg});
            std.debug.print("Query was: {s}\n", .{normalized_query});
            return MySQLError.QueryFailed;
        };
        defer mysql_free_result(result);

        const rows: usize = @intCast(mysql_num_rows(result));
        const cols: usize = @intCast(mysql_num_fields(result));

        var out = try self.allocator.alloc(T, rows);
        var i: usize = 0;

        while (mysql_fetch_row(result)) |row_values| {
            var item: T = undefined;
            const fields = std.meta.fields(T);

            inline for (fields, 0..) |field, j| {
                if (j >= cols) break;

                const raw_value = row_values[j];
                const value_ptr = mysqlValuePtr(raw_value);

                if (value_ptr == null) {
                    if (field.type == []const u8) {
                        @field(item, field.name) = try self.allocator.dupe(u8, "");
                    } else if (field.type == i32 or field.type == u32) {
                        @field(item, field.name) = 0;
                    } else {
                        @field(item, field.name) = undefined;
                    }
                    continue;
                }

                const src_text = std.mem.span(@as([*:0]const u8, @ptrCast(value_ptr.?)));
                if (field.type == []const u8) {
                    @field(item, field.name) = try self.allocator.dupe(u8, src_text);
                } else if (field.type == i32) {
                    @field(item, field.name) = std.fmt.parseInt(i32, src_text, 10) catch 0;
                } else if (field.type == u32) {
                    @field(item, field.name) = std.fmt.parseInt(u32, src_text, 10) catch 0;
                } else {
                    @field(item, field.name) = undefined;
                }
            }

            out[i] = item;
            i += 1;
        }

        return out;
    }

    pub fn freeResults(self: *MYSQL, comptime T: type, results: []T) void {
        const fields = std.meta.fields(T);
        for (results) |item| {
            inline for (fields) |field| {
                if (field.type == []const u8) {
                    const field_value = @field(item, field.name);
                    if (field_value.len > 0) {
                        self.allocator.free(field_value);
                    }
                }
            }
        }
        self.allocator.free(results);
    }

    fn execQuery(self: *MYSQL, query: []const u8, context: []const u8) !void {
        const conn = self.conn orelse return MySQLError.ConnectionFailed;

        const c_query = try self.allocator.dupeZ(u8, query);
        defer self.allocator.free(c_query);

        if (mysql_query(conn, c_query.ptr) != 0) {
            const err_msg = mysql_error(conn);
            std.debug.print("{s} failed: {s}\n", .{ context, err_msg });
            std.debug.print("Query was: {s}\n", .{query});
            return MySQLError.QueryFailed;
        }
    }

    fn parseConnInfo(conninfo: []const u8) !ConnConfig {
        var config = ConnConfig{
            .host = "127.0.0.1",
            .user = "root",
            .password = "",
            .database = "",
            .port = 3306,
        };

        var parts = std.mem.splitScalar(u8, conninfo, ' ');
        while (parts.next()) |part| {
            const token = std.mem.trim(u8, part, " \t");
            if (token.len == 0) continue;

            const eq_index = std.mem.indexOfScalar(u8, token, '=') orelse continue;
            const key = std.mem.trim(u8, token[0..eq_index], " \t");
            const value = std.mem.trim(u8, token[eq_index + 1 ..], " \t");

            if (std.mem.eql(u8, key, "host")) {
                config.host = value;
            } else if (std.mem.eql(u8, key, "user")) {
                config.user = value;
            } else if (std.mem.eql(u8, key, "password")) {
                config.password = value;
            } else if (std.mem.eql(u8, key, "database") or std.mem.eql(u8, key, "db")) {
                config.database = value;
            } else if (std.mem.eql(u8, key, "port")) {
                config.port = std.fmt.parseInt(u32, value, 10) catch return MySQLError.FormatFailed;
            }
        }

        if (config.database.len == 0) {
            std.debug.print("MySQL connection info must include database=<name>.\n", .{});
            return MySQLError.FormatFailed;
        }

        return config;
    }

    fn normalizeQuery(self: *MYSQL, query: []const u8) ![]u8 {
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();

        for (query) |ch| {
            if (ch == '"') {
                try out.append('`');
            } else {
                try out.append(ch);
            }
        }

        return out.toOwnedSlice();
    }

    fn mysqlTypeFromField(field: parser.MetaField) []const u8 {
        return switch (field.type) {
            .int => "INT",
            .float => "DOUBLE",
            .string => "VARCHAR(255)",
            .bool => "BOOLEAN",
            .datetime => "DATETIME",
            .objectid => "VARCHAR(255)",
            .relation => if (std.mem.eql(u8, field.name, "id") or std.mem.eql(u8, field.name, "age")) "INT" else "VARCHAR(255)",
        };
    }

    fn mysqlValuePtr(raw_value: anytype) ?[*c]const u8 {
        return switch (@typeInfo(@TypeOf(raw_value))) {
            .optional => if (raw_value) |value| @as([*c]const u8, @ptrCast(value)) else null,
            .pointer => if (@intFromPtr(raw_value) == 0) null else @as([*c]const u8, @ptrCast(raw_value)),
            else => null,
        };
    }
};
