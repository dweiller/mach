const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const math = std.math;
const StructField = std.builtin.Type.StructField;
const EnumField = std.builtin.Type.EnumField;
const UnionField = std.builtin.Type.UnionField;

const Entities = @import("entities.zig").Entities;

/// An ECS module can provide components, systems, and global values.
pub fn Module(comptime Params: anytype) @TypeOf(Params) {
    // TODO: validate the type
    return Params;
}

/// Describes a set of ECS modules, each of which can provide components, systems, and more.
pub fn Modules(comptime modules: anytype) @TypeOf(modules) {
    // TODO: validate the type
    return modules;
}

/// Returns a tagged union representing the messages, turning this:
///
/// ```
/// .{ .tick = void, .foo = i32 }
/// ```
///
/// Into `T`:
///
/// ```
/// const T = union(MessagesTag(messages)) {
///     .tick = void,
///     .foo = i32,
/// };
/// ```
pub fn Messages(comptime messages: anytype) type {
    var fields: []const UnionField = &[0]UnionField{};
    const message_fields = std.meta.fields(@TypeOf(messages));
    inline for (message_fields) |message_field| {
        const message_type = @field(messages, message_field.name);
        fields = fields ++ [_]std.builtin.Type.UnionField{.{
            .name = message_field.name,
            .field_type = message_type,
            .alignment = if (message_type == void) 0 else @alignOf(message_type),
        }};
    }

    // TODO(self-hosted): check if we can remove this now
    // Hack to workaround stage1 compiler bug. https://github.com/ziglang/zig/issues/8114
    //
    // return @Type(.{
    //     .Union = .{
    //         .layout = .Auto,
    //         .tag_type = MessagesTag(messages),
    //         .fields = fields,
    //         .decls = &[_]std.builtin.Type.Declaration{},
    //     },
    // });
    //
    const Ref = union(enum) { temp };
    var info = @typeInfo(Ref);
    info.Union.tag_type = MessagesTag(messages);
    info.Union.fields = fields;
    return @Type(info);
}

/// Returns the tag enum for a tagged union representing the messages, turning this:
///
/// ```
/// .{ .tick = void, .foo = i32 }
/// ```
///
/// Into this:
///
/// ```
/// enum { .tick, .foo };
/// ```
pub fn MessagesTag(comptime messages: anytype) type {
    var fields: []const EnumField = &[0]EnumField{};
    const message_fields = std.meta.fields(@TypeOf(messages));
    inline for (message_fields) |message_field, index| {
        fields = fields ++ [_]std.builtin.Type.EnumField{.{
            .name = message_field.name,
            .value = index,
        }};
    }

    return @Type(.{
        .Enum = .{
            .layout = .Auto,
            .tag_type = std.meta.Int(.unsigned, @floatToInt(u16, math.ceil(math.log2(@intToFloat(f64, message_fields.len))))),
            .fields = fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_exhaustive = true,
        },
    });
}

