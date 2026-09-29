// MicrOS (µOS) Fiber Context Switch & Immix GC Microbenchmark
// Implements SPEC-TECH-LANG-002 benchmark harness: measures fiber context
// switch latency and Immix mark-region GC allocation and sweep throughput.

const std = @import("std");
const macros = @import("macros");
const fiber = macros.fiber;
const gc = macros.gc;

pub inline fn rdtsc() u64 {
    var rax_val: u64 = undefined;
    var rdx_val: u64 = undefined;
    asm volatile (
        \\rdtsc
        : [rax_val] "={rax}" (rax_val),
          [rdx_val] "={rdx}" (rdx_val),
    );
    return (rdx_val << 32) | rax_val;
}

fn getMonotonicNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

var bench_switch_count: usize = 0;
const BENCH_FIBER_ITERATIONS: usize = 100_000;

fn fiberBenchWorker(ctx: ?*anyopaque) void {
    _ = ctx;
    while (bench_switch_count < BENCH_FIBER_ITERATIONS) {
        bench_switch_count += 1;
        fiber.yield();
    }
}

const SAMPLE_COUNT: usize = 10_000;
var sample_latencies: [SAMPLE_COUNT]u64 = [_]u64{0} ** SAMPLE_COUNT;
var sample_idx: usize = 0;

fn fiberTailWorker(ctx: ?*anyopaque) void {
    _ = ctx;
    while (sample_idx < SAMPLE_COUNT) {
        const t0 = rdtsc();
        fiber.yield();
        const t1 = rdtsc();
        if (sample_idx < SAMPLE_COUNT) {
            sample_latencies[sample_idx] = t1 - t0;
            sample_idx += 1;
        }
    }
}

fn runFiberBenchmark(allocator: std.mem.Allocator) !struct {
    switches: usize,
    elapsed_ns: u64,
    elapsed_cycles: u64,
    p99_us: f64,
} {
    var sched = fiber.Scheduler.init(allocator);
    defer sched.deinit();

    bench_switch_count = 0;
    _ = try sched.spawn(fiberBenchWorker, null);
    _ = try sched.spawn(fiberBenchWorker, null);

    const start_cycles = rdtsc();
    const start_time = getMonotonicNs();

    sched.run();

    const end_time = getMonotonicNs();
    const end_cycles = rdtsc();

    const elapsed_ns: u64 = @intCast(@max(0, end_time - start_time));
    const elapsed_cycles = end_cycles - start_cycles;

    // Tail latency sampling phase
    var tail_sched = fiber.Scheduler.init(allocator);
    defer tail_sched.deinit();

    sample_idx = 0;
    _ = try tail_sched.spawn(fiberTailWorker, null);
    _ = try tail_sched.spawn(fiberTailWorker, null);

    tail_sched.run();

    std.mem.sort(u64, &sample_latencies, {}, std.sort.asc(u64));
    const p99_cycles = sample_latencies[9900];
    const ns_per_cycle = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(elapsed_cycles));
    const p99_us = (@as(f64, @floatFromInt(p99_cycles)) * ns_per_cycle) / 1000.0;

    return .{
        .switches = bench_switch_count,
        .elapsed_ns = elapsed_ns,
        .elapsed_cycles = elapsed_cycles,
        .p99_us = p99_us,
    };
}

const GC_ALLOC_COUNT: usize = 10_000;
const GC_OBJECT_SIZE: usize = 256;

fn runGcBenchmark(allocator: std.mem.Allocator) !struct {
    alloc_ns: u64,
    sweep_ns: u64,
    bytes_swept: usize,
} {
    var heap = gc.Heap.init(allocator);
    defer heap.deinit();

    var ptrs = try allocator.alloc([]u8, GC_ALLOC_COUNT);
    defer allocator.free(ptrs);

    // Measure allocation phase
    const alloc_start = getMonotonicNs();
    for (0..GC_ALLOC_COUNT) |i| {
        ptrs[i] = try heap.alloc(GC_OBJECT_SIZE);
    }
    const alloc_end = getMonotonicNs();
    const alloc_ns: u64 = @intCast(@max(0, alloc_end - alloc_start));

    // Mark 50% of the allocated objects to create realistic hole fragmentation
    for (0..GC_ALLOC_COUNT) |i| {
        if ((i & 1) == 0) {
            heap.markSlice(ptrs[i].ptr, ptrs[i].len);
        }
    }

    const total_bytes = GC_ALLOC_COUNT * GC_OBJECT_SIZE;

    // Measure sweep phase
    const sweep_start = getMonotonicNs();
    heap.sweep();
    const sweep_end = getMonotonicNs();
    const sweep_ns: u64 = @intCast(@max(0, sweep_end - sweep_start));

    return .{
        .alloc_ns = alloc_ns,
        .sweep_ns = sweep_ns,
        .bytes_swept = total_bytes,
    };
}

fn printHeader() void {
    std.debug.print("========================================================\n", .{});
    std.debug.print("     MicrOS Fiber & Immix GC Microbenchmark Suite       \n", .{});
    std.debug.print("========================================================\n", .{});
}

fn printFiberResults(res: anytype) void {
    const total_switches = res.switches;
    const ns_per_switch = @as(f64, @floatFromInt(res.elapsed_ns)) / @as(f64, @floatFromInt(total_switches));
    const cycles_per_switch = @as(f64, @floatFromInt(res.elapsed_cycles)) / @as(f64, @floatFromInt(total_switches));

    std.debug.print("[fiber] Iterations       : {d} context switches\n", .{total_switches});
    std.debug.print("[fiber] Total Time       : {d:.3} ms\n", .{@as(f64, @floatFromInt(res.elapsed_ns)) / 1_000_000.0});
    std.debug.print("[fiber] Latency/Switch   : {d:.1} ns ({d:.1} CPU cycles)\n", .{ ns_per_switch, cycles_per_switch });
    std.debug.print("[fiber] Tail Latency p99 : {d:.2} us (bound: <= 50.0 us)\n", .{res.p99_us});
    std.debug.print("--------------------------------------------------------\n", .{});
}

fn printGcResults(res: anytype) void {
    const alloc_ms = @as(f64, @floatFromInt(res.alloc_ns)) / 1_000_000.0;
    const sweep_ms = @as(f64, @floatFromInt(res.sweep_ns)) / 1_000_000.0;
    const total_mb = @as(f64, @floatFromInt(res.bytes_swept)) / (1024.0 * 1024.0);
    const alloc_rate = total_mb / (alloc_ms / 1000.0);
    const sweep_rate = total_mb / (sweep_ms / 1000.0);

    std.debug.print("[immix] Objects Allocated: {d} ({d} bytes each, {d:.2} MB total)\n", .{
        GC_ALLOC_COUNT, GC_OBJECT_SIZE, total_mb,
    });
    std.debug.print("[immix] Alloc Time       : {d:.3} ms ({d:.1} MB/s)\n", .{ alloc_ms, alloc_rate });
    std.debug.print("[immix] Sweep Time       : {d:.3} ms ({d:.1} MB/s)\n", .{ sweep_ms, sweep_rate });
    std.debug.print("========================================================\n", .{});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    printHeader();
    const fiber_res = try runFiberBenchmark(allocator);
    printFiberResults(fiber_res);

    const gc_res = try runGcBenchmark(allocator);
    printGcResults(gc_res);
}
