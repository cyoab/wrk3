const std = @import("std");
const ScriptApi = @import("ScriptApi.zig");

pub const ScriptLoader = struct {
    // Function pointer types (C calling convention)
    pub const SetupFn = *const fn (*ScriptApi.ThreadContext) callconv(.c) void;
    pub const RequestFn = *const fn (*ScriptApi.Request) callconv(.c) void;
    pub const ResponseFn = *const fn (*const ScriptApi.Response) callconv(.c) void;
    pub const DoneFn = *const fn (*const ScriptApi.Summary) callconv(.c) void;

    lib: std.DynLib,
    so_path: []const u8,
    allocator: std.mem.Allocator,

    // Resolved function pointers (null if not exported by script)
    setup_fn: ?SetupFn,
    request_fn: ?RequestFn,
    response_fn: ?ResponseFn,
    done_fn: ?DoneFn,

    pub const Error = error{
        CompilationFailed,
        TempDirFailed,
        OutOfMemory,
        SpawnFailed,
        LoadFailed,
    };

    /// Compile a .zig script to a shared library using `zig build-lib`.
    /// Returns the path to the compiled .so file.
    pub fn compile(allocator: std.mem.Allocator, script_path: []const u8) Error![]const u8 {
        // Create temp directory for output with a unique name.
        const tmp_dir = std.fs.openDirAbsolute("/tmp", .{}) catch return error.TempDirFailed;
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        var rng_seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&rng_seed)) catch {
            rng_seed = @as(u64, @intCast(std.time.timestamp()));
        };
        const sub_path = std.fmt.bufPrint(&tmp_buf, "wrk3-script-{d}-{d}", .{
            @as(u64, @intCast(std.time.timestamp())),
            rng_seed,
        }) catch return error.OutOfMemory;
        tmp_dir.makeDir(sub_path) catch return error.TempDirFailed;

        // Build the output path.
        const so_path = std.fmt.allocPrint(allocator, "/tmp/{s}/libscript.so", .{sub_path}) catch
            return error.OutOfMemory;
        errdefer allocator.free(so_path);

        // Write embedded ScriptApi.zig to temp dir so the script can import it.
        const api_path = std.fmt.allocPrint(allocator, "/tmp/{s}/ScriptApi.zig", .{sub_path}) catch
            return error.OutOfMemory;
        defer allocator.free(api_path);

        const api_file = std.fs.createFileAbsolute(api_path, .{}) catch return error.TempDirFailed;
        defer api_file.close();
        api_file.writeAll(embedded_script_api) catch return error.TempDirFailed;

        // Build the module spec arguments for zig build-lib.
        // -Mwrk3_script=<api_path> --dep wrk3_script -Mroot=<script_path>
        const wrk3_mod_spec = std.fmt.allocPrint(allocator, "-Mwrk3_script={s}", .{api_path}) catch
            return error.OutOfMemory;
        defer allocator.free(wrk3_mod_spec);

        const root_mod_spec = std.fmt.allocPrint(allocator, "-Mroot={s}", .{script_path}) catch
            return error.OutOfMemory;
        defer allocator.free(root_mod_spec);

        const emit_spec = std.fmt.allocPrint(allocator, "-femit-bin={s}", .{so_path}) catch
            return error.OutOfMemory;
        defer allocator.free(emit_spec);

        const argv = [_][]const u8{
            "zig",
            "build-lib",
            "-dynamic",
            "-OReleaseFast",
            emit_spec,
            "--dep",
            "wrk3_script",
            root_mod_spec,
            wrk3_mod_spec,
        };

        var child = std.process.Child.init(&argv, allocator);
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;

        child.spawn() catch return error.SpawnFailed;

        // Read stderr for error messages.
        var stderr_buf: std.ArrayList(u8) = .empty;
        defer stderr_buf.deinit(allocator);
        var stdout_buf: std.ArrayList(u8) = .empty;
        defer stdout_buf.deinit(allocator);
        child.collectOutput(allocator, &stdout_buf, &stderr_buf, 1024 * 1024) catch return error.CompilationFailed;

        const term = child.wait() catch return error.CompilationFailed;

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    // Print compiler errors to stderr.
                    var err_buf: [8192]u8 = undefined;
                    var stderr_writer = std.fs.File.stderr().writer(&err_buf);
                    const stderr_iface = &stderr_writer.interface;
                    stderr_iface.print("Script compilation failed:\n{s}\n", .{stderr_buf.items}) catch {};
                    stderr_iface.flush() catch {};
                    return error.CompilationFailed;
                }
            },
            else => return error.CompilationFailed,
        }

        return so_path;
    }

    /// Load a compiled shared library and resolve hook function pointers.
    pub fn load(allocator: std.mem.Allocator, so_path: []const u8) Error!ScriptLoader {
        var lib = std.DynLib.open(so_path) catch return error.LoadFailed;

        return ScriptLoader{
            .lib = lib,
            .so_path = so_path,
            .allocator = allocator,
            .setup_fn = lib.lookup(SetupFn, "setup"),
            .request_fn = lib.lookup(RequestFn, "request"),
            .response_fn = lib.lookup(ResponseFn, "response"),
            .done_fn = lib.lookup(DoneFn, "done"),
        };
    }

    /// Close the dynamic library.
    pub fn deinit(self: *ScriptLoader) void {
        self.lib.close();
    }

    /// Remove the temporary .so file and its directory.
    pub fn cleanup(self: *ScriptLoader) void {
        // Delete the .so file.
        std.fs.deleteFileAbsolute(self.so_path) catch {};

        // Try to remove the parent temp directory.
        if (std.mem.lastIndexOfScalar(u8, self.so_path, '/')) |last_slash| {
            const dir_path = self.so_path[0..last_slash];
            std.fs.deleteDirAbsolute(dir_path) catch {};
        }

        self.allocator.free(self.so_path);
    }

    /// Embedded ScriptApi.zig source for compilation.
    const embedded_script_api = @embedFile("ScriptApi.zig");
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "ScriptLoader compile and load simple script" {
    const allocator = testing.allocator;

    // Write a minimal test script.
    const script_content =
        \\const wrk3 = @import("wrk3_script");
        \\
        \\export fn request(req: *wrk3.Request) callconv(.c) void {
        \\    req.method = .POST;
        \\    req.path.set("/test");
        \\}
    ;

    const script_path = "/tmp/wrk3_test_script.zig";
    const file = try std.fs.createFileAbsolute(script_path, .{});
    try file.writeAll(script_content);
    file.close();
    defer std.fs.deleteFileAbsolute(script_path) catch {};

    // Compile.
    const so_path = ScriptLoader.compile(allocator, script_path) catch |err| {
        std.debug.print("Compilation failed: {}\n", .{err});
        return err;
    };

    // Load.
    var loader = try ScriptLoader.load(allocator, so_path);
    defer loader.deinit();
    defer loader.cleanup();

    // Verify function resolution.
    try testing.expect(loader.request_fn != null);
    try testing.expect(loader.setup_fn == null);
    try testing.expect(loader.response_fn == null);
    try testing.expect(loader.done_fn == null);

    // Call the request function.
    var path_buf: [2048]u8 = undefined;
    var headers_buf: [4096]u8 = undefined;
    var body_buf: [8192]u8 = undefined;
    var req = ScriptApi.Request{
        .method = .GET,
        .path = .{ .ptr = &path_buf, .len = 1, .cap = path_buf.len },
        .headers = .{ .ptr = &headers_buf, .len = 0, .cap = headers_buf.len },
        .body = .{ .ptr = &body_buf, .len = 0, .cap = body_buf.len },
    };
    path_buf[0] = '/';

    loader.request_fn.?(&req);
    try testing.expectEqual(ScriptApi.Method.POST, req.method);
    try testing.expectEqualStrings("/test", req.path.slice());
}

test "ScriptLoader missing hooks are null" {
    const allocator = testing.allocator;

    // Script with no exported hook functions (but valid Zig).
    const script_content =
        \\export fn noop() callconv(.c) void {}
    ;

    const script_path = "/tmp/wrk3_test_empty_script.zig";
    const file = try std.fs.createFileAbsolute(script_path, .{});
    try file.writeAll(script_content);
    file.close();
    defer std.fs.deleteFileAbsolute(script_path) catch {};

    const so_path = ScriptLoader.compile(allocator, script_path) catch |err| {
        std.debug.print("Compilation failed: {}\n", .{err});
        return err;
    };

    var loader = try ScriptLoader.load(allocator, so_path);
    defer loader.deinit();
    defer loader.cleanup();

    try testing.expect(loader.setup_fn == null);
    try testing.expect(loader.request_fn == null);
    try testing.expect(loader.response_fn == null);
    try testing.expect(loader.done_fn == null);
}
