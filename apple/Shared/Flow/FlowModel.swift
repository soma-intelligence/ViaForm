import Foundation
import Observation

/// The product pipeline, kept by the Rust core (`viaform_core::flow`, through `vf_flow_*`):
/// what each workspace consumes and produces and whether it is current, the revisions of every
/// artifact ("Frame v12", "Board rev C"), the browser tree of each stage with its eyes and
/// locks, the selection and where it shows in the other stages, the jobs with their time left,
/// and the commands of all eight stages with their search.
///
/// The workspaces report what they build (`produce`, `startJob`...), the pipeline bar, the
/// browser and the inspector read it back. The state belongs to the open document: it travels
/// in the `.viaform` file as `flow.json` (`saveProject(_:)`, `openProject(_:)`, or the
/// `.viaformProjectSaved` and `.viaformProjectOpened` notifications), and a document with a path
/// keeps an autosave of its own, keyed by that path (`adoptDocument`, `openDocument`). A new
/// document, or a launch that loads a sample, starts on a fresh pipeline.
@MainActor
@Observable
final class FlowModel {
    // MARK: Shapes read from the core

    enum Status: String, Decodable {
        case current, empty, stale, running, failed
    }

    /// What a stale, failed or empty artifact offers: "Re-run on Frame v12", "Retry", "Build".
    struct Action: Decodable, Equatable {
        let label: String
        let op: String
        let plan: [String]
    }

    struct Stage: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let status: Status
        let artifacts: [String]
        let stale: Int
        var reason: String = ""
        var action: Action?

