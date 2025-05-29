const std = @import("std");
const Parser = @import("parser.zig");
const FieldType = Parser.FieldType;
const Constraint = Parser.Constraint;
const DatabaseType = Parser.DatabaseType;
const ParserError = Parser.ParserError;

fn zigTypeFromFieldType(field_type: FieldType) []const u8 {
    return switch (field_type) {
        .int => "i32",
        .float => "f64",
        .string => "[]const u8",
        .bool => "bool",
        .datetime => "i64", // Unix timestamp
        .objectid => "[]const u8", // ObjectId as string
        .relation => "[]const u8", // Will be refined based on actual relation
    };
}

fn generateStructField(writer: anytype, field: Parser.Field) !void {
    const is_optional = blk: {
        for (field.constraints.items) |constraint| {
            if (constraint == .optional) break :blk true;
        }
        break :blk false;
    };

    const field_type = zigTypeFromFieldType(field.type);
    if (is_optional) {
        try writer.print("    {s}: ?{s},\n", .{ field.name, field_type });
    } else {
        try writer.print("    {s}: {s},\n", .{ field.name, field_type });
    }
}

fn generateModel(writer: anytype, model: Parser.Model) !void {
    try writer.print("pub const {s} = struct {{\n", .{model.name});

    for (model.fields.items) |field| {
        try generateStructField(writer, field);
    }

    try writer.print("}};\n\n", .{});
}

fn generateMetadataModel(writer: anytype, model: Parser.Model) !void {
    try writer.print("pub const {s}Meta = ModelMeta{{\n", .{model.name});
    try writer.print("    .name = \"{s}\",\n", .{model.name});
    try writer.print("    .fields = &[_]MetaField{{\n", .{});

    for (model.fields.items) |field| {
        try writer.print("        .{{ .name = \"{s}\", .type = .{s}, .constraints = &[_]Constraint{{", .{ field.name, @tagName(field.type) });

        for (field.constraints.items, 0..) |constraint, i| {
            if (i > 0) try writer.print(", ", .{});
            switch (constraint) {
                .primary => try writer.print(".primary", .{}),
                .unique => try writer.print(".unique", .{}),
                .optional => try writer.print(".optional", .{}),
                .default => |val| try writer.print(".{{ .default = \"{s}\" }}", .{val}),
                .foreign_key => |fk| try writer.print(".{{ .foreign_key = .{{ .model = \"{s}\", .field = \"{s}\" }} }}", .{ fk.model, fk.field }),
            }
        }

        try writer.print("}} }},\n", .{});
    }

    try writer.print("    }},\n", .{});
    try writer.print("}};\n\n", .{});
}

fn generateMetaFile(allocator: std.mem.Allocator, schema: Parser.Schema, output_path: []const u8) !void {
    // Ensure the directory exists
    if (std.fs.path.dirname(output_path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    var buffered_writer = std.io.bufferedWriter(file.writer());
    const writer = buffered_writer.writer();

    // Generate header with import path that works from user's project
    try writer.print("// Generated file - Do not edit manually\n", .{});
    try writer.print("// Generated from schema.zorm\n\n", .{});
    try writer.print("const std = @import(\"std\");\n", .{});
    try writer.print("const zorm = @import(\"zorm\");\n\n", .{});
    try writer.print("pub const FieldType = zorm.FieldType;\n", .{});
    try writer.print("pub const Constraint = zorm.Constraint;\n", .{});
    try writer.print("pub const DatabaseType = zorm.DatabaseType;\n\n", .{});
    try writer.print("pub const MetaField = zorm.parser.MetaField;\n\n", .{});
    try writer.print("pub const ModelMeta = zorm.parser.ModelMeta;\n\n", .{});

    // Generate database type constant
    try writer.print("pub const DATABASE_TYPE = DatabaseType.{s};\n\n", .{@tagName(schema.db_type)});

    // Generate all model structs
    for (schema.models.items) |model| {
        try generateModel(writer, model);
    }

    // Generate metadata structs
    for (schema.models.items) |model| {
        try generateMetadataModel(writer, model);
    }

    // Generate a union type containing all models
    try writer.print("pub const Models = union(enum) {{\n", .{});
    for (schema.models.items) |model| {
        // Convert to lowercase for union field name
        var lowercase_name = try allocator.alloc(u8, model.name.len);
        defer allocator.free(lowercase_name);
        for (model.name, 0..) |c, i| {
            lowercase_name[i] = std.ascii.toLower(c);
        }
        try writer.print("    {s}: {s},\n", .{ lowercase_name, model.name });
    }
    try writer.print("}};\n\n", .{});

    // Generate model names array
    try writer.print("pub const MODEL_NAMES = [_][]const u8{{\n", .{});
    for (schema.models.items) |model| {
        try writer.print("    \"{s}\",\n", .{model.name});
    }
    try writer.print("}};\n", .{});

    try buffered_writer.flush();
}

pub fn main() !void {
    std.debug.print("Generating ZORM schema...\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.skip();

    const schema_path = args.next() orelse "schema.zorm";
    const output_path = args.next() orelse "generated_schema.zig";

    try generateSchema(allocator, schema_path, output_path);

    std.debug.print("Generated {s} \n", .{output_path});
}

// Wrapper function to use as an import
pub fn generateSchema(
    allocator: std.mem.Allocator,
    schema_path: []const u8,
    output_path: []const u8,
) !void {
    const file = try std.fs.cwd().openFile(schema_path, .{});
    defer file.close();

    const schema_file = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(schema_file);

    if (schema_file.len == 0) {
        return ParserError.InvalidConfig;
    }

    var parser = Parser.Parser.init(allocator);
    defer parser.deinit();
    const schema = try parser.parse(schema_file);

    // Generate schema file in user's project, not in library src/
    try generateMetaFile(allocator, schema, output_path);
}
