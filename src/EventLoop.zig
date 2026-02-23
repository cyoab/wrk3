const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

/// Thin wrapper around Linux epoll + timerfd.
/// Callback-based: each registered fd has a context pointer and function pointer
/// that gets called when the fd is ready.
pub const EventLoop = struct {
    epoll_fd: posix.fd_t,
    running: bool,
    registrations: [max_fds]?Registration,
    timer_contexts: [max_fds]?TimerContext,

    const max_fds = 65536;

    pub const Callback = *const fn (context: *anyopaque, events: u32) void;

    pub const Registration = struct {
        callback: Callback,
        context: *anyopaque,
    };

    const TimerContext = struct {
        fd: posix.fd_t,
        user_callback: Callback,
        user_context: *anyopaque,
    };

    /// Create a new EventLoop backed by epoll.
    pub fn init() !*EventLoop {
        const epoll_fd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        const self = try std.heap.page_allocator.create(EventLoop);
        self.* = EventLoop{
            .epoll_fd = epoll_fd,
            .running = false,
            .registrations = [_]?Registration{null} ** max_fds,
            .timer_contexts = [_]?TimerContext{null} ** max_fds,
        };
        return self;
    }

    /// Close the epoll file descriptor and free memory.
    pub fn deinit(self: *EventLoop) void {
        posix.close(self.epoll_fd);
        std.heap.page_allocator.destroy(self);
    }

    /// Register a file descriptor with epoll for the given events.
    /// Uses edge-triggered mode (EPOLLET).
    pub fn addFd(self: *EventLoop, fd: posix.fd_t, events: u32, callback: Callback, context: *anyopaque) void {
        const idx = fdToIndex(fd);
        self.registrations[idx] = Registration{
            .callback = callback,
            .context = context,
        };

        var ev = linux.epoll_event{
            .events = events | linux.EPOLL.ET,
            .data = .{ .ptr = @intFromPtr(&self.registrations[idx]) },
        };
        posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev) catch unreachable;
    }

    /// Modify the events and/or callback for an already-registered fd.
    pub fn modifyFd(self: *EventLoop, fd: posix.fd_t, events: u32, callback: Callback, context: *anyopaque) void {
        const idx = fdToIndex(fd);
        self.registrations[idx] = Registration{
            .callback = callback,
            .context = context,
        };

        var ev = linux.epoll_event{
            .events = events | linux.EPOLL.ET,
            .data = .{ .ptr = @intFromPtr(&self.registrations[idx]) },
        };
        posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, fd, &ev) catch unreachable;
    }

    /// Remove a file descriptor from epoll.
    pub fn removeFd(self: *EventLoop, fd: posix.fd_t) void {
        const idx = fdToIndex(fd);
        posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null) catch unreachable;
        self.registrations[idx] = null;
    }

    /// Wait for events on the epoll fd, dispatch callbacks, and return the
    /// number of events that fired.
    pub fn poll(self: *EventLoop, timeout_ms: i32) usize {
        var events: [64]linux.epoll_event = undefined;
        const n = posix.epoll_wait(self.epoll_fd, &events, timeout_ms);

        for (events[0..n]) |ev| {
            const reg_ptr: *const ?Registration = @ptrFromInt(ev.data.ptr);
            if (reg_ptr.*) |reg| {
                reg.callback(reg.context, ev.events);
            }
        }

        return n;
    }

    /// Signal the event loop to stop after the current (or next) poll returns.
    pub fn stop(self: *EventLoop) void {
        self.running = false;
    }

    /// Run the event loop, polling indefinitely until stop() is called.
    pub fn run(self: *EventLoop) void {
        self.running = true;
        while (self.running) {
            _ = self.poll(100);
        }
    }

    /// Create a timerfd, arm it, and register it with epoll.
    /// Returns the timerfd file descriptor.
    /// If interval_ns == 0, the timer is one-shot.
    pub fn addTimer(self: *EventLoop, initial_ns: u64, interval_ns: u64, callback: Callback, context: *anyopaque) posix.fd_t {
        const timer_fd = posix.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }) catch unreachable;

        const timer_spec = linux.itimerspec{
            .it_value = nsToTimespec(initial_ns),
            .it_interval = nsToTimespec(interval_ns),
        };
        posix.timerfd_settime(timer_fd, .{}, &timer_spec, null) catch unreachable;

        const idx = fdToIndex(timer_fd);
        self.timer_contexts[idx] = TimerContext{
            .fd = timer_fd,
            .user_callback = callback,
            .user_context = context,
        };

        // Register with epoll using level-triggered mode (no EPOLLET) for timerfds.
        // The trampoline reads the timerfd to acknowledge it before calling the user callback.
        self.registrations[idx] = Registration{
            .callback = &timerTrampoline,
            .context = @ptrCast(&self.timer_contexts[idx]),
        };

        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(&self.registrations[idx]) },
        };
        posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, timer_fd, &ev) catch unreachable;

        return timer_fd;
    }

    /// Remove a timer: unregister from epoll and close the timerfd.
    pub fn removeTimer(self: *EventLoop, fd: posix.fd_t) void {
        self.removeFd(fd);
        const idx = fdToIndex(fd);
        self.timer_contexts[idx] = null;
        posix.close(fd);
    }

    /// Trampoline that reads the timerfd (to acknowledge it) then calls the
    /// user-supplied callback.
    fn timerTrampoline(context: *anyopaque, events: u32) void {
        const tc: *TimerContext = @ptrCast(@alignCast(context));
        // Read 8 bytes from the timerfd to acknowledge the expiration.
        var buf: [8]u8 = undefined;
        _ = posix.read(tc.fd, &buf) catch 0;
        tc.user_callback(tc.user_context, events);
    }

    fn nsToTimespec(ns: u64) linux.timespec {
        if (ns == 0) {
            return .{ .sec = 0, .nsec = 0 };
        }
        const sec: isize = @intCast(ns / 1_000_000_000);
        const nsec: isize = @intCast(ns % 1_000_000_000);
        return .{ .sec = sec, .nsec = nsec };
    }

    fn fdToIndex(fd: posix.fd_t) usize {
        return @intCast(fd);
    }
};

