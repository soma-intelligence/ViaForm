import Foundation
import os

/// How long a click keeps the main actor (FRONTEND-SPEC 7.2: click to response under 100 ms;
/// UI-UX-AUDIT P0-11). Two figures per action:
/// - `click`: the button's own handler, from the click to the busy state on screen;
/// - `stall`: the longest the main actor went without running, while the action's work ran
///   (a 4 ms heartbeat on the main queue; a blocked main actor shows as one long gap).
///
/// Debug builds log each action (`log stream --predicate 'category == "timing"'`); the
/// self-test reads `last` and checks both figures against the budget.
@MainActor
enum ActionTiming {
    struct Record: Sendable {
        var action: String
        var clickMs: Double
        var stallMs: Double
        var totalMs: Double
    }

    static let budgetMs = 100.0
    private(set) static var last: [String: Record] = [:]
    private static let log = Logger(subsystem: "me.somalabs.viaform", category: "timing")

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    /// Times an action: `start` runs on the main actor at once (its time is the click figure),
    /// then its returned work runs while a heartbeat watches the main actor.
    static func measure<T>(_ action: String, _ start: () -> Void = {}, _ work: () async -> T) async -> T {
        let t0 = now()
        start()
        let click = now() - t0
        let probe = StallProbe()
        let value = await work()
        let stall = probe.stop()
        record(Record(action: action, clickMs: click, stallMs: stall, totalMs: now() - t0))
        return value
    }

    /// Notes the main actor time of a click handler that starts work and returns (File, Save:
    /// the handler starts the save task and the busy state, then gives the main actor back).
    static func click(_ action: String, since t0: Double) {
        let ms = now() - t0
        var r = last[action] ?? Record(action: action, clickMs: 0, stallMs: 0, totalMs: 0)
        r.clickMs = max(r.clickMs, ms)
        last[action] = r
        #if DEBUG
        log.debug("\(action, privacy: .public): click \(ms, format: .fixed(precision: 1)) ms")
        #endif
    }

    private static func record(_ r: Record) {
        var r = r
        if let old = last[r.action] { r.clickMs = max(r.clickMs, old.clickMs) }
        last[r.action] = r
        #if DEBUG
        log.debug("\(r.action, privacy: .public): click \(r.clickMs, format: .fixed(precision: 1)) ms, longest main-actor stall \(r.stallMs, format: .fixed(precision: 1)) ms, done in \(r.totalMs, format: .fixed(precision: 1)) ms")
        #endif
    }

    static func reset() { last = [:] }
}

/// A heartbeat on the main queue every 4 ms; the longest gap between beats, less the period, is
/// the longest time the main actor was kept busy.
@MainActor
final class StallProbe {
    private let timer: DispatchSourceTimer
    private var lastBeat = ActionTiming.now()
    private var worst = 0.0
    private static let periodMs = 4.0

    init() {
        timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(Int(Self.periodMs)), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.beat() }
        }
        timer.resume()
    }

    private func beat() {
        let t = ActionTiming.now()
        worst = max(worst, t - lastBeat - Self.periodMs)
        lastBeat = t
    }

    /// Stops the heartbeat and answers the longest stall in milliseconds (the gap up to now
    /// counts too).
    func stop() -> Double {
        beat()
        timer.cancel()
        return max(worst, 0)
    }
}
