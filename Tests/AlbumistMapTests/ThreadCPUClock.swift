#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Measures the CPU time of the calling thread instead of the wall clock, for the map's speed
/// tests. On a busy test Mac (3 cores, many simulators) the wall clock also counts the time the
/// test waited for a core: main CI 45722816550 had a 14.6 s stall in its log, and right after it
/// the pin grouping took 578 ms against a 500 ms bound and the photos-at-home check 316 ms
/// against 300 ms. Without load they take 80-90 ms and 113-128 ms (Linux debug build, 26.11.).
/// The work itself is what the bounds are about, so the bounds stay as they were: work that
/// grows faster than its input still fails them. All measured map code runs on one thread
/// (nothing in AlbumistMap starts a task or a queue), so the calling thread's time is all of it.
struct ThreadCPUClock {
    /// Same use as `ThreadCPUClock().measure`.
    func measure(_ work: () throws -> Void) rethrows -> Duration {
        let start = Self.now()
        try work()
        return Self.now() - start
    }

    private static func now() -> Duration {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
    }
}