        enum CodingKeys: String, CodingKey { case id, name, status, artifacts, stale, reason, action }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            status = try c.decode(Status.self, forKey: .status)
            artifacts = try c.decode([String].self, forKey: .artifacts)
            stale = try c.decode(Int.self, forKey: .stale)
            reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
            action = try? c.decode(Action.self, forKey: .action)
        }
    }

    struct Input: Decodable, Equatable {
        let id: String
        let seen: Int
        let now: Int
        let current: Bool
        var seen_name: String?
        var now_name: String?
    }

    /// A job as the pipeline bar, the jobs list and the job capsule draw it.
    struct RunningJob: Decodable, Identifiable, Equatable {
        let id: Int
        let artifact: String
        let stage: String
        var verb: String = ""
        let label: String
        let progress: Double
        var determinate = false
        var done: Int?
        var total: Int?
        var eta: Double?
        var elapsed: Double = 0
        /// "Generating 74 of 120 · 3 min left".
        var caption: String = ""
        var state: String = "running"
        var pausable = false

        var paused: Bool { state == "paused" }

        enum CodingKeys: String, CodingKey { case id, artifact, stage, verb, label, progress, determinate, done, total, eta, elapsed, caption, state, pausable }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(Int.self, forKey: .id)) ?? 0
            artifact = try c.decode(String.self, forKey: .artifact)
            stage = try c.decode(String.self, forKey: .stage)
            verb = (try? c.decode(String.self, forKey: .verb)) ?? ""
            label = try c.decode(String.self, forKey: .label)
            progress = (try? c.decode(Double.self, forKey: .progress)) ?? 0
            determinate = (try? c.decode(Bool.self, forKey: .determinate)) ?? (progress > 0)
            done = try? c.decode(Int.self, forKey: .done)
            total = try? c.decode(Int.self, forKey: .total)
            eta = try? c.decode(Double.self, forKey: .eta)
            elapsed = (try? c.decode(Double.self, forKey: .elapsed)) ?? 0
            caption = (try? c.decode(String.self, forKey: .caption)) ?? label
            state = (try? c.decode(String.self, forKey: .state)) ?? "running"
            pausable = (try? c.decode(Bool.self, forKey: .pausable)) ?? false
        }
    }

    typealias Job = RunningJob

    struct Node: Decodable, Identifiable, Equatable {
        let id: String
        let stage: String
        let name: String
        var label: String = ""
        let revision: Int
        /// "Frame v12"; nil until built.
        var revisionName: String?
        var revisions: Int = 0
        let status: Status
        let summary: String
        var from: String?
        let error: String?
        var note: String?
        var reason: String = ""
        var action: Action?
        let job: RunningJob?
        let consumes: [Input]
        let feeds: [String]

        enum CodingKeys: String, CodingKey {
            case id, stage, name, label, revision, revision_name, revisions, status, summary, from, error, note, reason, action, job, consumes, feeds
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            stage = try c.decode(String.self, forKey: .stage)
            name = try c.decode(String.self, forKey: .name)
            label = (try? c.decode(String.self, forKey: .label)) ?? name
            revision = try c.decode(Int.self, forKey: .revision)
            revisionName = try? c.decode(String.self, forKey: .revision_name)
            revisions = (try? c.decode(Int.self, forKey: .revisions)) ?? revision
            status = try c.decode(Status.self, forKey: .status)
            summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
            from = try? c.decode(String.self, forKey: .from)
            error = try? c.decode(String.self, forKey: .error)
            note = try? c.decode(String.self, forKey: .note)
            reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
            action = try? c.decode(Action.self, forKey: .action)
            job = try? c.decode(RunningJob.self, forKey: .job)
            consumes = (try? c.decode([Input].self, forKey: .consumes)) ?? []
            feeds = (try? c.decode([String].self, forKey: .feeds)) ?? []
        }
    }

    /// Where the selection also shows: "Assemble, Frame:1".
    struct Presence: Decodable, Equatable, Identifiable {
        let stage: String
        let count: Int
        let ids: [String]
        let names: [String]
        var id: String { stage }
    }

    struct Selection: Decodable, Equatable {
        var stage = ""
        var ids: [String] = []
        var names: [String] = []
        var anchor: [Double]?
        var linked: [Presence] = []

        init() {}
        enum CodingKeys: String, CodingKey { case stage, ids, names, anchor, linked }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            stage = (try? c.decode(String.self, forKey: .stage)) ?? ""
            ids = (try? c.decode([String].self, forKey: .ids)) ?? []
            names = (try? c.decode([String].self, forKey: .names)) ?? ids
            anchor = try? c.decode([Double].self, forKey: .anchor)
            linked = (try? c.decode([Presence].self, forKey: .linked)) ?? []
        }

        var isEmpty: Bool { ids.isEmpty }
        /// "Frame", "Frame and 2 more".
        var title: String {
            guard let first = names.first else { return "Nothing selected" }
            return names.count == 1 ? first : "\(first) and \(names.count - 1) more"
        }
    }

    /// One browser row: an artifact of the stage, or something its workspace reported.
    struct TreeRow: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let kind: String
        var detail: String?
        let depth: Int
        var parent: String?
        var children: Int = 0
        let visible: Bool
        let locked: Bool
        /// Visible once the parents' eyes are counted.
        let shown: Bool
        /// Locked once the parents' locks are counted.
        let held: Bool
        let selected: Bool
        var status: Status?
        var links: [String] = []
    }

    /// What a workspace reports into its stage's tree.
    struct TreeItem: Encodable, Equatable {
        var id: String
        var name: String
        var kind: String
        var parent: String?
        var artifact: String?
        var links: [String] = []
        var detail: String?
    }

    /// A PIPELINE OUTPUTS row.
    struct Output: Decodable, Identifiable, Equatable {
        let id: String
        let stage: String
        let name: String
        let label: String
        let revision: Int
        var revision_name: String?
        let status: Status
        let reason: String
        var action: Action?
    }

    struct Revision: Decodable, Identifiable, Equatable {
        let number: Int
        let name: String
        let summary: String
        let source: String
        var from: String?
        let active: Bool
        var used_by: [String] = []
        var id: Int { number }
    }

    struct Diff: Decodable, Equatable {
        struct Change: Decodable, Equatable { let from: String; let to: String; let changed: Bool }
        struct InputChange: Decodable, Equatable { let id: String; let from: String; let to: String; let changed: Bool }
        let artifact: String
        let from: String
        let to: String
        let summary: Change
        let inputs: [InputChange]
        let same_content: Bool
    }

    /// One command of the eight stages: from SolidCraft (`design`), PCBCraft (`pcb`) or the
    /// pipeline's own verbs (`app`), routed by the front end.
    struct Command: Decodable, Identifiable, Equatable, Hashable {
        let id: String
        let label: String
        let stage: String
        let group: String
        let icon: String
        var key: String?
        let source: String
        var detail: String = ""
    }

    /// The jobs list as one value: the capsule shows its headline.
    struct JobQueue: Equatable {
        var jobs: [RunningJob] = []
        var isEmpty: Bool { jobs.isEmpty }
        var count: Int { jobs.count }
        /// The first job's caption, and how many more run.
        var headline: String? {
            guard let first = jobs.first else { return nil }
            return jobs.count == 1 ? first.caption : "\(first.caption) (+\(jobs.count - 1))"
        }
        func on(stage: String) -> RunningJob? { jobs.first { $0.stage == stage } }
        func on(artifact: String) -> RunningJob? { jobs.first { $0.artifact == artifact } }
    }

    /// What a job's engine does when the jobs list pauses, resumes or cancels it. A training or
    /// a generative study registers these where it starts (`startJob(... controls:)`), so the
    /// pipeline drives it without its module knowing about the pipeline.
    struct JobControls {
        var pause: (() -> Bool)?
        var resume: (() -> Bool)?
        var cancel: (() -> Void)?
        init(pause: (() -> Bool)? = nil, resume: (() -> Bool)? = nil, cancel: (() -> Void)? = nil) {
            self.pause = pause
            self.resume = resume
            self.cancel = cancel
        }
    }

    private struct State: Decodable {
        var product: String?
        let stages: [Stage]
        let nodes: [Node]
        let jobs: [RunningJob]
        var selection: Selection?
    }

    // MARK: State

    private let service: FlowService
    /// Where the per-document autosaves live; nil keeps nothing (samples, previews, checks).
    private let autosaveRoot: URL?
    /// The open document the pipeline belongs to (its file path); nil for an unsaved one.
    private(set) var documentKey: String?
    /// The document is a `.viaform` project, whose `flow.json` is the pipeline's home.
    private(set) var isProjectFile = false
    /// Empty until the document names its product.
    private(set) var product = ""
    /// The open design's joints and motors (motor or servo bodies), counted on every revision
    /// by the reporting (`FlowReporting`), so the summaries never show another design's.
    /// Moves when the pipeline starts over for another document (New, Open, a sample), so the
    /// reporting reports the workspaces again into the fresh pipeline.
    private(set) var documentEpoch = 0
    var designJoints = 0
    var designMotors = 0
    private(set) var stages: [Stage] = []
    private(set) var nodes: [Node] = []
    private(set) var jobs: [RunningJob] = []
    private(set) var selection = Selection()
    private(set) var error: String?
    /// Moves on every change, so views that read the tree, the outputs or the revisions
    /// refresh with it.
    private(set) var version = 0
    @ObservationIgnored private var controls: [Int: JobControls] = [:]
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Where the per-document autosaves are kept.
    static var defaultAutosaveRoot: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("ViaForm", isDirectory: true).appendingPathComponent("flow", isDirectory: true)
    }

    /// The app's pipeline: the worked example with `--flow-sample` (nothing saved), else a fresh
    /// one for the untitled document the app opens on. Nothing from an earlier launch or another
    /// window comes back until a document with a path is opened.
    convenience init() {
        if ProcessInfo.processInfo.arguments.contains("--flow-selftest") { FlowSelfTest.run() }
        if ProcessInfo.processInfo.arguments.contains("--flow-sample") {
            self.init(service: RustFlow(sample: true), autosave: nil)
        } else {
            self.init(service: RustFlow(), autosave: Self.defaultAutosaveRoot)
        }
    }

    init(service: FlowService, autosave root: URL?) {
        self.service = service
        self.autosaveRoot = root
        refresh()
        listenForProjectFiles()
    }

    /// The autosave of the document at `key`.
    func autosaveURL(for key: String) -> URL? {
        autosaveRoot?.appendingPathComponent(FlowFingerprint.of([key]) + ".json")
    }

    private var autosaveURL: URL? { documentKey.flatMap(autosaveURL(for:)) }

    /// The canned project, no engine needed (previews, model checks).
    static func preview() -> FlowModel { FlowModel(service: MockFlow(), autosave: nil) }

    /// The core's worked example, nothing saved.
    static func sample() -> FlowModel { FlowModel(service: RustFlow(sample: true), autosave: nil) }

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// The hand's graph: it has no generated frame, the drone's does. Its Simulation stage is a
    /// grasp test, not a flight.
    var isHandProduct: Bool { !nodes.isEmpty && node("generate.frame") == nil }
    func stage(_ id: String) -> Stage? { stages.first { $0.id == id } }
    func stage(_ w: Workspace) -> Stage? { stage(w.stage) }
    func nodes(in stage: String) -> [Node] { nodes.filter { $0.stage == stage } }
    var queue: JobQueue { JobQueue(jobs: jobs) }

    /// The revision a stage shows next to the project's name: its first built artifact's.
    func revisionName(of stage: String) -> String? { nodes(in: stage).compactMap(\.revisionName).first }

    // MARK: Builds

    /// Records that `artifact` was just built from the current revisions of its inputs. With a
    /// `fingerprint`, a build with the same content as the revision in use changes nothing and
    /// one with an older revision's content (an undo) puts that revision back; `amendWithin`
    /// folds a burst of edits into one revision.
    @discardableResult
    func produce(_ artifact: String, summary: String? = nil, fingerprint: String? = nil, amendWithin: Double? = nil, source: String? = nil, data: [String: Any]? = nil) -> String? {
        let r = send(["op": "produce", "artifact": artifact, "summary": summary, "fingerprint": fingerprint, "amend_within": amendWithin, "source": source, "data": data])
        return r?["result"] as? String
    }

    /// Reports the design: undo and redo land on the revision with the same content, and a
    /// burst of edits within two seconds is one revision.
    func reportDesign(_ s: DesignSnapshot) {
        guard !s.bodies.isEmpty else { return }
        produce("design.model", summary: "\(s.bodies.count) bodies, \(s.timeline.count) features", fingerprint: FlowFingerprint.design(s), amendWithin: 2, source: "edit")
    }

    /// Makes a result the artifact's new revision: "Use as Frame" on outcome 13.
    func promote(_ artifact: String, from: String, summary: String? = nil, data: [String: Any]? = nil) {
        send(["op": "promote", "artifact": artifact, "from": from, "summary": summary, "data": data])
    }

    /// Puts an earlier revision back in use.
    func activate(_ artifact: String, revision: Int) {
        send(["op": "activate", "artifact": artifact, "revision": revision])
    }

    func revisions(_ artifact: String) -> [Revision] {
        _ = version
        return decode([Revision].self, read(["op": "revisions", "artifact": artifact]), at: ["list", "revisions"]) ?? []
    }

    func diff(_ artifact: String, from: Int? = nil, to: Int? = nil) -> Diff? {
        _ = version
        return decode(Diff.self, read(["op": "diff", "artifact": artifact, "from": from, "to": to]), at: ["diff"])
    }

    /// The stale or failed artifacts to rebuild, in order, so `artifact` is current.
    func planUpdate(_ artifact: String) -> [String] { (read(["op": "plan_update", "artifact": artifact])?["order"] as? [String]) ?? [] }

    /// Everything built from `artifact`, in build order.
    func downstream(_ artifact: String) -> [String] { (read(["op": "downstream", "artifact": artifact])?["order"] as? [String]) ?? [] }

    /// PIPELINE OUTPUTS: every artifact with its state, reason and action.
    func outputs() -> [Output] {
        _ = version
        return decode([Output].self, read(["op": "outputs"]), at: ["outputs"]) ?? []
    }

    // MARK: Jobs

    /// Starts work on `artifact`; answers the job id. `total` counts steps; `expected` (seconds)
    /// gives progress and time left to work that cannot count. `controls` is what pause,
    /// resume and cancel call.
    @discardableResult
    func startJob(_ artifact: String, verb: String, label: String, total: Int? = nil, expected: Double? = nil, controls: JobControls? = nil) -> Int? {
        let r = send(["op": "job_start", "artifact": artifact, "verb": verb, "label": label, "total": total, "expected": expected,
                      "pausable": controls?.pause != nil && controls?.resume != nil])
        guard let id = r?["job"] as? Int else { return nil }
        if let controls { self.controls[id] = controls }
        return id
    }

    func progress(job: Int, fraction: Double? = nil, done: Int? = nil, total: Int? = nil, label: String? = nil) {
        send(["op": "job_progress", "job": job, "progress": fraction, "done": done, "total": total, "label": label])
    }

    func pause(job: Int) {
        guard controls[job]?.pause?() != false else { return }
        send(["op": "job_pause", "job": job])
    }

    func resume(job: Int) {
        guard controls[job]?.resume?() != false else { return }
        send(["op": "job_resume", "job": job])
    }

    func cancel(job: Int) {
        let c = controls.removeValue(forKey: job)
        send(["op": "job_cancel", "job": job])
        c?.cancel?()
    }

    /// A nil error builds the artifact; an error keeps its last build and marks it failed.
    func end(job: Int, error: String? = nil, summary: String? = nil, data: [String: Any]? = nil) {
        controls[job] = nil
        send(["op": "job_end", "job": job, "error": error, "summary": summary, "data": data])
    }

    /// The job running on `artifact`, if any.
    func job(on artifact: String) -> RunningJob? { jobs.first { $0.artifact == artifact } }

    func jobStart(_ artifact: String, label: String) {
        startJob(artifact, verb: label, label: label)
    }

    func jobProgress(_ artifact: String, _ progress: Double) {
        send(["op": "job_progress", "artifact": artifact, "progress": progress])
    }

    /// Ends the job on `artifact` (or, with none running, records the build or the failure).
    func jobEnd(_ artifact: String, error: String? = nil, summary: String? = nil) {
        if let j = job(on: artifact) { controls[j.id] = nil }
        send(["op": "job_end", "artifact": artifact, "error": error, "summary": summary])
    }

    // MARK: Tree and selection

    func tree(_ stage: String) -> [TreeRow] {
        _ = version
        return decode([TreeRow].self, read(["op": "tree", "stage": stage]), at: ["tree", "rows"]) ?? []
    }

    func reportTree(_ stage: String, items: [TreeItem]) {
        guard let data = try? JSONEncoder().encode(items), let list = try? JSONSerialization.jsonObject(with: data) else { return }
        send(["op": "tree_report", "stage": stage, "items": list], save: false)
    }

    func setVisible(_ id: String, _ visible: Bool) { send(["op": "tree_set", "id": id, "visible": visible]) }
    func setLocked(_ id: String, _ locked: Bool) { send(["op": "tree_set", "id": id, "locked": locked]) }

    func select(_ ids: [String], in stage: String, anchor: SIMD3<Double>? = nil) {
        send(["op": "select", "stage": stage, "ids": ids, "anchor": anchor.map { [$0.x, $0.y, $0.z] }])
    }

    func clearSelection() { select([], in: "") }

    // MARK: Commands

    /// Every command of the eight stages, or of one.
    /// The catalog's commands, of one stage or all. The hand has no flight: its Simulation
    /// stage is a grasp test, so the drone's flight verbs (fly, race, stress, wind, record) are
    /// not offered on it.
    func commands(stage: String? = nil) -> [Command] {
        let all = decode([Command].self, read(["op": "commands", "stage": stage]), at: ["commands"]) ?? []
        return isHandProduct ? all.filter { !$0.id.hasPrefix("simulate.") } : all
    }

    /// The command palette's search: best first, the current stage's commands ahead on a tie;
    /// a single letter that is a shortcut (E, F, M, J) finds its command first.
    func search(_ query: String, stage: String? = nil, limit: Int = 20) -> [Command] {
        guard let hits = read(["op": "search", "query": query, "stage": stage, "limit": limit])?["results"] as? [[String: Any]] else { return [] }
        return hits.compactMap { h in
            guard let c = h["command"], let data = try? JSONSerialization.data(withJSONObject: c) else { return nil }
            return try? JSONDecoder().decode(Command.self, from: data)
        }
    }

    // MARK: Project file

    /// Writes the pipeline into the `.viaform` project at `url` as `flow.json`.
    func save(into url: URL) {
        send(["op": "save", "path": url.path], save: false)
    }

    /// Reads the pipeline from the `.viaform` project at `url`; a project saved without one
    /// starts a fresh pipeline. Answers whether it had one.
    @discardableResult
    func open(from url: URL) -> Bool {
        let r = send(["op": "open", "path": url.path])
        return (r?["found"] as? Bool) ?? false
    }

    /// The pipeline as a document (what `flow.json` holds).
    func exportDocument() -> Data? {
        guard let doc = read(["op": "export"])?["doc"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }

    func setProduct(_ name: String) { send(["op": "set_product", "name": name]) }

    /// Picks the product's graph ("drone", "hand"), keeping the revisions of the artifacts both
    /// graphs share.
    func setGraph(preset: String) { send(["op": "set_graph", "preset": preset]) }

    func reset() { send(["op": "reset"]) }

    // MARK: Documents

    /// A new document: a fresh pipeline, no autosave until it gets a path. `product` names it
    /// (a sample), else the title falls back to the design's name.
    func newDocument(product: String? = nil, graph: String = "drone") {
        pendingSave?.cancel()
        documentKey = nil
        isProjectFile = false
        send(["op": "reset"], save: false)
        if graph != "drone" { send(["op": "set_graph", "preset": graph], save: false) }
        if let product { send(["op": "set_product", "name": product], save: false) }
        documentEpoch += 1
    }

    /// The open document got a path (Save As): the pipeline stays, and is kept under it.
    func adoptDocument(_ key: String) {
        guard key != documentKey else { return }
        documentKey = key
        scheduleAutosave()
    }

    /// Another document was opened: its own autosave comes back, or a fresh pipeline.
    func openDocument(_ key: String) {
        pendingSave?.cancel()
        isProjectFile = false
        documentKey = key
        if let url = autosaveURL(for: key), let data = try? Data(contentsOf: url),
           let doc = try? JSONSerialization.jsonObject(with: data), (call(["op": "import", "doc": doc])?["error"]) == nil {
            refresh()
            version += 1
        } else {
            send(["op": "reset"], save: false)
        }
        documentEpoch += 1
    }

    /// Saves the pipeline into the `.viaform` project just written at `url`.
    func saveProject(_ url: URL) {
        save(into: url)
        isProjectFile = true
        documentKey = url.path
        scheduleAutosave()
    }

    /// Reads the pipeline from the `.viaform` project just opened at `url`: its `flow.json`, or
    /// for a project saved without one, the autosave kept for it, else a fresh pipeline.
    func openProject(_ url: URL) {
        pendingSave?.cancel()
        isProjectFile = true
        documentKey = url.path
        if !open(from: url) {
            openDocument(url.path)
            isProjectFile = true
        }
        documentEpoch += 1
    }

    // MARK: Plumbing

    @discardableResult
    private func send(_ command: [String: Any?], save: Bool = true) -> [String: Any]? {
        let r = call(command)
        refresh()
        version += 1
        if save { scheduleAutosave() }
        return r
    }

    private func encode(_ command: [String: Any?]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: command.compactMapValues { $0 }) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func parse(_ reply: String) -> [String: Any]? {
        let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]
        return object
    }

    private func call(_ command: [String: Any?]) -> [String: Any]? {
        guard let text = encode(command) else { return nil }
        let object = parse(service.command(text))
        error = object?["error"] as? String
        return object
    }

    private func read(_ query: [String: Any?]) -> [String: Any]? {
        guard let text = encode(query) else { return nil }
        return parse(service.query(text))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]?, at path: [String]) -> T? {
        var v: Any? = object
        for k in path { v = (v as? [String: Any])?[k] }
        guard let v, let data = try? JSONSerialization.data(withJSONObject: v) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func refresh() {
        guard let s = try? JSONDecoder().decode(State.self, from: Data(service.state().utf8)) else {
            error = "unreadable pipeline state"
            return
        }
        if let p = s.product.map({ $0 == "Untitled" ? "" : $0 }), p != product { product = p }
        if s.stages != stages { stages = s.stages }
        if s.nodes != nodes { nodes = s.nodes }
        if s.jobs != jobs { jobs = s.jobs }
        if let sel = s.selection, sel != selection { selection = sel }
        // Running jobs move on their own (time left, Rust workers): keep reading while any runs.
        if jobs.isEmpty {
            poll?.cancel()
            poll = nil
        } else if poll == nil {
            poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    let ended = (self.parse(self.service.tick())?["ended"] as? [Int]) ?? []
                    for id in ended { self.controls[id] = nil }
                    self.refresh()
                    if !ended.isEmpty { self.version += 1; self.scheduleAutosave() }
                    if self.jobs.isEmpty { return }
                }
            }
        }
    }

    private func scheduleAutosave() {
        guard let url = autosaveURL else { return }
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let data = self.exportDocument() else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Whoever writes or reads a `.viaform` file posts these with the file's URL as the object,
    /// and the pipeline rides along as `flow.json`.
    private func listenForProjectFiles() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .viaformProjectSaved, object: nil, queue: .main) { [weak self] n in
            guard let url = n.object as? URL else { return }
            MainActor.assumeIsolated { self?.saveProject(url) }
        })
        observers.append(nc.addObserver(forName: .viaformProjectOpened, object: nil, queue: .main) { [weak self] n in
            guard let url = n.object as? URL else { return }
            MainActor.assumeIsolated { self?.openProject(url) }
        })
    }
}

