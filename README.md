# ⚡ wrk3

**A modern HTTP benchmarking tool written in Zig — inspired by [wrk2](https://github.com/giltene/wrk2).**

Constant-throughput load generation with accurate high-percentile latency measurement, zero external dependencies, and coordinated omission correction out of the box.

![Zig](https://img.shields.io/badge/Zig-0.15.2+-F7A41D?logo=zig&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Linux-blue?logo=linux&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green)
![Status](https://img.shields.io/badge/Status-Alpha-orange)

---

## 🚀 Features

- **Constant-throughput load generation** — requests are scheduled independently of response times
- **Coordinated omission correction** — measures what latencies *would have been*, not just what was observed
- **HdrHistogram** — pure-Zig implementation for lossless, full-range latency recording up to the 99.99th percentile
- **Multi-threaded** — distributes connections evenly across OS threads with epoll-based async I/O
- **HTTPS support** — built-in TLS via Zig's standard library
- **HTTP/1.1** — keep-alive, chunked transfer encoding, custom headers
- **Zig scripting** — write benchmark scripts in Zig with `setup()`, `request()`, `response()`, `done()` hooks — compiled to shared libraries at runtime
- **Zero dependencies** — pure Zig + stdlib, no C libraries, no vendored code
- **wrk2-compatible output** — drop-in replacement for existing tooling and scripts
- **Histogram export** — CSV and JSON export of latency data for post-processing and visualization

## 📦 Installation

### Build from source

Requires **Zig 0.15.2** or later.

```bash
git clone https://github.com/cyoab/wrk3.git
cd wrk3
zig build -Doptimize=ReleaseFast
```

The binary is at `zig-out/bin/wrk3`.

### Run tests

```bash
zig build test
```

## 🔧 Usage

```
wrk3 [options] <url>
```

### Required

| Flag | Description |
|------|-------------|
| `-R, --rate <N>` | Target requests per second (supports `100k`, `1M`) |
| `<url>` | Target HTTP or HTTPS URL |

### Optional

| Flag | Default | Description |
|------|---------|-------------|
| `-t, --threads <N>` | `2` | Number of worker threads |
| `-c, --connections <N>` | `10` | Total number of open connections |
| `-d, --duration <T>` | `10s` | Test duration (`500ms`, `30s`, `1m`, `5h`) |
| `-H, --header <H>` | — | Custom header, repeatable (`"Name: Value"`) |
| `-s, --script <F>` | — | Zig script file for custom hooks |
| `-L, --latency` | off | Print full latency percentile distribution |
| `--timeout <T>` | `2s` | Socket timeout |
| `--export <F:P>` | — | Export histogram (`csv:file.csv` or `json:file.json`) |

### Examples

```bash
# Basic: 100 req/s for 30 seconds
wrk3 -R 100 -d 30s http://localhost:8080

# Scale up: 4 threads, 200 connections, 10k req/s
wrk3 -t 4 -c 200 -R 10k -d 1m http://localhost:8080/api

# HTTPS with custom headers and latency distribution
wrk3 -R 500 -c 50 -L \
  -H "Authorization: Bearer mytoken" \
  -H "Accept: application/json" \
  https://api.example.com/endpoint

# Custom scripting: POST with JSON body
wrk3 -R 500 -c 20 -s examples/post_json.zig http://localhost:8080

# Dynamic paths via script
wrk3 -R 1000 -c 50 -s examples/dynamic_path.zig http://localhost:8080

# Export latency histogram to CSV or JSON
wrk3 -R 1000 -d 30s --export csv:latency.csv http://localhost:8080
wrk3 -R 1000 -d 30s --export json:latency.json http://localhost:8080
```

### Sample output

```
Running 30s test @ http://localhost:8080
  4 threads and 200 connections
  Thread calibration: mean lat.: 1.23ms, rate sampling interval: 10ms
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.25ms  348.00us   12.35ms   78.23%
    Req/Sec     2.50k   120.35     3.10k     68.50%
  Latency Distribution (HdrHistogram - Coverage: 99.99%)
    50.000%    1.12ms
    75.000%    1.35ms
    90.000%    1.78ms
    99.000%    3.45ms
    99.900%    8.12ms
    99.990%   12.35ms
  299847 requests in 30.00s, 45.12MB read
Requests/sec:   9994.90
Transfer/sec:      1.50MB
```

## 🏗️ Architecture

```
main.zig ─── CLI entry point
  ├── Config         Parse CLI args and URL
  ├── ScriptLoader   Compile .zig scripts → .so, resolve hooks
  ├── Worker[]       Spawn OS threads
  │    ├── EventLoop     epoll-based async I/O
  │    ├── Connection[]  HTTP state machines
  │    │    ├── Socket       TCP + TLS
  │    │    ├── HttpParser   HTTP/1.1 response parser
  │    │    ├── Scheduler    Constant-rate request pacer
  │    │    ├── Histogram    Per-connection latency recording
  │    │    └── ScriptApi    request()/response() hook dispatch
  │    └── Timer         Duration tracking
  ├── Export         CSV/JSON histogram export
  └── Stats          Aggregate & report results
```

| Module | Role |
|--------|------|
| `EventLoop` | Linux epoll with edge-triggered callbacks |
| `Socket` | Non-blocking TCP with optional TLS |
| `Connection` | HTTP request/response state machine |
| `Scheduler` | Deterministic send-time calculation, decoupled from responses |
| `HttpParser` | Streaming HTTP/1.1 parser (chunked, keep-alive, content-length) |
| `Histogram` | HdrHistogram — O(1) recording, coordinated omission backfill |
| `Worker` | Thread lifecycle, connection distribution, result collection |
| `Stats` | Histogram merging, percentile computation, formatted output |
| `Config` | Argument parsing, URL decomposition |
| `ScriptApi` | Extern struct types shared across `.so` boundary (Request, Response, Summary) |
| `ScriptLoader` | Compiles `.zig` scripts via `zig build-lib`, loads `.so` via `std.DynLib` |
| `Export` | CSV and JSON histogram export via `--export` flag |
| `Units` | Human-readable duration/count/byte formatting and parsing |

## 📝 Scripting

wrk3 supports custom benchmark scripts written in Zig. Scripts are compiled to shared libraries at runtime via `zig build-lib` and loaded dynamically — giving you full access to Zig's standard library with zero overhead when no script is provided.

### Hooks

| Hook | Signature | Called |
|------|-----------|--------|
| `setup` | `fn(*ThreadContext) void` | Once per thread, before connections start |
| `request` | `fn(*Request) void` | Before each HTTP request is sent |
| `response` | `fn(*const Response) void` | After each HTTP response is received |
| `done` | `fn(*const Summary) void` | Once after the benchmark completes |

All hooks are optional — export only the ones you need.

### Example: POST with JSON body

```zig
const std = @import("std");
const wrk3 = @import("wrk3_script");

var counter: u64 = 0;

export fn request(req: *wrk3.Request) callconv(.c) void {
    counter += 1;
    req.method = .POST;
    req.path.set("/api/users");
    req.headers.set("Content-Type: application/json\r\n");
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{counter}) catch return;
    req.body.set(body);
}
```

```bash
wrk3 -R 500 -c 20 -s script.zig http://localhost:8080
```

### How it works

1. wrk3 compiles your `.zig` file to a shared library using `zig build-lib -dynamic`
2. Each worker thread loads the `.so` and resolves hook function pointers
3. `request()` is called before each send — modify method, path, headers, body
4. `response()` is called after each response — inspect status, headers, body
5. `done()` is called once with a summary including latency percentiles

See `examples/` for more scripts.

## 🔬 Coordinated Omission

Traditional benchmarking tools measure latency from when a request is *sent* to when the response arrives. If the server stalls, pending requests simply wait in a queue — their latency appears low because measurement starts when they're *eventually dispatched*, not when they *should have been*.

wrk3 (like wrk2) solves this by **scheduling requests ahead of time** and measuring from the *scheduled* send time. If a request was supposed to go out at T=100ms but the connection was busy until T=500ms, the recorded latency includes that 400ms delay. This produces accurate high-percentile numbers that reflect real user experience.

## 🔄 wrk2 Compatibility & Differences

wrk3 aims to be a modern, dependency-free alternative to wrk2. Here's where things stand:

### ✅ Implemented (parity with wrk2)

- Constant-throughput request scheduling (`-R` flag)
- Coordinated omission correction via HdrHistogram
- Multi-threaded load generation (`-t`, `-c`)
- Configurable duration and timeout (`-d`, `--timeout`)
- Custom HTTP headers (`-H`)
- Latency percentile distribution (`-L`)
- HTTP/1.1 keep-alive and chunked encoding
- wrk2-compatible output format
- CSV/JSON histogram export (`--export`)
- Scripting with `setup()`, `request()`, `response()`, `done()` hooks (`-s`)

### 🚧 Missing (not yet implemented)

| Feature | wrk2 | wrk3 | Notes |
|---------|------|------|-------|
| **Uncorrected latency** (`--u_latency`) | ✅ | ❌ | wrk2 can show both corrected and uncorrected histograms side-by-side for comparison |
| **Thread calibration output** | ✅ | ❌ | wrk2 prints per-thread calibration stats (mean latency, sampling interval) |
| **HTTP pipelining** | ✅ | ❌ | Sending multiple requests without waiting for each response |
| **macOS / BSD support** | ✅ | ❌ | wrk3 currently requires Linux (epoll); kqueue support not implemented |
| **Histogram export** | Partial | ✅ | CSV/JSON export via `--export` flag |
| **Config file support** | ❌ | ❌ | Neither tool supports config files |

### 🎯 wrk3 advantages over wrk2

- **No C dependencies** — wrk2 requires LuaJIT, OpenSSL, and a C toolchain
- **Single static binary** — `zig build` produces one self-contained executable
- **Simpler build** — no Makefiles, no `pkg-config`, no linker flags
- **Memory safe** — Zig's safety checks catch bugs that C misses
- **Modern TLS** — uses Zig's built-in TLS, no OpenSSL version headaches
- **Zig scripting** — scripts have access to the full Zig standard library instead of Lua

## 🧪 Testing

The project includes **90+ unit tests** across all modules:

```bash
# Run all tests
zig build test

# Run with verbose output
zig build test -- --verbose
```

| Module | Tests | Coverage |
|--------|-------|----------|
| Config | 17 | Arg parsing, URL validation, export flags, edge cases |
| Scheduler | 8 | Rate distribution, staggering, reset |
| HttpParser | 11 | Chunked, keep-alive, malformed input |
| Units | 11 | Parsing, formatting, round-trips |
| EventLoop | 6 | fd registration, timers, stop |
| Socket | 6 | TCP, TLS, non-blocking I/O |
| Connection | 5 | State machine, request formatting |
| Stats | 5 | Aggregation, formatting, edge cases |
| Histogram | 10 | Percentiles, merge, reset, iterator |
| Export | 3 | CSV format, JSON format, empty histogram |
| ScriptApi | 3 | Buffer operations, set/slice, method names |
| ScriptLoader | 2 | Compile + load, missing hooks resolution |
| Worker | 3 | Init, distribution, integration |

## 📄 License

MIT

## 🙏 Acknowledgements

- [wrk2](https://github.com/giltene/wrk2) by Gil Tene — the original constant-throughput HTTP benchmarking tool
- [wrk](https://github.com/wg/wrk) by Will Glozer — the HTTP benchmarking tool that started it all
- [HdrHistogram](https://github.com/HdrHistogram/HdrHistogram) by Gil Tene — the data structure behind accurate latency recording