// ---------------------------------------------------------------------------
// Helper: create a Unix socketpair for testing
// ---------------------------------------------------------------------------
fn makeSocketPair() [2]posix.fd_t {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) {
        unreachable;
    }
    return fds;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Simple atomic counter that callbacks can increment.
const CallbackCounter = struct {
    count: u32 = 0,

    fn callback(ctx: *anyopaque, _: u32) void {
        const self: *CallbackCounter = @ptrCast(@alignCast(ctx));
        self.count += 1;
    }
};

test "socketpair read event" {
    const el = try EventLoop.init();
    defer el.deinit();

    const fds = makeSocketPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var counter = CallbackCounter{};
    el.addFd(fds[0], linux.EPOLL.IN, &CallbackCounter.callback, @ptrCast(&counter));

    // Write to write end
    _ = try posix.write(fds[1], "hello");

    // Poll — should fire the read callback
    const n = el.poll(100);
    try testing.expect(n >= 1);
    try testing.expectEqual(@as(u32, 1), counter.count);
}

test "timer fires" {
    const el = try EventLoop.init();
    defer el.deinit();

    var counter = CallbackCounter{};
    const tfd = el.addTimer(
        10_000_000, // 10ms initial
        0, // one-shot
        &CallbackCounter.callback,
        @ptrCast(&counter),
    );
    defer el.removeTimer(tfd);

    // Poll with 200ms timeout — timer should fire within 10ms
    _ = el.poll(200);

    try testing.expectEqual(@as(u32, 1), counter.count);
}

test "multiple fds" {
    const el = try EventLoop.init();
    defer el.deinit();

    const pair1 = makeSocketPair();
    defer posix.close(pair1[0]);
    defer posix.close(pair1[1]);

    const pair2 = makeSocketPair();
    defer posix.close(pair2[0]);
    defer posix.close(pair2[1]);

    const pair3 = makeSocketPair();
    defer posix.close(pair3[0]);
    defer posix.close(pair3[1]);

    var c1 = CallbackCounter{};
    var c2 = CallbackCounter{};
    var c3 = CallbackCounter{};

    el.addFd(pair1[0], linux.EPOLL.IN, &CallbackCounter.callback, @ptrCast(&c1));
    el.addFd(pair2[0], linux.EPOLL.IN, &CallbackCounter.callback, @ptrCast(&c2));
    el.addFd(pair3[0], linux.EPOLL.IN, &CallbackCounter.callback, @ptrCast(&c3));

    // Write to all write ends
    _ = try posix.write(pair1[1], "a");
    _ = try posix.write(pair2[1], "b");
    _ = try posix.write(pair3[1], "c");

    // Poll — all three should fire
    const n = el.poll(100);
    try testing.expect(n >= 3);
    try testing.expectEqual(@as(u32, 1), c1.count);
    try testing.expectEqual(@as(u32, 1), c2.count);
    try testing.expectEqual(@as(u32, 1), c3.count);
}

test "modify fd" {
    const el = try EventLoop.init();
    defer el.deinit();

    const fds = makeSocketPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var counter_read = CallbackCounter{};
    var counter_rw = CallbackCounter{};

    // Register for read only
    el.addFd(fds[0], linux.EPOLL.IN, &CallbackCounter.callback, @ptrCast(&counter_read));

    // Modify to read + write with a different context
    el.modifyFd(fds[0], linux.EPOLL.IN | linux.EPOLL.OUT, &CallbackCounter.callback, @ptrCast(&counter_rw));

    // The socket should be immediately writable, so poll should fire with the new context
    const n = el.poll(100);
    try testing.expect(n >= 1);
    try testing.expectEqual(@as(u32, 0), counter_read.count);
    try testing.expect(counter_rw.count >= 1);
}

test "remove fd" {
    const el = try EventLoop.init();
    defer el.deinit();

    const fds = makeSocketPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var counter = CallbackCounter{};
    el.addFd(fds[0], linux.EPOLL.IN, &CallbackCounter.callback, @ptrCast(&counter));

    // Remove the fd before writing
    el.removeFd(fds[0]);

    // Write data
    _ = try posix.write(fds[1], "hello");

    // Poll — callback should NOT fire
    const n = el.poll(50);
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqual(@as(u32, 0), counter.count);
}

test "stop exits run loop" {
    const el = try EventLoop.init();
    defer el.deinit();

    const StopHelper = struct {
        loop: *EventLoop,

        fn stopCallback(ctx: *anyopaque, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.loop.stop();
        }
    };

    var helper = StopHelper{ .loop = el };

    // Add a 10ms one-shot timer that calls stop()
    const tfd = el.addTimer(
        10_000_000, // 10ms
        0,
        &StopHelper.stopCallback,
        @ptrCast(&helper),
    );
    defer el.removeTimer(tfd);

    // run() should return once the timer fires and calls stop()
    el.run();

    try testing.expectEqual(false, el.running);
}