/// Returns the namespaced components struct **type**.
//
/// Consult `namespacedComponents` for how a value of this type looks.
fn NamespacedComponents(comptime modules: anytype) type {
    var fields: []const StructField = &[0]StructField{};
    inline for (std.meta.fields(@TypeOf(modules))) |module_field| {
        const module = @field(modules, module_field.name);
        if (@hasField(@TypeOf(module), "components")) {
            fields = fields ++ [_]std.builtin.Type.StructField{.{
                .name = module_field.name,
                .field_type = @TypeOf(module.components),
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(@TypeOf(module.components)),
            }};
        }
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

/// Extracts namespaces components from modules like this:
///
/// ```
/// .{
///     .renderer = .{
///         .components = .{
///             .location = Vec3,
///             .rotation = Vec3,
///         },
///         ...
///     },
///     .physics2d = .{
///         .components = .{
///             .location = Vec2
///             .velocity = Vec2,
///         },
///         ...
///     },
/// }
/// ```
///
/// Returning a namespaced components value like this:
///
/// ```
/// .{
///     .renderer = .{
///         .location = Vec3,
///         .rotation = Vec3,
///     },
///     .physics2d = .{
///         .location = Vec2
///         .velocity = Vec2,
///     },
/// }
/// ```
///
fn namespacedComponents(comptime modules: anytype) NamespacedComponents(modules) {
    var x: NamespacedComponents(modules) = undefined;
    inline for (std.meta.fields(@TypeOf(modules))) |module_field| {
        const module = @field(modules, module_field.name);
        if (@hasField(@TypeOf(module), "components")) {
            @field(x, module_field.name) = module.components;
        }
    }
    return x;
}

/// Extracts namespaced globals from modules like this:
///
/// ```
/// .{
///     .renderer = .{
///         .globals = struct{
///             foo: *Bar,
///             baz: Bam,
///         },
///         ...
///     },
///     .physics2d = .{
///         .globals = struct{
///             foo: *Instance,
///         },
///         ...
///     },
/// }
/// ```
///
/// Into a namespaced global type like this:
///
/// ```
/// struct{
///     renderer: struct{
///         foo: *Bar,
///         baz: Bam,
///     },
///     physics2d: struct{
///         foo: *Instance,
///     },
/// }
/// ```
///
fn NamespacedGlobals(comptime modules: anytype) type {
    var fields: []const StructField = &[0]StructField{};
    inline for (std.meta.fields(@TypeOf(modules))) |module_field| {
        const module = @field(modules, module_field.name);
        if (@hasField(@TypeOf(module), "globals")) {
            fields = fields ++ [_]std.builtin.Type.StructField{.{
                .name = module_field.name,
                .field_type = module.globals,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(module.globals),
            }};
        }
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

pub fn World(comptime modules: anytype) type {
    const all_components = namespacedComponents(modules);
    const WorldEntities = Entities(all_components);
    return struct {
        allocator: Allocator,
        entities: WorldEntities,
        globals: NamespacedGlobals(modules),

        const Self = @This();

        pub fn init(allocator: Allocator) !Self {
            return Self{
                .allocator = allocator,
                .entities = try Entities(all_components).init(allocator),
                .globals = undefined,
            };
        }

        pub fn deinit(world: *Self) void {
            world.entities.deinit();
        }

        /// Gets a global value called `.global_tag` from the module named `.module_tag`
        pub fn get(world: *Self, comptime module_tag: anytype, comptime global_tag: anytype) @TypeOf(@field(
            @field(world.globals, @tagName(module_tag)),
            @tagName(global_tag),
        )) {
            return comptime @field(
                @field(world.globals, @tagName(module_tag)),
                @tagName(global_tag),
            );
        }

        /// Sets a global value called `.global_tag` in the module named `.module_tag`
        pub fn set(
            world: *Self,
            comptime module_tag: anytype,
            comptime global_tag: anytype,
            value: @TypeOf(@field(
                @field(world.globals, @tagName(module_tag)),
                @tagName(global_tag),
            )),
        ) void {
            comptime @field(
                @field(world.globals, @tagName(module_tag)),
                @tagName(global_tag),
            ) = value;
        }

        /// Tick sends the global 'tick' message to all modules that are subscribed to it.
        pub fn tick(world: *Self) void {
            _ = world;
            inline for (std.meta.fields(@TypeOf(modules))) |module_field| {
                const module = @field(modules, module_field.name);
                if (@hasField(@TypeOf(module), "messages")) {
                    if (@hasField(module.messages, "tick")) module.update(.tick);
                }
            }
        }

        const namespaces = std.meta.fields(@TypeOf(all_components));

        pub const ComponentAccess = ComponentAccess: {
            var fields: [namespaces.len]std.builtin.Type.UnionField = undefined;

            inline for (namespaces) |namespace, i| {
                const component_enum = std.meta.FieldEnum(namespace.field_type);
                const comp_info = @typeInfo(component_enum).Enum;
                var comp_access_fields: [comp_info.fields.len]std.builtin.Type.StructField = undefined;
                inline for (comp_access_fields) |*access, field_idx| {
                    const field_name = comp_info.fields[field_idx].name;
                    access.* = std.builtin.Type.StructField{
                        .name = field_name,
                        .field_type = ?Access,
                        .default_value = &Access.unused,
                        .is_comptime = false,
                        .alignment = @alignOf(?Access),
                    };
                }
                const CompAccess = @Type(std.builtin.Type{ .Struct = .{
                    .layout = .Auto,
                    .fields = &comp_access_fields,
                    .decls = &.{},
                    .is_tuple = false,
                } });

                fields[i] = .{
                    .name = namespace.name,
                    .field_type = CompAccess,
                    .alignment = @alignOf(CompAccess),
                };
            }

            // need type_info variable (rather than embedding in @Type() call)
            // to work around stage 1 bug
            const type_info = std.builtin.Type{
                .Union = .{
                    .layout = .Auto,
                    .tag_type = std.meta.FieldEnum(@TypeOf(all_components)),
                    .fields = &fields,
                    .decls = &.{},
                },
            };
            break :ComponentAccess @Type(type_info);
        };

        fn extractQuery(comptime components: []const ComponentAccess) []const WorldEntities.Query {
            const num_components = 20;
            var query: [num_components]WorldEntities.Query = undefined;
            var comp_idx = 0;
            for (components) |comp_access| {
                const namespace = std.meta.activeTag(comp_access);
                const namespace_name = @tagName(namespace);
                const comp_struct = @field(comp_access, namespace_name);
                const comp_info = @typeInfo(@TypeOf(comp_struct)).Struct;
                inline for (comp_info.fields) |field, i| {
                    const component = @field(comp_struct, field.name);
                    _ = i;
                    // const Component = std.meta.fieldInfo(
                    //     WorldEntities.Query,
                    //     @intToEnum(std.meta.FieldEnum(WorldEntities.Query), i),
                    // ).field_type;
                    if (component != null) {
                        query[comp_idx] = @unionInit(
                            WorldEntities.Query,
                            @tagName(namespace),
                            .id,
                        );
                        comp_idx += 1;
                    }
                }
            }
            return query[0..comp_idx];
        }

        pub const Access = union(enum) {
            read: void,
            modify: void,

            const unused: ?Access = null;
        };

        fn SystemFuncType(comptime query: []const ComponentAccess) type {
            var i = 0;
            var params: [query.len]std.builtin.Type.Fn.Param = undefined;
            for (query) |comp_access| {
                const namespace = std.meta.activeTag(comp_access);
                const components = @field(comp_access, @tagName(namespace));
                for (@typeInfo(@TypeOf(components)).Struct.fields) |component_info| {
                    const Component = @field(@field(all_components, @tagName(namespace)), component_info.name);
                    const access = @field(components, component_info.name);
                    if (access) |mode| {
                        const param_type = switch (mode) {
                            .read => Component,
                            .modify => *Component,
                        };
                        params[i] = .{ .is_generic = false, .is_noalias = false, .arg_type = param_type };
                        i += 1;
                    }
                }
            }
            const type_info = std.builtin.Type{
                .Fn = .{
                    .calling_convention = .Unspecified,
                    .alignment = 0,
                    .is_generic = false,
                    .is_var_args = false,
                    .return_type = void,
                    .args = params[0..i],
                },
            };
            return @Type(type_info);
        }

        pub fn LocalSystem(
            comptime query_access: []const ComponentAccess,
            comptime func: SystemFuncType(query_access),
        ) fn (*Self) void {
            const gen = struct {
                pub fn update(world: *Self) void {
                    const components = comptime extractQuery(query_access);
                    var iter = world.entities.query(components);
                    while (iter.next()) |entry| {
                        var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
                        inline for (@typeInfo(@TypeOf(args)).Struct.fields) |field_info, i| {
                            const namespace_name = comptime std.meta.activeTag(components[i]);
                            const component_name = @field(components[i], @tagName(namespace_name));
                            @field(args, field_info.name) = switch (@typeInfo(field_info.field_type)) {
                                .Pointer => world.entities.getComponentPtr(
                                    entry.entity,
                                    namespace_name,
                                    component_name,
                                ).?,
                                else => world.entities.getComponent(
                                    entry.entity,
                                    namespace_name,
                                    component_name,
                                ).?,
                            };
                        }
                        @call(.{ .modifier = .always_inline }, func, args);
                    }
                }
            };
            return gen.update;
        }
    };
}
