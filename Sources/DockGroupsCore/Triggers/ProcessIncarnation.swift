import Darwin

/// One fork incarnation of a process: its PID and the kernel's start time for it
/// (`proc_pidinfo(PROC_PIDTBSDINFO)`, `pbi_start_tvsec`/`pbi_start_tvusec`), as the running-code
/// verifier brackets a check with it (docs/design/app-presence-watch-upgrade.md §4.3).
///
/// - A PID is reused only after its incarnation exited, and a later incarnation always starts
///   later, so two equal readings mean the same incarnation existed in between (argued, not
///   proven; the start time has microsecond resolution).
/// - `exec` keeps the start time: this names the incarnation, never the image. Exec is the process
///   watch's job (`ApplicationProcessWatching`).
/// - It is no process identity, no audit token and no authorization. A stale `NSWorkspace` entry
///   whose PID was reused before it was listed reads as the new process.
/// - A reading that fails (no such process, not permitted, a short or mismatched answer, a zero
///   start time) is `nil`, never a default value; callers treat `nil` as unavailable.
struct ProcessIncarnation: Hashable, Sendable {
    /// Reads the incarnation running under a PID now, or `nil`. Called on any thread.
    typealias Read = @Sendable (Int32) -> ProcessIncarnation?

    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    /// The kernel's answer for `pid`, or `nil` when there is none to trust.
    static func read(pid: Int32) -> ProcessIncarnation? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let returned = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard returned == size, info.pbi_pid == UInt32(pid) else { return nil }
        guard info.pbi_start_tvsec != 0 || info.pbi_start_tvusec != 0 else { return nil }
        return ProcessIncarnation(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
}
