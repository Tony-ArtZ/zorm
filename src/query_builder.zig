// filepath: /home/vera/projects/zorm/src/query_builder.zig
const std = @import("std");
const parser = @import("parser.zig");

pub const OrderDirection = enum {
    ASC,
    DESC,
};

pub const ComparisonOperator = enum {
    EQ, // =
    NE, // <>
    LT, // <
    GT, // >
    LTE, // <=
    GTE, // >=
    LIKE, // LIKE
    ILIKE, // ILIKE (PostgreSQL case-insensitive LIKE)
    IN, // IN (value list)
    IS_NULL, // IS NULL
    IS_NOT_NULL, // IS NOT NULL
};

pub const LogicalOperator = enum {
    AND,
    OR,
};

pub const WhereCondition = struct {
    field: []const u8,
    operator: ComparisonOperator,
    value: ?[]const u8 = null, // null for IS NULL / IS NOT NULL
    values: ?[]const []const u8 = null, // for IN operator
};

pub const OrderByClause = struct {
    field: []const u8,
    direction: OrderDirection,
};

pub const QueryBuilder = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    model_meta: ?*const parser.ModelMeta = null,

    // Query components
    select_fields: std.ArrayList([]const u8),
    where_conditions: std.ArrayList(WhereCondition),
    logical_operators: std.ArrayList(LogicalOperator),
    order_by_clauses: std.ArrayList(OrderByClause),
    limit_value: ?usize = null,
    offset_value: ?usize = null,

    insert_data: std.StringHashMap([]const u8),
    update_data: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, model_meta: *const parser.ModelMeta) !QueryBuilder {
        return QueryBuilder{
            .allocator = allocator,
            .table_name = model_meta.name,
            .model_meta = model_meta,
            .select_fields = std.ArrayList([]const u8).init(allocator),
            .where_conditions = std.ArrayList(WhereCondition).init(allocator),
            .logical_operators = std.ArrayList(LogicalOperator).init(allocator),
            .order_by_clauses = std.ArrayList(OrderByClause).init(allocator),
            .insert_data = std.StringHashMap([]const u8).init(allocator),
            .update_data = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *QueryBuilder) void {
        if (self.model_meta == null) {
            self.allocator.free(self.table_name);
        }

        for (self.select_fields.items) |field| {
            self.allocator.free(field);
        }
        self.select_fields.deinit();

        for (self.where_conditions.items) |condition| {
            if (condition.value) |value| {
                self.allocator.free(value);
            }
            if (condition.values) |values| {
                for (values) |value| {
                    self.allocator.free(value);
                }
                self.allocator.free(values);
            }
            self.allocator.free(condition.field);
        }
        self.where_conditions.deinit();

        self.logical_operators.deinit();

        for (self.order_by_clauses.items) |clause| {
            self.allocator.free(clause.field);
        }
        self.order_by_clauses.deinit();

        var insert_it = self.insert_data.iterator();
        while (insert_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.insert_data.deinit();

        var update_it = self.update_data.iterator();
        while (update_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.update_data.deinit();
    }

    pub fn select(self: *QueryBuilder, fields: ?[]const []const u8) !*QueryBuilder {
        for (self.select_fields.items) |field| {
            self.allocator.free(field);
        }
        try self.select_fields.resize(0);

        if (fields) |field_list| {
            for (field_list) |field| {
                const field_copy = try self.allocator.dupe(u8, field);
                try self.select_fields.append(field_copy);
            }
        }

        return self;
    }

    pub fn selectAll(self: *QueryBuilder) !*QueryBuilder {
        for (self.select_fields.items) |field| {
            self.allocator.free(field);
        }
        try self.select_fields.resize(0);

        return self;
    }

    pub fn where(self: *QueryBuilder, field: []const u8, operator: ComparisonOperator, value: ?[]const u8) !*QueryBuilder {
        const field_copy = try self.allocator.dupe(u8, field);

        var value_copy: ?[]const u8 = null;
        if (value) |val| {
            value_copy = try self.allocator.dupe(u8, val);
        }

        const condition = WhereCondition{
            .field = field_copy,
            .operator = operator,
            .value = value_copy,
        };

        try self.where_conditions.append(condition);

        return self;
    }

    pub fn whereIn(self: *QueryBuilder, field: []const u8, values: []const []const u8) !*QueryBuilder {
        const field_copy = try self.allocator.dupe(u8, field);

        var values_copy = try self.allocator.alloc([]const u8, values.len);
        for (values, 0..) |val, i| {
            values_copy[i] = try self.allocator.dupe(u8, val);
        }

        const condition = WhereCondition{
            .field = field_copy,
            .operator = ComparisonOperator.IN,
            .values = values_copy,
        };

        try self.where_conditions.append(condition);

        return self;
    }

    pub fn whereNull(self: *QueryBuilder, field: []const u8) !*QueryBuilder {
        const field_copy = try self.allocator.dupe(u8, field);

        const condition = WhereCondition{
            .field = field_copy,
            .operator = ComparisonOperator.IS_NULL,
        };

        try self.where_conditions.append(condition);

        return self;
    }

    pub fn whereNotNull(self: *QueryBuilder, field: []const u8) !*QueryBuilder {
        const field_copy = try self.allocator.dupe(u8, field);

        const condition = WhereCondition{
            .field = field_copy,
            .operator = ComparisonOperator.IS_NOT_NULL,
        };

        try self.where_conditions.append(condition);

        return self;
    }

    pub fn andWhere(self: *QueryBuilder) !*QueryBuilder {
        try self.logical_operators.append(LogicalOperator.AND);
        return self;
    }

    pub fn orWhere(self: *QueryBuilder) !*QueryBuilder {
        try self.logical_operators.append(LogicalOperator.OR);
        return self;
    }

    pub fn orderBy(self: *QueryBuilder, field: []const u8, direction: OrderDirection) !*QueryBuilder {
        const field_copy = try self.allocator.dupe(u8, field);

        try self.order_by_clauses.append(OrderByClause{
            .field = field_copy,
            .direction = direction,
        });

        return self;
    }

    pub fn limit(self: *QueryBuilder, value: usize) *QueryBuilder {
        self.limit_value = value;
        return self;
    }

    pub fn offset(self: *QueryBuilder, value: usize) *QueryBuilder {
        self.offset_value = value;
        return self;
    }

    pub fn insert(self: *QueryBuilder, data: std.StringHashMap([]const u8)) !*QueryBuilder {
        var it = self.insert_data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.insert_data.clearRetainingCapacity();

        var data_it = data.iterator();
        while (data_it.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            const value_copy = try self.allocator.dupe(u8, entry.value_ptr.*);
            try self.insert_data.put(key_copy, value_copy);
        }

        return self;
    }

    pub fn update(self: *QueryBuilder, data: std.StringHashMap([]const u8)) !*QueryBuilder {
        var it = self.update_data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.update_data.clearRetainingCapacity();

        var data_it = data.iterator();
        while (data_it.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            const value_copy = try self.allocator.dupe(u8, entry.value_ptr.*);
            try self.update_data.put(key_copy, value_copy);
        }

        return self;
    }

    pub fn buildSelectQuery(self: *QueryBuilder, buffer: *std.ArrayList(u8)) !void {
        try buffer.appendSlice("SELECT ");

        if (self.select_fields.items.len == 0) {
            try buffer.appendSlice("*");
        } else {
            for (self.select_fields.items, 0..) |field, i| {
                if (i > 0) try buffer.appendSlice(", ");
                try buffer.append('"');
                try buffer.appendSlice(field);
                try buffer.append('"');
            }
        }

        try buffer.appendSlice(" FROM \"");
        try buffer.appendSlice(self.table_name);
        try buffer.append('"');

        try self.appendWhereClause(buffer);
        try self.appendOrderByClause(buffer);

        if (self.limit_value) |limit_val| {
            try buffer.appendSlice(" LIMIT ");
            try std.fmt.format(buffer.writer(), "{}", .{limit_val});
        }

        if (self.offset_value) |offset_val| {
            try buffer.appendSlice(" OFFSET ");
            try std.fmt.format(buffer.writer(), "{}", .{offset_val});
        }

        try buffer.append(';');
    }

    pub fn buildInsertQuery(self: *QueryBuilder, buffer: *std.ArrayList(u8)) !void {
        if (self.insert_data.count() == 0) {
            return;
        }

        try buffer.appendSlice("INSERT INTO \"");
        try buffer.appendSlice(self.table_name);
        try buffer.appendSlice("\" (");

        var i: usize = 0;
        var it = self.insert_data.iterator();
        while (it.next()) |entry| {
            if (i > 0) try buffer.appendSlice(", ");
            try buffer.append('"');
            try buffer.appendSlice(entry.key_ptr.*);
            try buffer.append('"');
            i += 1;
        }

        try buffer.appendSlice(") VALUES (");

        i = 0;
        it = self.insert_data.iterator();
        while (it.next()) |entry| {
            if (i > 0) try buffer.appendSlice(", ");
            try buffer.append('\'');
            try buffer.appendSlice(entry.value_ptr.*);
            try buffer.append('\'');
            i += 1;
        }

        try buffer.appendSlice(");");
    }

    pub fn buildUpdateQuery(self: *QueryBuilder, buffer: *std.ArrayList(u8)) !void {
        if (self.update_data.count() == 0) {
            return;
        }

        try buffer.appendSlice("UPDATE \"");
        try buffer.appendSlice(self.table_name);
        try buffer.appendSlice("\" SET ");

        var i: usize = 0;
        var it = self.update_data.iterator();
        while (it.next()) |entry| {
            if (i > 0) try buffer.appendSlice(", ");
            try buffer.append('"');
            try buffer.appendSlice(entry.key_ptr.*);
            try buffer.appendSlice("\" = '");
            try buffer.appendSlice(entry.value_ptr.*);
            try buffer.append('\'');
            i += 1;
        }

        try self.appendWhereClause(buffer);
        try buffer.append(';');
    }

    pub fn buildDeleteQuery(self: *QueryBuilder, buffer: *std.ArrayList(u8)) !void {
        try buffer.appendSlice("DELETE FROM \"");
        try buffer.appendSlice(self.table_name);
        try buffer.append('"');

        try self.appendWhereClause(buffer);
        try buffer.append(';');
    }

    fn appendWhereClause(self: *QueryBuilder, buffer: *std.ArrayList(u8)) !void {
        if (self.where_conditions.items.len == 0) {
            return;
        }

        try buffer.appendSlice(" WHERE ");

        for (self.where_conditions.items, 0..) |condition, i| {
            if (i > 0) {
                const op = if (i - 1 < self.logical_operators.items.len)
                    self.logical_operators.items[i - 1]
                else
                    LogicalOperator.AND;

                try buffer.append(' ');
                switch (op) {
                    LogicalOperator.AND => try buffer.appendSlice("AND"),
                    LogicalOperator.OR => try buffer.appendSlice("OR"),
                }
                try buffer.append(' ');
            }

            try buffer.append('"');
            try buffer.appendSlice(condition.field);
            try buffer.append('"');
            try buffer.append(' ');

            switch (condition.operator) {
                .EQ => try buffer.appendSlice("="),
                .NE => try buffer.appendSlice("<>"),
                .LT => try buffer.appendSlice("<"),
                .GT => try buffer.appendSlice(">"),
                .LTE => try buffer.appendSlice("<="),
                .GTE => try buffer.appendSlice(">="),
                .LIKE => try buffer.appendSlice("LIKE"),
                .ILIKE => try buffer.appendSlice("ILIKE"),
                .IN => try buffer.appendSlice("IN"),
                .IS_NULL => {
                    try buffer.appendSlice("IS NULL");
                    continue;
                },
                .IS_NOT_NULL => {
                    try buffer.appendSlice("IS NOT NULL");
                    continue;
                },
            }

            try buffer.append(' ');

            if (condition.operator == .IN) {
                try buffer.append('(');
                if (condition.values) |values| {
                    for (values, 0..) |value, j| {
                        if (j > 0) try buffer.appendSlice(", ");
                        try buffer.append('\'');
                        try buffer.appendSlice(value);
                        try buffer.append('\'');
                    }
                }
                try buffer.append(')');
            } else if (condition.value) |value| {
                try buffer.append('\'');
                try buffer.appendSlice(value);
                try buffer.append('\'');
            }
        }
    }

    fn appendOrderByClause(self: *QueryBuilder, buffer: *std.ArrayList(u8)) !void {
        if (self.order_by_clauses.items.len == 0) {
            return;
        }

        try buffer.appendSlice(" ORDER BY ");

        for (self.order_by_clauses.items, 0..) |clause, i| {
            if (i > 0) try buffer.appendSlice(", ");
            try buffer.append('"');
            try buffer.appendSlice(clause.field);
            try buffer.append('"');
            try buffer.append(' ');

            switch (clause.direction) {
                OrderDirection.ASC => try buffer.appendSlice("ASC"),
                OrderDirection.DESC => try buffer.appendSlice("DESC"),
            }
        }
    }
};
