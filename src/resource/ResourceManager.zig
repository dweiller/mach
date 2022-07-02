const std = @import("std");
const uri_parser = @import("uri_parser.zig");

const ResourceManager = @This();

allocator: std.mem.Allocator,
paths: []const []const u8,
// TODO: Use comptime hash map for resource_types
resource_map: std.StringArrayHashMapUnmanaged(ResourceType) = .{},
file_cache: std.BufMap,
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
        // TODO: Unmanaged version of std.BufMap would be nice
        .file_cache = std.BufMap.init(allocator),
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

pub fn clearCache(self: *ResourceManager) void {
    self.file_cache.deinit();
    self.file_cache = std.BufMap.init(self.allocator);
}

pub fn unloadCachedFile(self: *ResourceManager, path: []const u8) void {
    self.file_cache.remove(path);
}

fn loadFromBytes(self: *ResourceManager, res_type: ResourceType, uri: []const u8, data: []const u8) !Resource {
    const resource = try res_type.load(self.allocator, self.context, data);
    errdefer res_type.unload(self.allocator, self.context, resource);

    const res = Resource{
        .uri = try self.allocator.dupe(u8, uri),
        .resource = resource,
    };
    try self.resources.putNoClobber(self.allocator, res.uri, res);
    return res;
}

pub fn getResource(self: *ResourceManager, uri: []const u8) !Resource {
    if (self.resources.get(uri)) |res|
        return res;

    const uri_data = try uri_parser.parseUri(uri);

    if (self.file_cache.get(uri_data.path)) |bytes| {
        if (self.resource_map.get(uri_data.scheme)) |res_type| {
            const res = try self.loadFromBytes(res_type, uri, bytes);
            return res;
        }
    }

    var file: ?std.fs.File = null;
    defer if (file) |f| f.close();

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
            // file_cache.put() copies the key and data slices, so we need to cleanup `data`;
            // TODO: altered implementation of std.BufMap for copying key but moving value
            defer self.allocator.free(data);

            try self.file_cache.put(uri_data.path, data);
            const res = try self.loadFromBytes(res_type, uri, data);
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
    self.file_cache.deinit();
    self.cwd.close();
    return self.context;
}

pub const Resource = struct {
    uri: []const u8,
    resource: *anyopaque,

    // Returns the raw data, which you can use in any ways. Internally it is stored
    // as an *anyopaque
    pub fn getData(res: Resource, comptime T: type) *T {
        return @ptrCast(*T, @alignCast(std.meta.alignment(*T), res.resource));
    }
};
