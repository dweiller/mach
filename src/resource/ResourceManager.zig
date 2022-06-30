const std = @import("std");
const uri_parser = @import("uri_parser.zig");

const ResourceManager = @This();

allocator: std.mem.Allocator,
paths: []const []const u8,
// TODO: Use comptime hash map for resource_types
resource_map: std.StringArrayHashMapUnmanaged(ResourceType) = .{},
resources: std.StringHashMapUnmanaged(Resource) = .{},
cwd: std.fs.Dir,
context: ?*anyopaque = null,

pub fn init(allocator: std.mem.Allocator, paths: []const []const u8, resource_types: []const ResourceType) !ResourceManager {
    const path = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(path);
    var cwd = try std.fs.openDirAbsolute(path, .{});
    errdefer cwd.close();

    var resource_map: std.StringArrayHashMapUnmanaged(ResourceType) = .{};
    for (resource_types) |res| {
        try resource_map.put(allocator, res.name, res);
    }

    return ResourceManager{
        .allocator = allocator,
        .paths = paths,
        .resource_map = resource_map,
        .cwd = cwd,
    };
}

pub const ResourceType = struct {
    name: []const u8,
    load: *const fn (context: ?*anyopaque, mem: []const u8) error{ InvalidResource, CorruptData }!*anyopaque,
    unload: *const fn (context: ?*anyopaque, resource: *anyopaque) void,
};

pub fn setLoadContext(self: *ResourceManager, ctx: anytype) void {
    var context = self.allocator.create(@TypeOf(ctx)) catch unreachable;
    context.* = ctx;
    self.context = context;
}

pub fn removeLoadContext(self: *ResourceManager, comptime T: type) void {
    if (self.context) |ctx| {
        const casted_ptr = @ptrCast(*T, @alignCast(@alignOf(T), ctx));
        self.allocator.destroy(casted_ptr);
    }
}

pub fn getResource(self: *ResourceManager, uri: []const u8) !Resource {
    if (self.resources.get(uri)) |res|
        return res;

    var file: ?std.fs.File = null;
    defer if (file) |f| f.close();
    const uri_data = try uri_parser.parseUri(uri);

    for (self.paths) |path| {
        var dir = try self.cwd.openDir(path, .{});
        defer dir.close();

        file = dir.openFile(uri_data.path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        break;
    }

    if (file) |f| {
        if (self.resource_map.get(uri_data.scheme)) |res_type| {
            var data = try f.reader().readAllAlloc(self.allocator, std.math.maxInt(usize));
            errdefer self.allocator.free(data);

            const resource = try res_type.load(self.allocator, self.context, data);
            errdefer res_type.unload(self.allocator, self.context, resource);

            const res = Resource{
                .uri = try self.allocator.dupe(u8, uri),
                .resource = resource,
                .size = data.len,
            };
            try self.resources.putNoClobber(self.allocator, res.uri, res);
            return res;
        }
        return error.UnknownResourceType;
    }

    return error.ResourceNotFound;
}

pub fn unloadResource(self: *ResourceManager, res: Resource) void {
    const uri_data = uri_parser.parseUri(res.uri) catch unreachable;
    if (self.resource_map.get(uri_data.scheme)) |res_type| {
        res_type.unload(self.allocator, self.context, res.resource);
    }

    _ = self.resources.remove(res.uri);
    self.allocator.free(res.uri);
}

pub fn deinit(self: *ResourceManager) ?*anyopaque {
    var removal_stack = std.BoundedArray(Resource, 64){};
    var again = true;
    while (again) {
        again = false;
        var iter = self.resources.valueIterator();
        while (iter.next()) |res_ptr| {
            removal_stack.append(res_ptr.*) catch {
                again = true;
                break;
            };
        }
        while (removal_stack.popOrNull()) |res| {
            self.unloadResource(res);
        }
    }
    self.resources.deinit(self.allocator);
    self.resource_map.deinit(self.allocator);
    self.cwd.close();
    return self.context;
}

pub const Resource = struct {
    uri: []const u8,
    resource: *anyopaque,
    size: u64,

    // Returns the raw data, which you can use in any ways. Internally it is stored
    // as an *anyopaque
    pub fn getData(res: Resource, comptime T: type) *T {
        return @ptrCast(*T, @alignCast(std.meta.alignment(*T), res.resource));
    }
};
