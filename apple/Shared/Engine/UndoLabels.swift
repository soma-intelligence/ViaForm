import Foundation

/// The names of an engine's undo and redo steps ("Extrude", "Move Footprint"), for the Edit
/// menu's "Undo Extrude" (UI-UX-AUDIT P0-1). The engines report only how deep their stacks are,
/// so the wrapper notes each command it runs and matches them to the depths the engine reports
/// (`labels(undo:redo:)`): a step the wrapper did not see (a direct C call) has no name and the
/// menu reads plain "Undo". The engine's own reply to an undo or redo ("undone": "Extrude")
/// names the step that moved, so a guess that drifted is put right at the next undo.
///
/// Thread safe: engines run commands on workers too; the menu reads from the main thread.
final class UndoLabels: @unchecked Sendable {
    private let lock = NSLock()
    private var undo: [String?] = []
    private var redo: [String?] = []
    /// Commands run since the stacks were last matched to the engine's depths.
    private var pending: [String] = []
    /// The stacks when a checkpoint was taken, by checkpoint id (the tool previews).
    private var checkpoints: [Int: ([String?], [String?])] = [:]
    /// The engine keeps this many undo steps at most.
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    /// A command ran and may have changed the document (queries are not noted); "" for one
    /// with no name.
    func ran(_ label: String) {
        lock.lock(); defer { lock.unlock() }
        pending.append(label)
        if pending.count > 16 { pending.removeFirst(pending.count - 16) }
    }

    /// The engine undid a step; `name` is the step's own name from its reply.
    func undid(_ name: String?) {
        lock.lock(); defer { lock.unlock() }
        pending = []
        let top = undo.popLast() ?? nil
        redo.append(name ?? top)
    }

    func redid(_ name: String?) {
        lock.lock(); defer { lock.unlock() }
        pending = []
        let top = redo.popLast() ?? nil
        undo.append(name ?? top)
    }

    func checkpoint(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        checkpoints[id] = (undo, redo)
    }

    /// The document went back to checkpoint `id` (its history too), or the checkpoint was dropped.
    func restored(_ id: Int, forget: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !forget, let s = checkpoints[id] { (undo, redo) = s; pending = [] }
        checkpoints = checkpoints.filter { $0.key < id }
    }

    /// Another document came in: no step has a name.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        undo = []; redo = []; pending = []; checkpoints = [:]
    }

    /// The names of the top undo and redo steps for the depths the engine reports now.
    func labels(undo u: Int, redo r: Int) -> (undo: String?, redo: String?) {
        lock.lock(); defer { lock.unlock() }
        if u > undo.count {
            // New steps: the last commands run name them, the oldest unseen ones stay unnamed.
            let k = u - undo.count
            let named: [String?] = pending.suffix(k).map { $0.isEmpty ? nil : $0 }
            undo += Array(repeating: nil, count: k - named.count) + named
            pending = []
        } else if u < undo.count {
            undo = Array(undo.prefix(u))
        } else if u == limit, !pending.isEmpty, r == 0 {
            // At the engine's limit a new step drops the oldest: the depth stays the same.
            undo.removeFirst()
            undo.append(pending.last.flatMap { $0.isEmpty ? nil : $0 })
            pending = []
        }
        if r < redo.count {
            redo = r == 0 ? [] : Array(redo.suffix(r))
        } else if r > redo.count {
            redo = Array(repeating: nil, count: r - redo.count) + redo
        }
        return ((undo.last ?? nil), (redo.last ?? nil))
    }
}
