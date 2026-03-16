const std = @import("std");
const posix = std.posix;

const ConfigMod = @import("wrk3").Config;
const Config = ConfigMod.Config;
const Worker = @import("wrk3").Worker.Worker;
const StatsMod = @import("wrk3").Stats;
const Stats = StatsMod.Stats;
const Units = @import("wrk3").Units;
const Export = @import("wrk3").Export;
const ScriptLoader = @import("wrk3").ScriptLoader.ScriptLoader;
const ScriptApi = @import("wrk3").ScriptApi;

var stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var signal_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn handleSignal(_: c_int) callconv(.c) void {
    const prev = signal_count.fetchAdd(1, .monotonic);
    if (prev >= 1) {
        std.process.exit(1);
    }
    stop_requested.store(true, .release);
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments (skip argv[0] which is the program name).
    const all_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, all_args);

    if (all_args.len < 2) {
        ConfigMod.printUsage();
        std.process.exit(1);
    }

    const args = all_args[1..];
    const config = ConfigMod.parse(allocator, args) catch |err| {
        var err_buf: [4096]u8 = undefined;
        var err_writer = std.fs.File.stderr().writer(&err_buf);
        const stderr = &err_writer.interface;
        switch (err) {
            error.MissingUrl => stderr.writeAll("Error: URL is required\n") catch {},
            error.MissingRate => stderr.writeAll("Error: -R/--rate is required\n") catch {},
            error.InvalidArgument => stderr.writeAll("Error: Invalid argument\n") catch {},
            error.InvalidUrl => stderr.writeAll("Error: Invalid URL\n") catch {},
            error.OutOfMemory => stderr.writeAll("Error: Out of memory\n") catch {},
        }
        stderr.flush() catch {};
        ConfigMod.printUsage();
        std.process.exit(1);
    };
    defer allocator.free(config.headers);

    // Reconstruct URL string for display.
    var url_buf: [512]u8 = undefined;
    const scheme_str: []const u8 = if (config.url.scheme == .https) "https" else "http";
    const url_display = std.fmt.bufPrint(&url_buf, "{s}://{s}:{d}{s}", .{
        scheme_str,
        config.url.host,
        config.url.port,
        config.url.path,
    }) catch "???";

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // Install signal handlers for graceful shutdown.
    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);

    // Compile script if provided.
    var so_path: ?[]const u8 = null;
    if (config.script_path) |script| {
        stdout.print("Compiling script: {s}...\n", .{script}) catch {};
        stdout.flush() catch {};
        so_path = ScriptLoader.compile(allocator, script) catch |err| {
            var err_buf3: [4096]u8 = undefined;
            var err_writer3 = std.fs.File.stderr().writer(&err_buf3);
            const stderr3 = &err_writer3.interface;
            stderr3.print("Error: failed to compile script: {}\n", .{err}) catch {};
            stderr3.flush() catch {};
            std.process.exit(1);
        };
    }
    defer if (so_path) |path| {
        // Clean up temp .so file and its directory.
        std.fs.deleteFileAbsolute(path) catch {};
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |last_slash| {
            const dir_path = path[0..last_slash];
            std.fs.deleteDirAbsolute(dir_path) catch {};
        }
        allocator.free(path);
    };

    // Create workers.
    const workers = try allocator.alloc(Worker, config.threads);
    defer allocator.free(workers);

    for (workers, 0..) |*w, i| {
        w.* = try Worker.init(allocator, config, @intCast(i), &stop_requested, so_path);
    }

    // Start all worker threads.
    for (workers) |*w| {
        try w.start();
    }

    // Join all worker threads and collect results.
    const worker_stats = try allocator.alloc(StatsMod.WorkerStats, config.threads);
    defer allocator.free(worker_stats);

    for (workers, 0..) |*w, i| {
        worker_stats[i] = w.join();
    }

    // Aggregate results.
    var stats = try Stats.aggregate(allocator, worker_stats);
    defer stats.deinit(allocator);

    const interrupted = stop_requested.load(.acquire);

    if (interrupted) {
        stdout.writeAll("\n-- Interrupted (partial results) --\n\n") catch {};
    } else {
        // Override duration_ns with the configured value for display
        // only when the run completed normally.
        if (stats.duration_ns == 0) {
            stats.duration_ns = config.duration_ns;
        }
    }

    // Print results.
    stats.formatReport(stdout, url_display, config.threads, config.connections, config.print_latency) catch {};
    stdout.flush() catch {};

    // Call done() script hook using an existing worker's loaded script.
    // Avoids extra dlopen/dlclose and ensures done() sees accumulated script state.
    var done_fn: ?ScriptLoader.DoneFn = null;
    for (workers) |*w| {
        if (w.script_loader) |loader| {
            done_fn = loader.done_fn;
            break;
        }
    }
    if (done_fn) |df| {
        const summary = ScriptApi.Summary{
            .total_requests = stats.total_requests,
            .total_errors = stats.total_errors,
            .total_bytes_read = stats.total_bytes_read,
            .total_bytes_written = stats.total_bytes_written,
            .duration_ns = stats.duration_ns,
            .avg_latency_ns = stats.avg_latency_ns,
            .max_latency_ns = stats.max_latency_ns,
            .p50_ns = stats.latency_histogram.valueAtPercentile(50.0),
            .p90_ns = stats.latency_histogram.valueAtPercentile(90.0),
            .p99_ns = stats.latency_histogram.valueAtPercentile(99.0),
            .p99_9_ns = stats.latency_histogram.valueAtPercentile(99.9),
            .p99_99_ns = stats.latency_histogram.valueAtPercentile(99.99),
        };
        df(&summary);
    }

    // Export histogram if requested.
    if (config.export_config) |export_cfg| {
        Export.exportHistogram(&stats.latency_histogram, export_cfg) catch |err| {
            var err_buf2: [4096]u8 = undefined;
            var err_writer2 = std.fs.File.stderr().writer(&err_buf2);
            const stderr2 = &err_writer2.interface;
            stderr2.print("Error: failed to export histogram to {s}: {}\n", .{ export_cfg.path, err }) catch {};
            stderr2.flush() catch {};
        };
    }

    // Clean up workers.
    for (workers) |*w| {
        w.deinit();
    }
}