extension Notification.Name {
    /// Posted after a `.viaform` file is written (object: its URL): the pipeline writes its
    /// `flow.json` into it.
    static let viaformProjectSaved = Notification.Name("me.somalabs.viaform.projectSaved")
    /// Posted after a `.viaform` file is opened (object: its URL): the pipeline reads its
    /// `flow.json` from it.
    static let viaformProjectOpened = Notification.Name("me.somalabs.viaform.projectOpened")
}

/// A digest of what a workspace holds, stable across launches (FNV-1a, not `Hasher`, which is
/// seeded per process), so an undo back to a saved state finds that revision again.
enum FlowFingerprint {
    static func of(_ parts: [String]) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\u{1F}").utf8 {
            h ^= UInt64(byte)
            h &*= 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// The design's bodies, features, sketches and parameters, not its camera or selection.
    static func design(_ s: DesignSnapshot) -> String {
        var parts: [String] = []
        for b in s.bodies { parts.append("b|\(b.name)|\(Int(((b.volume_mm3 ?? 0) * 100).rounded()))|\(b.faces ?? 0)|\(b.material ?? "")") }
        for f in s.timeline { parts.append("f|\(f.name)|\(f.type)|\(f.suppressed ?? false)|\(f.rolled_back ?? false)") }
        for k in s.sketches { parts.append("s|\(k.name)|\(k.curves ?? 0)") }
        for p in s.params { parts.append("p|\(p.name)|\(p.expression)") }
        return of(parts)
    }
}
