const std = @import("std");

pub const DatabaseType = enum {
    postgres,
    sqlite,
    mongo,
};

pub const FieldType = enum {
    int,
    float,
    string,
    bool,
    datetime,
    relation,
    objectid, // for MongoDB
};

pub const MetaField = struct {
    name: []const u8,
    type: FieldType,
    constraints: []const Constraint,
};

pub const Constraint = union(enum) {
    primary,
    unique,
    optional,
    default: []const u8,
    foreign_key: struct {
        model: []const u8,
        field: []const u8,
    },
};

pub const Field = struct {
    name: []const u8,
    type: FieldType,
    constraints: std.ArrayList(Constraint),
};

pub const Model = struct {
    name: []const u8,
    fields: std.ArrayList(Field),
};

pub const ModelMeta = struct {
    name: []const u8,
    fields: []const MetaField,
};

pub const Schema = struct {
    models: std.ArrayList(Model),
    db_type: DatabaseType,
};

pub const ParserError = error{
    InvalidConfig,
    UnknownBackend,
    InvalidModel,
    InvalidField,
    MissingFieldType,
    UnexpectedEOF,
    OutOfMemory,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    models: std.ArrayList(Model),
    db_type: DatabaseType,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return Parser{
            .allocator = allocator,
            .models = std.ArrayList(Model).init(allocator),
            .db_type = undefined,
        };
    }

    pub fn deinit(self: *Parser) void {
        for (self.models.items) |*model| {
            for (model.fields.items) |*field| {
                field.constraints.deinit();
            }
            model.fields.deinit();
        }
        self.models.deinit();
    }

    pub fn parse(self: *Parser, input: []const u8) ParserError!Schema {
        var lines = std.mem.splitScalar(u8, input, '\n');
        var current_model: ?Model = null;
        var fields = std.ArrayList(Field).init(self.allocator);
        var in_config = false;
        var effective_db_type: DatabaseType = undefined;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");

            if (std.mem.startsWith(u8, trimmed, "[config]")) {
                in_config = true;
                continue;
            }

            // Parse config section
            if (in_config) {
                if (trimmed.len == 0) continue;
                if (std.mem.startsWith(u8, trimmed, "backend ")) {
                    const sliced = trimmed[8..];
                    if (sliced.len == 0) return ParserError.InvalidConfig;
                    const backend_val = std.mem.trim(u8, sliced, " \t");

                    std.debug.print("Backend value: {s}\n", .{backend_val});
                    if (std.mem.eql(u8, backend_val, "mongodb")) {
                        effective_db_type = DatabaseType.mongo;
                    } else if (std.mem.eql(u8, backend_val, "postgres")) {
                        effective_db_type = DatabaseType.postgres;
                    } else if (std.mem.eql(u8, backend_val, "sqlite")) {
                        effective_db_type = DatabaseType.sqlite;
                    } else {
                        return ParserError.UnknownBackend;
                    }
                } else if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "model ")) {
                    return ParserError.InvalidConfig;
                }
                // End config section if next section starts
                if (std.mem.startsWith(u8, trimmed, "model ")) {
                    in_config = false;
                } else {
                    continue;
                }
            }

            // Parse model section
            if (std.mem.startsWith(u8, trimmed, "model ")) {
                if (current_model) |m| {
                    var model = m;
                    model.fields = fields;
                    try self.models.append(model);
                    fields = std.ArrayList(Field).init(self.allocator);
                }
                const nameSliced = trimmed[6..];
                const name = std.mem.trim(u8, nameSliced, " {\t");
                if (name.len == 0) return ParserError.InvalidModel;
                current_model = Model{
                    .name = name,
                    .fields = undefined, // will set later
                };
            } else if (std.mem.startsWith(u8, trimmed, "}")) {
                if (current_model) |m| {
                    var model = m;
                    model.fields = fields;
                    try self.models.append(model);
                    current_model = null;
                    fields = std.ArrayList(Field).init(self.allocator);
                } else {
                    return ParserError.InvalidModel;
                }
            } else if (trimmed.len > 0) {
                // Parse field line: name type [@constraint ...]
                var tokens = std.mem.splitScalar(u8, trimmed, ' ');
                const field_name = tokens.next() orelse return ParserError.InvalidField;
                var type_str = tokens.next() orelse return ParserError.MissingFieldType;

                // Check if type ends with ? for optional
                var is_optional_from_type = false;
                if (std.mem.endsWith(u8, type_str, "?")) {
                    is_optional_from_type = true;
                    type_str = type_str[0 .. type_str.len - 1]; // Remove the ?
                }

                var field_type: FieldType = undefined;
                if (std.mem.eql(u8, type_str, "Int")) {
                    field_type = FieldType.int;
                } else if (std.mem.eql(u8, type_str, "String")) {
                    field_type = FieldType.string;
                } else if (std.mem.eql(u8, type_str, "Float")) {
                    field_type = FieldType.float;
                } else if (std.mem.eql(u8, type_str, "Bool")) {
                    field_type = FieldType.bool;
                } else if (std.mem.eql(u8, type_str, "DateTime")) {
                    field_type = FieldType.datetime;
                } else if (std.mem.eql(u8, type_str, "ObjectId")) {
                    field_type = FieldType.objectid;
                } else {
                    field_type = FieldType.relation;
                }
                var constraints = std.ArrayList(Constraint).init(self.allocator);

                // Add optional constraint if type ended with ?
                if (is_optional_from_type) {
                    try constraints.append(Constraint.optional);
                }

                while (tokens.next()) |tok| {
                    if (std.mem.startsWith(u8, tok, "@id")) {
                        try constraints.append(Constraint.primary);
                    } else if (std.mem.startsWith(u8, tok, "@unique")) {
                        try constraints.append(Constraint.unique);
                    } else if (std.mem.startsWith(u8, tok, "?")) {
                        try constraints.append(Constraint.optional);
                    }
                    //TODO: Add more constraints
                }
                try fields.append(Field{
                    .name = field_name,
                    .type = field_type,
                    .constraints = constraints,
                });
            }
        }
        if (current_model) |m| {
            var model = m;
            model.fields = fields;
            try self.models.append(model);
        }
        self.db_type = effective_db_type;
        return Schema{
            .models = self.models,
            .db_type = self.db_type,
        };
    }
};
