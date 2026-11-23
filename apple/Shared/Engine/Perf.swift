import Foundation
import QuartzCore
import os

/// Timings for the "feel instant" work. Every measured span is an `os_signpost` interval
/// (Instruments, Points of Interest), always on and nearly free. With `--perf` the app also
/// prints each span and keeps the samples; `--perf-script` (implies `--perf`) waits for the
/// viewport to show a stable scene, then orbits it, hovers and picks, cycles the workspaces,
/// prints a summary and quits.
///
/// Launch the Mac app with, for example:
/// `ViaForm --perf-script --hand` or `ViaForm --perf-script --sample hand --generate-assembly`.
enum Perf {
    static let script = ProcessInfo.processInfo.arguments.contains("--perf-script")
    static let enabled = script || ProcessInfo.processInfo.arguments.contains("--perf")
    static let signposter = OSSignposter(subsystem: "me.somalabs.viaform", category: .pointsOfInterest)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var samples: [String: [Double]] = [:]
    nonisolated(unsafe) private static var milestones: Set<String> = []
    /// Spans shorter than this are kept but not printed one by one.
    static let printThreshold = 4.0

    static func now() -> Double { CACurrentMediaTime() }

    /// Runs `body` inside a signpost interval; with `--perf`, records its time in milliseconds.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let t0 = enabled ? now() : 0
        defer {
            signposter.endInterval(name, state)
            if enabled { record("\(name)", ms: (now() - t0) * 1000) }
        }
        return try body()
    }

    static func record(_ name: String, ms: Double, quiet: Bool = false) {
        guard enabled else { return }
        lock.lock()
        samples[name, default: []].append(ms)
        lock.unlock()
        if !quiet, ms >= printThreshold { print(String(format: "[perf] %@ %.2f ms", name, ms)) }
    }

    static func count(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return samples[name]?.count ?? 0
    }

    static func clear(_ prefix: String) {
        lock.lock()
        for k in samples.keys where k.hasPrefix(prefix) { samples[k] = nil }
        lock.unlock()
    }

    /// Milliseconds since the process started (the kernel's start time, so dyld and static
    /// initialisers count).
    static func sinceLaunch() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return (Date().timeIntervalSince1970 - started) * 1000
    }

    /// Prints (once) how long after launch `name` happened.
    static func milestone(_ name: String) {
        signposter.emitEvent("milestone")
        guard enabled else { return }
        lock.lock()
        let first = milestones.insert(name).inserted
        lock.unlock()
        guard first else { return }
        let ms = sinceLaunch()
        record("launch." + name, ms: ms, quiet: true)
        print(String(format: "[perf] milestone %@ at %.0f ms after launch", name, ms))
    }

    struct Stats {
        var n: Int
        var mean: Double
        var p50: Double
        var p95: Double
        var max: Double
        var line: String { String(format: "n %4d  mean %8.2f  p50 %8.2f  p95 %8.2f  max %8.2f ms", n, mean, p50, p95, max) }
    }

    static func stats(_ name: String) -> Stats? {
        lock.lock()
        let v = samples[name] ?? []
        lock.unlock()
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        func q(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
        return Stats(n: s.count, mean: s.reduce(0, +) / Double(s.count), p50: q(0.5), p95: q(0.95), max: s.last!)
    }

    static func report(_ title: String = "summary") {
        guard enabled else { return }
        lock.lock()
        let keys = samples.keys.sorted()
        lock.unlock()
        print("[perf] ==== \(title) ====")
        for k in keys { if let s = stats(k) { print("[perf] \(k.padding(toLength: 34, withPad: " ", startingAt: 0)) \(s.line)") } }
    }

    // MARK: Frames

    /// Which phase frame samples belong to (`idle`, `orbit`...), set by the script.
    nonisolated(unsafe) static var phase = "app" { didSet { lastDraw = 0 } }
    nonisolated(unsafe) private static var lastDraw = 0.0

    /// One `draw(in:)`: the time since the last one, and its CPU encode time.
    static func frame(start: Double, end: Double) {
        guard enabled else { return }
        let p = phase
        if lastDraw > 0 { record(p + ".frame.interval", ms: (start - lastDraw) * 1000, quiet: true) }
        lastDraw = start
        record(p + ".frame.cpu", ms: (end - start) * 1000, quiet: true)
    }

    static func gpu(_ ms: Double, phase p: String) { record(p + ".frame.gpu", ms: ms, quiet: true) }

    // MARK: Main thread stalls

    nonisolated(unsafe) private static var iterationStart = 0.0
    nonisolated(unsafe) private static var stallObserver: CFRunLoopObserver?

    /// Logs every main run loop iteration longer than 50 ms (`main.stall`).
    static func watchMainThread() {
        guard enabled, stallObserver == nil else { return }
        // Lines reach a pipe or a file at once, even when the app is killed.
        setvbuf(stdout, nil, _IOLBF, 0)
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, activity in
            if activity == .afterWaiting {
                iterationStart = now()
            } else if iterationStart > 0 {
                let ms = (now() - iterationStart) * 1000
                if ms > 50 { record("main.stall", ms: ms) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        stallObserver = o
    }

    /// Calls `done` with the milliseconds from now until the main run loop is next about to
    /// sleep, after SwiftUI's update and Core Animation's commit (both run before it).
    static func untilIdle(_ done: @escaping (Double) -> Void) {
        let t0 = now()
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            done((now() - t0) * 1000)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
    }
}

/// The `--perf-script` run. The viewport registers itself; the Mac window hands over a way to
/// switch workspaces.
@MainActor
enum PerfScript {
    nonisolated(unsafe) static weak var viewport: ViewportCoordinator?
    /// Switches the window's workspace (set by the Mac project window).
    static var openWorkspace: ((Workspace) -> Void)?
    nonisolated(unsafe) private static var started = false

    /// Called on the main thread by each viewport as it attaches.
    nonisolated static func viewportAttached(_ c: ViewportCoordinator) {
        guard Perf.script, !started else { return }
        // The first viewport is the design's; others (generative previews) are left alone.
        if viewport == nil { viewport = c }
        started = true
        Task { @MainActor in await run() }
    }

    private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private static func run() async {
        // Wait for a scene with bodies that has not changed for 1.5 s (60 s at most).
        var lastCount = -1, stableSince = Perf.now()
        let deadline = Perf.now() + 90
        while Perf.now() < deadline {
            await sleep(0.25)
            let n = Perf.count("scene.upload")
            let meshes = viewport?.model.scene.meshes.count ?? 0
            if n != lastCount { lastCount = n; stableSince = Perf.now() }
            if meshes > 0, Perf.now() - stableSince > 1.5 { break }
        }
        guard let c = viewport else { print("[perf] no viewport"); exit(1) }
        let m = c.model
        Perf.milestone("scene stable")
        let tris = m.scene.meshes.reduce(0) { $0 + $1.indices.count / 3 }
        let verts = m.scene.meshes.reduce(0) { $0 + $1.positions.count }
        let edges = m.scene.meshes.reduce(0) { $0 + $1.edges.count }
        print("[perf] scene: \(m.scene.meshes.count) meshes, \(tris) triangles, \(verts) vertices, \(edges) edges, view \(Int(m.viewSize.width))x\(Int(m.viewSize.height))")
        // What every command's refresh pays to describe the design, with and without the
        // per-body measures.
        for measure in [true, false] {
            for _ in 0..<3 {
                let t0 = Perf.now()
                _ = try? m.engine.execute("document.inspect", ["measure": measure])
                Perf.record(measure ? "inspect.measured" : "inspect.plain", ms: (Perf.now() - t0) * 1000, quiet: true)
            }
        }
        Perf.report("load")
        Perf.clear("")

        Perf.phase = "idle"
        await sleep(1.5)

        // Orbit as a mouse would: 120 events a second for 3 s.
        Perf.phase = "orbit"
        let end = Perf.now() + 3
        while Perf.now() < end {
            m.camera.orbit(dx: 3, dy: 0.4)
            c.moved()
            await sleep(1.0 / 120)
        }
        c.moved(final: true)
        Perf.phase = "after"
        await sleep(0.5)

        // Hover and pick over a grid of points across the view.
        let size = m.viewSize
        var points: [CGPoint] = []
        for i in 0..<20 { for j in 0..<15 { points.append(CGPoint(x: size.width * (Double(i) + 0.5) / 20, y: size.height * (Double(j) + 0.5) / 15)) } }
        for p in points {
            let t0 = Perf.now()
            m.hover(at: p)
            Perf.record("hover", ms: (Perf.now() - t0) * 1000, quiet: true)
        }
        m.hover = nil
        // Selection: click the centre, then wait for the frame.
        for p in points.prefix(40) {
            let t0 = Perf.now()
            m.click(at: p, additive: false)
            Perf.record("select.click", ms: (Perf.now() - t0) * 1000, quiet: true)
            await withCheckedContinuation { k in Perf.untilIdle { ms in Perf.record("select.toIdle", ms: ms, quiet: true); k.resume() } }
        }
        m.selection = []
        await sleep(0.3)

        // Workspaces: each one, then back to Design.
        if let open = openWorkspace {
            for w in Workspace.allCases.dropFirst() + [.design] {
                let t0 = Perf.now()
                open(w)
                await withCheckedContinuation { k in Perf.untilIdle { ms in Perf.record("workspace." + w.rawValue, ms: ms, quiet: true); k.resume() } }
                _ = t0
                await sleep(0.6)
            }
            // A second round: the views now exist once.
            for w in Workspace.allCases.dropFirst() + [.design] {
                open(w)
                await withCheckedContinuation { k in Perf.untilIdle { ms in Perf.record("workspace2." + w.rawValue, ms: ms, quiet: true); k.resume() } }
                await sleep(0.4)
            }
        }
        Perf.report("interaction")
        fflush(stdout)
        exit(0)
    }
}
