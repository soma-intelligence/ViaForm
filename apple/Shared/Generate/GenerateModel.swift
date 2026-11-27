import CoreGraphics
import Foundation
import Observation
import simd

/// The Generate workspace: a 3D study being set up (design space, material, goal, limits, the
/// regions that hold, load, keep out and keep in), the candidates its last run gave with their
/// previews, and the one picked to build into the design. Runs happen off the main actor;
/// building owns the design's session in the background while [`EngineGate`] is shut.
@MainActor
@Observable
final class GenerateModel {
    enum Template: String, CaseIterable, Identifiable {
        case bracket = "Wall bracket", cantilever = "Cantilever", motorMount = "Motor mount", bridge = "Bridge"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bracket: String(localized: "Wall bracket")
            case .cantilever: String(localized: "Cantilever")
            case .motorMount: String(localized: "Motor mount")
            case .bridge: String(localized: "Bridge")
            }
        }
        var symbol: String {
            switch self {
            case .bracket: "l.square"
            case .cantilever: "arrow.down.right"
            case .motorMount: "fanblades"
            case .bridge: "road.lanes"
            }
        }
    }

    enum Display: String, CaseIterable { case setup = "Setup", result = "Result", assembly = "Assembly" }
    enum Pane: String, CaseIterable { case project = "Project", study = "Study", regions = "Regions", results = "Results", variants = "Variants" }

    /// A region of the study, by what it is and its identity.
    enum RegionKey: Hashable {
        case support(UUID), load(UUID), keepOut(UUID), keepIn(UUID)

        /// The scene node name that carries the key.
        var name: String {
            switch self {
            case .support(let id): "s|\(id.uuidString)"
            case .load(let id): "l|\(id.uuidString)"
            case .keepOut(let id): "o|\(id.uuidString)"
            case .keepIn(let id): "i|\(id.uuidString)"
            }
        }

        init?(name: String) {
            let parts = name.split(separator: "|")
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
            switch parts[0] {
            case "s": self = .support(id)
            case "l": self = .load(id)
            case "o": self = .keepOut(id)
            case "i": self = .keepIn(id)
            default: return nil
            }
        }
    }

    var study = GenerateModel.study(.cantilever) {
        didSet { if study != oldValue { recordEdit(from: oldValue) } }
    }
    /// The setup as it was last loaded (template, project study, sample): edits since then are
    /// the user's own and are never replaced without asking.
    private(set) var baseline = GenerateModel.study(.cantilever)
    var display = Display.setup
    var pane = Pane.study
    var selection: RegionKey?
    /// The load case the regions pane edits; its loads draw in full colour.
    var activeCase = 0
    private(set) var outcome: StudyOutcome?
    /// The study the candidates came from: building reruns exactly that one.
    private(set) var studied: Study?
    /// Preview geometry per candidate, built off the main actor with the outcome.
    private(set) var previews: [PreviewMesh] = [] { didSet { previewsVersion += 1 } }
    /// Bumped whenever the previews are rebuilt (a new outcome, a picked variant, a new colour
    /// scale): the scene and the gallery follow it.
    private(set) var previewsVersion = 0
    /// Counts outcomes, so views know when previews and thumbnails are new.
    private(set) var outcomeVersion = 0
    var selected: Int?
    private(set) var running = false
    private(set) var startedAt: Date?
    /// Seconds the running study is expected to take.
    private(set) var expected: Double = 0
    private(set) var building = false
    private(set) var error: String?
    private(set) var notice: String?
    private var runID = 0
    private var hooksRan = false
    /// The open project (`--sample hand`, `--sample drone`): its studies and its assembly.
    private(set) var project: GenerateProject?
    /// The project study the setup came from, and the setup as it came (edits are sent over the
    /// file, so fields the editor does not show still reach the engine).
    private(set) var projectStudy: String?
    private var loadedStudy: Study?
    private var loadedRaw: Data?
    /// Where the running study is, as the engine reports it.
    private(set) var progress: GenerateJob.Progress?
    /// The running study, and the one the shown candidates came from (builds take them from it).
    private var runningJob: GenerateJob?
    private var outcomeJob: GenerateJob?
    /// The project's assembly once inserted into the design, and its movable joints.
    private(set) var assemblyLoaded = false
    private(set) var loadingAssembly = false
    private(set) var assemblySummary: AssemblyJoint.Summary?
    var joints: [AssemblyJoint] = []
    private var moving: (key: RegionKey, region: StudyRegion, center: Vec3)?

    // MARK: Live run state

    /// Every iteration the running (or last) study reported: the convergence plot's points.
    private(set) var liveSteps: [GenerateJob.LiveStep] = []
    /// The running shape (a coarse surface of the latest densities) and its version.
    private(set) var livePreview: PreviewMesh?
    private(set) var liveVersion = 0
    private(set) var paused = false
    /// Seconds the last results took to open once the engine finished (summary and surfaces).
    private(set) var openSeconds: Double?
    @ObservationIgnored private var fetchingPreview = false

    // MARK: Gallery, camera and colours (kept here, so a return to Generate finds them)

    /// Stills of the candidates, by index, for `thumbnailsFor` previews.
    private(set) var thumbnails: [Int: CGImage] = [:]
    /// Indices whose still was attempted (a surface may give none).
    private(set) var thumbnailsDone: Set<Int> = []
    @ObservationIgnored private var thumbnailsFor = -1
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    /// The preview's camera when the Generate view last closed.
    @ObservationIgnored var camera: GenerateScene.CameraState?

    // MARK: Outcomes (VIAFORM-SPEC 7.10.3: sort, compare, mesh checks, export, Pareto)

    /// The gallery's order.
    var outcomeSort = OutcomeSort.mass
    /// The candidate under the pointer in the gallery or the Pareto chart (they light together).
    var hoveredOutcome: Int?
    /// The two candidates the compare sheet shows, by index; nil when it is closed.
    var comparing: OutcomePair?
    /// Mesh checks per candidate index, for `meshChecksFor` outcomes.
    var meshChecks: [Int: MeshCheckReport] = [:]
    /// Candidates whose checks failed to run, with the reason.
    var meshCheckErrors: [Int: String] = [:]
    @ObservationIgnored var meshChecksFor = -1
    /// An export is being written.
    var exporting = false
    /// The last export's failure, shown with Try Again until dismissed.
    var exportFailure: OutcomeExportFailure?
    /// Try Again on a failed export: the export menu picks it up and starts over.
    var retryExport: OutcomeExportFailure?
    /// A box to frame in the preview (a mesh check's Show), and a count so the view reacts to it.
    var focusBox: (lo: Vec3, hi: Vec3)?
    var focusVersion = 0

    /// Renders the gallery stills off the main actor, once per set of previews; a return to the
    /// stage keeps the ones already made.
    func renderThumbnails(theme: ViewportTheme) {
        guard thumbnailsFor != previewsVersion else { return }
        thumbnailsFor = previewsVersion
        thumbnails = [:]
        thumbnailsDone = []
        thumbnailTask?.cancel()
        let previews = previews, version = previewsVersion
        thumbnailTask = Task { [weak self] in
            for (i, p) in previews.enumerated() {
                let image = await Task.detached(priority: .utility) {
                    GenerateScene.thumbnail(p, size: CGSize(width: 320, height: 220), theme: theme)
                }.value
                guard let self, !Task.isCancelled, version == self.previewsVersion else { return }
                if let image { self.thumbnails[i] = image }
                self.thumbnailsDone.insert(i)
            }
        }
    }

    /// The stress heat map's colours; a change recolours the candidates off the main actor.
    var stressScale: StressColors.Scale = StressColors.current {
        didSet {
            guard stressScale != oldValue else { return }
            StressColors.current = stressScale
            recolor()
        }
    }

    private func recolor() {
        guard let o = outcome, let s = studied, !o.candidates.isEmpty else { return }
        let version = outcomeVersion
        let candidates = o.candidates
        Task { [weak self] in
            let rebuilt = await Task.detached(priority: .userInitiated) { candidates.map { PreviewMesh.make($0, study: s) } }.value
            guard let self, version == self.outcomeVersion else { return }
            self.previews = rebuilt
        }
    }

    // MARK: Variants

    /// Manufacturing routes the variants compare.
    enum Route: String, CaseIterable, Identifiable, Sendable {
        case fdm = "FDM", sls = "SLS", cnc3 = "CNC 3-axis"
        var id: String { rawValue }
        /// The engine's process keyword.
        var key: String {
            switch self {
            case .fdm: "fdm"
            case .sls: "sls"
            case .cnc3: "cnc3"
            }
        }
        var process: StudyManufacturing.Process {
            switch self {
            case .fdm: .additive
            case .sls: .free
            case .cnc3: .milling
            }
        }
    }

    /// One variant of the study: what it changes, its run and what came out.
    struct VariantRun: Identifiable {
        let id: Int
        var label: String
        var study: Study
        var json: String
        var job: GenerateJob?
        var progress: GenerateJob.Progress?
        var outcome: StudyOutcome?
        var preview: PreviewMesh?
        var error: String?
        var candidate: StudyCandidate? { outcome.flatMap { $0.candidates[safe: $0.best] } }
    }

    /// Volume fractions, materials and routes the next exploration crosses.
    var variantFractions: [Double] = [0.15, 0.25]
    var variantMaterials: [String] = ["PLA", "Aluminum 6061"]
    var variantRoutes: Set<Route> = [.fdm, .sls, .cnc3]
    private(set) var variants: [VariantRun] = []
    private(set) var exploring = false
    /// The variant last pushed to the results (Build takes it from there).
    private(set) var pickedVariant: Int?

    /// The route of the variant pushed to the results, if any (mesh checks hold it to its process).
    var pickedRoute: Route? {
        guard let i = pickedVariant, let label = variants[safe: i]?.label else { return nil }
        return Route.allCases.first { label.hasPrefix($0.rawValue) }
    }

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let name = GenerateProject.launchSample { openSample(name) }
        if let pick = args.first(where: { $0.hasPrefix("--generate-study=") })?.dropFirst(17), let e = project?.studies.first(where: { $0.name == pick }) { load(e) }
        // What the app opened with is the start of the history, not a step to undo.
        undoStack = []
        redoStack = []
        // `--generate-variants=N`: run N candidates (screenshots of the outcomes gallery).
        if let n = args.first(where: { $0.hasPrefix("--generate-variants=") }).flatMap({ Int($0.dropFirst(20)) }) {
            study.variants = min(max(n, 1), 8)
            undoStack = []
        }
        if args.contains("--generate-run") { run() }
        // `--generate-explore`: run the default variants at once, then push the lightest
        // feasible one (else the first) to the results.
        if args.contains("--generate-explore") {
            pane = .variants
            explore()
        }
    }

    /// A model that only reads project `name` (assembly, joints, summary) for a side view such as
    /// the grasp test: no launch arguments, no study loaded, and the Generate stage's own model
    /// is left alone.
    init(reading name: String) {
        openSample(name, replaceStudy: false)
        undoStack = []
        redoStack = []
    }

    /// The setup changed since the candidates were made.
    var stale: Bool { outcome != nil && studied != study && pickedVariant == nil }

    /// The user changed the setup since it was loaded: replacing it asks first.
    var studyEdited: Bool { study != baseline }

    var candidate: StudyCandidate? {
        guard let o = outcome, let s = selected, o.candidates.indices.contains(s) else { return nil }
        return o.candidates[s]
    }

    func apply(_ t: Template) {
        let material = study.material
        var next = Self.study(t)
        if t != .bridge { next.material = material }
        named(String(localized: "Apply Template")) { study = next }
        baseline = next
        loadedStudy = nil
        loadedRaw = nil
        projectStudy = nil
        selection = nil
        activeCase = 0
        display = .setup
    }

    // MARK: Readiness

    /// Why Run cannot start yet, naming the section to fill (nil when the study can run).
    /// A project study unedited from its file runs as the file says (it may hold supports the
    /// editor does not show).
    var readiness: String? {
        if loadedRaw != nil, study == loadedStudy { return nil }
        if study.elementCount <= 0 { return String(localized: "Give the design space a size in Study.") }
        if study.supports.isEmpty { return String(localized: "Add a support in Regions.") }
        let loaded = study.cases.contains { !$0.loads.isEmpty || $0.acceleration != nil }
        if !loaded { return String(localized: "Add a load in Regions.") }
        return nil
    }

    /// The line under Run: what is missing, or what the study holds.
    var readinessLine: String {
        if let r = readiness { return r }
        let loads = study.cases.reduce(0) { $0 + $1.loads.count }
        return String(localized: "Ready: \(study.supports.count) supports, \(loads) loads in \(study.cases.count) cases")
    }

    // MARK: Undo

    /// One step of the study's undo history: the setup before the change, and its name.
    struct UndoStep: Identifiable {
        let id = UUID()
        let study: Study
        let name: String
    }

    private(set) var undoStack: [UndoStep] = []
    private(set) var redoStack: [UndoStep] = []
    @ObservationIgnored private var lastEdit = Date.distantPast
    @ObservationIgnored private var pendingName: String?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var grouping = false

    var canUndo: Bool { !running && !undoStack.isEmpty }
    var canRedo: Bool { !running && !redoStack.isEmpty }
    /// "Undo Study Change", or the named step ("Undo Remove Support").
    var undoName: String { undoStack.last?.name ?? String(localized: "Study Change") }
    var redoName: String { redoStack.last?.name ?? String(localized: "Study Change") }

    /// Runs `change` as one named undo step.
    private func named(_ name: String, _ change: () -> Void) {
        pendingName = name
        lastEdit = .distantPast
        change()
        pendingName = nil
        lastEdit = .distantPast
    }

    /// Runs `change` (any number of edits) as one undo step named `name`.
    func asOneStep(_ name: String, _ change: () -> Void) {
        let before = study
        let wasGrouping = grouping
        grouping = true
        change()
        grouping = wasGrouping
        if !wasGrouping, study != before {
            undoStack.append(UndoStep(study: before, name: name))
            redoStack.removeAll()
        }
        lastEdit = .distantPast
    }

    /// Records the setup before an edit. Edits closer than a second with the same name (typing,
    /// dragging a region, a slider) coalesce into one step.
    private func recordEdit(from old: Study) {
        guard !restoring else { return }
        redoStack.removeAll()
        if grouping { return }
        let name = pendingName ?? String(localized: "Study Change")
        let now = Date()
        if pendingName == nil, now.timeIntervalSince(lastEdit) < 1, undoStack.last?.name == name {
            lastEdit = now
            return
        }
        lastEdit = now
        undoStack.append(UndoStep(study: old, name: name))
        if undoStack.count > 100 { undoStack.removeFirst(undoStack.count - 100) }
    }

    func undo() {
        guard canUndo, let step = undoStack.popLast() else { return }
        redoStack.append(UndoStep(study: study, name: step.name))
        restore(step.study)
    }

    func redo() {
        guard canRedo, let step = redoStack.popLast() else { return }
        undoStack.append(UndoStep(study: study, name: step.name))
        restore(step.study)
    }

    /// Undoes `step` when it is still the latest one (a toast's Undo after a removal).
    func undo(step id: UUID?) {
        guard let id, undoStack.last?.id == id else { return }
        undo()
    }

    /// The id of the latest undo step, for a toast to undo exactly that one.
    var lastUndoID: UUID? { undoStack.last?.id }

    private func restore(_ s: Study) {
        restoring = true
        study = s
        restoring = false
        lastEdit = .distantPast
        if let key = selection, region(key) == nil { selection = nil }
        activeCase = min(max(activeCase, 0), max(study.cases.count - 1, 0))
    }

    // MARK: Run

    /// The study as the engine takes it: the project file as it came when the setup was not
    /// edited, else the file with the editor's fields laid over it.
    func engineJSON(_ s: Study) throws -> String {
        guard let raw = loadedRaw, let loaded = loadedStudy else { return try GenerateEngine.json(s) }
        if s == loaded { return String(decoding: raw, as: UTF8.self) }
        guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let mine = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any] else { return try GenerateEngine.json(s) }
        for (k, v) in mine { obj[k] = v }
        return String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    /// Runs the study in the engine on its own thread, following its iterations; Stop ends it at
    /// the next one and keeps its best design so far, Discard drops it.
    func run() {
        let study = study
        stopRequested = false
        stopping = false
        error = nil
        notice = nil
        let job: GenerateJob
        do {
            job = try GenerateJob(json: try engineJSON(study))
        } catch {
            self.error = error.localizedDescription
            return
        }
        runningJob?.cancel()
        runID += 1
        let id = runID
        runningJob = job
        running = true
        progress = nil
        liveSteps = []
        livePreview = nil
        liveVersion = 0
        paused = false
        openSeconds = nil
        startedAt = Date()
        expected = Self.estimate(study)
        let units = Self.workUnits(study), overhead = Self.overhead(study)
        Task { [weak self] in
            while let self, id == self.runID, self.running {
                let p = job.progress
                self.progress = p
                self.paused = p.paused
                // The engine's own pace once it has one, else the estimate.
                if let eta = p.eta { self.expected = p.seconds + eta + Self.overhead(study) } else if p.fraction > 0.05, p.seconds > 1 { self.expected = p.seconds / p.fraction }
                let new = job.history(from: self.liveSteps.count)
                if !new.isEmpty { self.liveSteps += new }
                self.followPreview(job, version: p.previewVersion, id: id, study: study)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(StudyOutcome, [PreviewMesh], Double), any Error> in
                Result {
                    // Wait for the engine, then time the opening alone: the figures (no
                    // densities) and each surface as flat arrays.
                    while job.progress.running { Thread.sleep(forTimeInterval: 0.02) }
                    let t = Date()
                    let o = try job.summary()
                    let previews = o.candidates.map { PreviewMesh.make($0, study: study) }
                    return (o, previews, Date().timeIntervalSince(t))
                }
            }.value
            guard let self, id == self.runID else { return }
            let stopped = self.stopping
            self.running = false
            self.stopping = false
            self.runningJob = nil
            switch result {
            case .success(let (o, previews, open)):
                self.openSeconds = open
                self.liveSteps += job.history(from: self.liveSteps.count)
                self.pickedVariant = nil
                self.outcome = o
                self.outcomeJob = job
                self.previews = previews
                self.outcomeVersion += 1
                self.studied = study
                self.progress = job.progress
                self.selected = o.candidates.indices.contains(o.best) ? o.best : (o.candidates.isEmpty ? nil : 0)
                self.display = o.candidates.isEmpty ? .setup : .result
                if o.candidates.isEmpty { self.error = String(localized: "The study gave no candidates. Loosen the limits or add volume, then run again.") }
                if let c = o.stoppedCandidate, let n = c.stoppedAt {
                    self.notice = String(localized: "Stopped at iteration \(n). The best design so far is kept as candidate \(c.id + 1), not converged.")
                } else if o.stopped || stopped {
                    self.notice = String(localized: "Stopped. The finished candidates are kept.")
                }
                Self.calibrate(seconds: o.seconds > 0 ? o.seconds : Date().timeIntervalSince(self.startedAt ?? Date()), units: units, overhead: overhead)
                self.afterRun?()
                self.afterRun = nil
            case .failure(let e):
                if e.localizedDescription == "cancelled" {
                    self.notice = String(localized: "Stopped before a usable shape formed. The last results are kept.")
                } else {
                    self.error = e.localizedDescription
                }
            }
        }
    }

    /// Fetches the live shape off the main actor when the engine has a newer one, at most one
    /// at a time (the engine surfaces it on the fetching thread).
    private func followPreview(_ job: GenerateJob, version: Int, id: Int, study: Study) {
        guard version > liveVersion, !fetchingPreview else { return }
        fetchingPreview = true
        let since = liveVersion
        Task { [weak self] in
            let got = await Task.detached(priority: .utility) { () -> (Int, PreviewMesh)? in
                guard let p = job.preview(since: since) else { return nil }
                return (p.version, PreviewMesh.live(p.mesh, study: study))
            }.value
            guard let self else { return }
            self.fetchingPreview = false
            guard id == self.runID, self.running, let (v, mesh) = got, v > self.liveVersion else { return }
            self.livePreview = mesh
            self.liveVersion = v
        }
    }

    func clearError() { error = nil }

    /// Holds the running study after its current iteration, or lets it go on.
    func togglePause() {
        guard running else { return }
        _ = setPaused(!paused)
    }

    /// Pauses or resumes the running study (the jobs list calls this too); false when no study runs.
    @discardableResult
    func setPaused(_ on: Bool) -> Bool {
        guard running, let job = runningJob else { return false }
        if paused != on {
            paused = on
            job.setPaused(on)
        }
        return true
    }

    /// Seconds the running study has been going.
    var runAge: Double { running ? Date().timeIntervalSince(startedAt ?? Date()) : 0 }

    /// A stop of a run older than this many seconds asks first: keep the best so far, discard
    /// the run, or keep it running.
    static let confirmStopAfter = 30.0

    /// Set when a stop needs confirming; the Generate view shows the question.
    var stopRequested = false

    /// True between a stop that keeps the best so far and the engine's answer (the kept design
    /// is analysed and surfaced first, a few seconds at most).
    var stopping = false

    /// Stop from a button, Command-., a menu or the jobs list: at once (keeping the best design
    /// so far) for a young run, else asks first.
    func requestStop() {
        guard running, !stopping else { return }
        if runAge > Self.confirmStopAfter { stopRequested = true } else { cancel() }
    }

    /// Stops the running study at its next iteration and keeps its best design so far: the
    /// engine answers it as a candidate flagged not converged, which opens like any result.
    /// Asking again while it stops does nothing.
    func cancel() {
        stopRequested = false
        guard running, !stopping, let job = runningJob else { return }
        stopping = true
        paused = false
        job.cancel()
        notice = String(localized: "Stopping. Keeping the best design so far.")
    }

    /// Stops the running study and drops its answer; the last results stay.
    func discard() {
        stopRequested = false
        guard running else { return }
        runningJob?.cancel()
        runningJob = nil
        runID += 1
        running = false
        stopping = false
        paused = false
        notice = String(localized: "Stopped. The last results are kept.")
    }

    // MARK: Variants

    /// The variants the current choices cross: every volume fraction, material and route.
    var variantPlan: [(label: String, fraction: Double, material: StudyMaterial, route: Route)] {
        var out: [(String, Double, StudyMaterial, Route)] = []
        for f in variantFractions {
            for name in variantMaterials {
                guard let m = StudyMaterial.presets.first(where: { $0.name == name }) else { continue }
                for r in Route.allCases where variantRoutes.contains(r) {
                    out.append(("\(r.rawValue) · \(m.name) · \(Int((f * 100).rounded())) %", f, m, r))
                }
            }
        }
        return out
    }

    /// Runs every planned variant at once, each as its own engine job (one candidate each).
    func explore() {
        guard !exploring, !running else { return }
        let plan = variantPlan
        guard !plan.isEmpty else { return }
        error = nil
        let base: String
        do { base = try engineJSON(study) } catch { self.error = error.localizedDescription; return }
        var runs: [VariantRun] = []
        for (i, v) in plan.enumerated() {
            var s = study
            s.volumeFraction = v.fraction
            s.material = v.material
            s.manufacturing.process = v.route.process
            s.manufacturing.overhang = 45
            s.variants = 1
            if s.dynamics.modes == 0 { s.dynamics.modes = 1 }
            var run = VariantRun(id: i, label: v.label, study: s, json: "")
            do {
                let enc = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v.material))
                run.json = try GenerateJob.variant(base: base, variant: ["label": v.label, "volume_fraction": v.fraction, "material": enc, "process": v.route.key])
                run.job = try GenerateJob(json: run.json)
            } catch {
                run.error = error.localizedDescription
            }
            runs.append(run)
        }
        variants = runs
        pickedVariant = nil
        exploring = true
        Task { [weak self] in
            while let self, self.exploring {
                var busy = false
                for i in self.variants.indices {
                    guard let job = self.variants[i].job, self.variants[i].outcome == nil, self.variants[i].error == nil else { continue }
                    let p = job.progress
                    self.variants[i].progress = p
                    if p.running { busy = true; continue }
                    let s = self.variants[i].study
                    let r = await Task.detached(priority: .userInitiated) { () -> Result<(StudyOutcome, PreviewMesh?), any Error> in
                        Result {
                            let o = try job.summary()
                            return (o, o.candidates[safe: o.best].map { PreviewMesh.make($0, study: s) })
                        }
                    }.value
                    switch r {
                    case .success(let (o, p)):
                        self.variants[i].outcome = o
                        self.variants[i].preview = p
                    case .failure(let e):
                        self.variants[i].error = e.localizedDescription
                    }
                }
                if !busy && self.variants.allSatisfy({ $0.outcome != nil || $0.error != nil }) {
                    self.exploring = false
                    if ProcessInfo.processInfo.arguments.contains("--generate-explore") {
                        let done = self.variants.filter { $0.candidate != nil }
                        let pick = done.filter { $0.candidate!.feasible }.min { $0.candidate!.massG < $1.candidate!.massG } ?? done.first
                        if let pick { self.pickVariant(pick.id) }
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    /// Stops every variant still running.
    func stopExploring() {
        variants.forEach { $0.job?.cancel() }
        exploring = false
    }

    /// Makes variant `i` the results: its candidate shows, analyses and builds into the design.
    func pickVariant(_ i: Int) {
        guard let v = variants[safe: i], let o = v.outcome, let job = v.job, !running else { return }
        outcome = o
        outcomeJob = job
        studied = v.study
        previews = o.candidates.map { c in c.id == o.candidates[safe: o.best]?.id ? (v.preview ?? PreviewMesh.make(c, study: v.study)) : PreviewMesh.make(c, study: v.study) }
        outcomeVersion += 1
        selected = o.candidates.indices.contains(o.best) ? o.best : nil
        pickedVariant = i
        display = .result
    }

    /// What to do once the next run ends well (launch hooks chain on it).
    @ObservationIgnored private var afterRun: (() -> Void)?

    // MARK: Project

    /// Opens the sample project `name` with its assembly and joints. Its first study becomes the
    /// setup only when `replaceStudy` says so; by default (nil) only when the user has not edited
    /// the setup, so opening a project from another stage never drops the user's study. The
    /// replacement is one undo step.
    func openSample(_ name: String, replaceStudy: Bool? = nil) {
        do {
            let p = try GenerateProject.open(name)
            project = p
            assemblyLoaded = false
            joints = p.assembly.map(AssemblyJoint.read) ?? []
            assemblySummary = p.assembly.map(AssemblyJoint.summary)
            pane = .project
            if replaceStudy ?? !studyEdited, let first = p.firstStudy { load(first) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Opens the project's assembly and joints only, leaving the setup as it is. The grasp test
    /// no longer calls this (it reads the hand into a model of its own, `init(reading:)`).
    func openProjectOnly(_ name: String) {
        guard project?.name != name else { return }
        let keep = pane
        openSample(name, replaceStudy: false)
        pane = keep
    }

    /// Makes a project study the setup (one undo step).
    func load(_ e: GenerateProject.Entry) {
        guard !running else { return }
        named(String(localized: "Open Study")) { study = e.study }
        baseline = e.study
        loadedStudy = e.study
        loadedRaw = e.raw
        projectStudy = e.name
        selection = nil
        activeCase = 0
        if display != .assembly { display = .setup }
    }

    /// Inserts the project's assembly (generated parts, the real components with their
    /// `component_ref`, the joints) into the design as one undo step, then shows it.
    func loadAssembly(into design: DesignModel, then: (@MainActor () -> Void)? = nil) {
        guard let url = project?.assembly, !loadingAssembly, !EngineGate.shared.shut else { return }
        loadingAssembly = true
        EngineGate.shared.holder = "Inserting the \(project?.name ?? "") assembly"
        let handle = SessionHandle(pointer: design.engine.session)
        let path = url.path
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, any Error> in
                Result { try GenerateEngine.assemble(path: path, into: handle) }
            }.value
            EngineGate.shared.holder = nil
            loadingAssembly = false
            switch result {
            case .success(let reply):
                assemblyLoaded = true
                joints = AssemblyJoint.read(url)
                design.refresh()
                design.setView(.iso)
                design.zoomToFit()
                display = .assembly
                let ok = (try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])?["ok"] as? [String: Any]
                design.flash("Assembly: \(ok?["parts"] as? Int ?? 0) parts, \(ok?["joints"] as? Int ?? 0) joints")
                then?()
            case .failure(let e):
                design.flash(e.localizedDescription, error: true)
                error = e.localizedDescription
            }
        }
    }

    /// Joint values asked for since the last drive reached the engine, by joint name.
    @ObservationIgnored private var pendingDrives: [String: Double] = [:]
    @ObservationIgnored private var driveFlush: Task<Void, Never>?
    @ObservationIgnored private var pendingRedraw = false

    /// Drives one joint of the inserted assembly (degrees), as the joint tool does. The value
    /// shows at once; the engine drive and the redraw are throttled to the display rate, so a
    /// slider or the grasp loop never queues one engine call per tick.
    func drive(_ name: String, to value: Double, design: DesignModel, redraw: Bool = true) {
        guard assemblyLoaded, !EngineGate.shared.shut, let i = joints.firstIndex(where: { $0.name == name }) else { return }
        let v = min(max(value, joints[i].limits.lowerBound), joints[i].limits.upperBound)
        joints[i].value = v
        pendingDrives[name] = v
        if redraw { pendingRedraw = true }
        scheduleDrives(design: design)
    }

    private func scheduleDrives(design: DesignModel) {
        guard driveFlush == nil else { return }
        driveFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            self?.flushDrives(design: design)
        }
    }

    /// Sends every pending joint value to the engine, then redraws once.
    func flushDrives(design: DesignModel) {
        driveFlush?.cancel()
        driveFlush = nil
        let drives = pendingDrives
        pendingDrives = [:]
        guard !drives.isEmpty, !EngineGate.shared.shut else { return }
        for (name, v) in drives.sorted(by: { $0.key < $1.key }) {
            do {
                _ = try design.engine.execute("joint.drive", ["joint": name, "values": [String(format: "%.3f deg", v)]])
            } catch {
                design.flash("\(name): \(error.localizedDescription)", error: true)
            }
        }
        if pendingRedraw { design.rebuildScene() } else { design.refresh() }
        pendingRedraw = false
    }

    /// Curls every finger and the thumb to the end of its flexion: a closed fist.
    func closeFist(design: DesignModel) { pose(design: design) { $0.fistValue } }

    /// Every joint back to its rest (zero, or the nearest end of its range).
    func openHand(design: DesignModel) { pose(design: design) { min(max(0, $0.limits.lowerBound), $0.limits.upperBound) } }

    /// The grasp test's drive: every movable joint between its rest (0) and its fist value (1).
    func grasp(_ closure: Double, design: DesignModel) {
        let c = min(max(closure, 0), 1)
        pose(design: design) { j in
            let rest = min(max(0, j.limits.lowerBound), j.limits.upperBound)
            return rest + c * (j.fistValue - rest)
        }
    }

    private func pose(design: DesignModel, _ value: (AssemblyJoint) -> Double) {
        for j in joints where j.movable { drive(j.name, to: value(j), design: design, redraw: false) }
    }

    /// Launch hooks for scripted runs and screenshots, through the same bridge as the panel:
    /// `--generate-build=<study.json>[,<study.json>…]` runs each study and builds its best
    /// candidate into the design; `--generate-assembly=<assembly.json>` inserts a generated
    /// assembly with its joints. With `VIAFORM_GENERATE_LOG` set, the replies go to that file.
    func launchHooks(design: DesignModel) {
        guard !hooksRan else { return }
        hooksRan = true
        let args = ProcessInfo.processInfo.arguments
        // The open project: `--generate-assembly` inserts its assembly (then `--generate-fist`
        // closes the hand), `--generate-insert` builds the run's best candidate into the design,
        // `--generate-pane=` and `--generate-display=` pick what shows.
        if let p = args.first(where: { $0.hasPrefix("--generate-pane=") })?.dropFirst(16), let pane = Pane.allCases.first(where: { $0.rawValue.lowercased() == p.lowercased() }) { self.pane = pane }
        let display = args.first(where: { $0.hasPrefix("--generate-display=") })?.dropFirst(19).lowercased()
        if args.contains("--generate-insert") {
            afterRun = { [weak self] in
                guard let self else { return }
                self.build(into: design)
                if display == "result" { self.display = .result }
            }
        }
        if project?.assembly != nil, args.contains("--generate-assembly") {
            let fist = args.contains("--generate-fist")
            loadAssembly(into: design) { [weak self] in
                guard let self else { return }
                if fist { self.closeFist(design: design) }
                if let d = display, let v = Display.allCases.first(where: { $0.rawValue.lowercased() == d }) { self.display = v }
                if let log = ProcessInfo.processInfo.environment["VIAFORM_GENERATE_LOG"] {
                    let text = self.joints.map { "\($0.name)\t\(String(format: "%.1f", $0.value))" }.joined(separator: "\n")
                    try? ("assembly \(self.project?.name ?? "")\nparts \(design.assembly.count)\n" + text).write(toFile: log, atomically: true, encoding: .utf8)
                }
            }
        } else if let d = display, let v = Display.allCases.first(where: { $0.rawValue.lowercased() == d }), v != .assembly {
            self.display = v
        }
        let builds = args.first { $0.hasPrefix("--generate-build=") }.map { $0.dropFirst(17).split(separator: ",").map(String.init) } ?? []
        let assembly = args.first { $0.hasPrefix("--generate-assembly=") }.map { String($0.dropFirst(20)) }
        guard !builds.isEmpty || assembly != nil, !EngineGate.shared.shut else { return }
        EngineGate.shared.holder = "Generating"
        let handle = SessionHandle(pointer: design.engine.session)
        let log = ProcessInfo.processInfo.environment["VIAFORM_GENERATE_LOG"]
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, any Error> in
                Result {
                    var replies: [String] = []
                    for path in builds {
                        replies.append(try GenerateEngine.buildRaw(try String(contentsOfFile: path, encoding: .utf8), into: handle))
                    }
                    if let assembly { replies.append(try GenerateEngine.assemble(path: assembly, into: handle)) }
                    return replies.joined(separator: "\n")
                }
            }.value
            EngineGate.shared.holder = nil
            let text: String
            switch result {
            case .success(let replies):
                text = replies
                design.refresh()
                design.zoomToFit()
                design.flash("Generated \(builds.count) studies\(assembly == nil ? "" : " and an assembly")")
            case .failure(let e):
                text = "error: \(e.localizedDescription)"
                design.flash(e.localizedDescription, error: true)
            }
            if let log { try? text.write(toFile: log, atomically: true, encoding: .utf8) }
        }
    }

    /// Builds the picked candidate into the design, then shows it. The engine reruns the study,
    /// so this owns the session in the background, with the gate shut.
    func build(into design: DesignModel) {
        guard let studied, let selected, !building, !EngineGate.shared.shut else { return }
        building = true
        EngineGate.shared.holder = "Building candidate \(selected + 1)"
        let handle = SessionHandle(pointer: design.engine.session)
        Task {
            let job = outcomeJob
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(body: String, commands: Int), any Error> in
                Result {
                    // The run that made the candidates holds them: no second run.
                    if let job { return try job.build(candidate: selected, into: handle) }
                    return try GenerateEngine.build(studied, candidate: selected, into: handle)
                }
            }.value
            EngineGate.shared.holder = nil
            building = false
            switch result {
            case .success(let built):
                design.refresh()
                design.zoomToFit()
                let mass = outcome?.candidates[safe: selected]?.massG ?? 0
                design.flash(String(localized: "Built \(built.body) from candidate \(selected + 1): \(VFFormat.mass(mass)) in \(built.commands) commands"))
            case .failure(let e):
                design.flash(e.localizedDescription, error: true)
            }
        }
    }

    // MARK: Estimate

    /// Element solves the study asks for: every iteration solves each load case on every
    /// element (three times over when robust: eroded, nominal, dilated), a frequency floor adds
    /// an eigen solve of its held modes each iteration, a mode costs about forty solves, an
    /// impact one per time step; variants add up.
    nonisolated static func workUnits(_ s: Study) -> Double {
        let n = Double(s.elementCount)
        let robust = s.robustDelta == nil ? 1.0 : 3.0
        let iterations = Double(s.iterations)
        let floor = s.minFrequency == nil ? 0 : iterations * Double(max(s.frequencyModes, 1)) * 8
        let perVariant = iterations * Double(max(s.cases.count, 1)) * robust + floor + Double(s.dynamics.modes) * 40
            + s.dynamics.impacts.reduce(0) { $0 + Double($1.steps) }
        return n * perVariant * Double(max(s.variants, 1))
    }

    /// Seconds every run spends whatever its size: starting the engine, surfacing each
    /// candidate and building its preview.
    nonisolated static func overhead(_ s: Study) -> Double {
        1.5 + Double(s.elementCount) * 4e-6 * Double(max(s.variants, 1))
    }

    private nonisolated static let calibrationKey = "generate.secondsPerElementSolve"

    /// Seconds per element solve on this machine, learnt from past runs.
    nonisolated static var secondsPerUnit: Double {
        let v = UserDefaults.standard.double(forKey: calibrationKey)
        return v > 0 ? v : 4e-7
    }

    /// Seconds the study should take: never less than three, a run is never instant.
    nonisolated static func estimate(_ s: Study) -> Double { max(3, overhead(s) + workUnits(s) * secondsPerUnit) }

    private static func calibrate(seconds: Double, units: Double, overhead: Double) {
        let solving = seconds - overhead
        guard solving > 0.2, units > 0 else { return }
        let measured = min(max(solving / units, 1e-10), 1e-4)
        UserDefaults.standard.set(0.5 * secondsPerUnit + 0.5 * measured, forKey: calibrationKey)
    }

    // MARK: Regions

    func region(_ key: RegionKey) -> StudyRegion? {
        switch key {
        case .support(let id): study.supports.first { $0.id == id }?.region
        case .load(let id): load(id).map { study.cases[$0.0].loads[$0.1].region }
        case .keepOut(let id): study.keepOut.first { $0.id == id }?.region
        case .keepIn(let id): study.keepIn.first { $0.id == id }?.region
        }
    }

    func setRegion(_ key: RegionKey, _ r: StudyRegion) {
        switch key {
        case .support(let id):
            if let i = study.supports.firstIndex(where: { $0.id == id }) { study.supports[i].region = r }
        case .load(let id):
            if let (c, l) = load(id) { study.cases[c].loads[l].region = r }
        case .keepOut(let id):
            if let i = study.keepOut.firstIndex(where: { $0.id == id }) { study.keepOut[i].region = r }
        case .keepIn(let id):
            if let i = study.keepIn.firstIndex(where: { $0.id == id }) { study.keepIn[i].region = r }
        }
    }

    /// Case and position of a load.
    func load(_ id: UUID) -> (Int, Int)? {
        for (c, lc) in study.cases.enumerated() {
            if let l = lc.loads.firstIndex(where: { $0.id == id }) { return (c, l) }
        }
        return nil
    }

    /// What a region is called in undo names and toasts.
    static func kindName(_ key: RegionKey) -> String {
        switch key {
        case .support: String(localized: "Support")
        case .load: String(localized: "Load")
        case .keepOut: String(localized: "Keep-Out")
        case .keepIn: String(localized: "Keep-In")
        }
    }

    /// Removes a region as one undo step named after it.
    func remove(_ key: RegionKey) {
        named(String(localized: "Remove \(Self.kindName(key))")) {
            switch key {
            case .support(let id): study.supports.removeAll { $0.id == id }
            case .load(let id): if let (c, l) = load(id) { study.cases[c].loads.remove(at: l) }
            case .keepOut(let id): study.keepOut.removeAll { $0.id == id }
            case .keepIn(let id): study.keepIn.removeAll { $0.id == id }
            }
        }
        if selection == key { selection = nil }
    }

    /// Removes an impact as one undo step.
    func removeImpact(_ id: UUID) {
        named(String(localized: "Remove Impact")) { study.dynamics.impacts.removeAll { $0.id == id } }
    }

    func addImpact() {
        named(String(localized: "Add Impact")) {
            study.dynamics.impacts.append(StudyImpact(caseIndex: min(activeCase, max(study.cases.count - 1, 0))))
        }
    }

    /// Picks a region, and the case its load belongs to.
    func select(_ key: RegionKey?) {
        selection = key
        if case .load(let id)? = key, let (c, _) = load(id) { activeCase = c }
        if key != nil { pane = .regions }
    }

    /// A drag in the preview starts moving `key`.
    func beginMove(_ key: RegionKey) {
        guard let r = region(key) else { return }
        // The whole drag is one undo step (dropped again when nothing moved).
        undoStack.append(UndoStep(study: study, name: String(localized: "Move \(Self.kindName(key))")))
        grouping = true
        var center = Vec3.zero
        if case .load(let id) = key, let (c, l) = load(id) { center = study.cases[c].loads[l].center }
        moving = (key, r, center)
        select(key)
    }

    /// Moves the region being dragged by `d` from where it started (snapped to the millimetre);
    /// a torque's centre moves with its region.
    func move(by d: Vec3) {
        guard let m = moving else { return }
        let step = study.voxel >= 1 ? 1.0 : 0.1
        let snapped = (d / step).rounded(.toNearestOrEven) * step
        setRegion(m.key, m.region.translated(snapped))
        if case .load(let id) = m.key, let (c, l) = load(id) { study.cases[c].loads[l].center = m.center + snapped }
    }

    func endMove() {
        moving = nil
        if grouping, undoStack.last?.study == study { undoStack.removeLast() }
        grouping = false
        lastEdit = .distantPast
    }

    // MARK: Adding

    /// A region a tenth of the design space, at its centre.
    private var smallBox: StudyRegion {
        let mid = (study.min + study.max) / 2, half = study.size / 10
        return .box(mid - half, mid + half)
    }

    func addSupport() {
        let lo = simd_min(study.min, study.max), hi = simd_max(study.min, study.max)
        let s = StudySupport(region: .box(lo, Vec3(lo.x + max(study.voxel, 1), hi.y, hi.z)))
        named(String(localized: "Add Support")) { study.supports.append(s) }
        select(.support(s.id))
    }

    func addLoad(_ kind: StudyLoad.Kind) {
        if study.cases.isEmpty { study.cases = [StudyLoadCase(name: String(localized: "Case 1"))] }
        let c = min(max(activeCase, 0), study.cases.count - 1)
        let r = smallBox
        let load: StudyLoad
        switch kind {
        case .force: load = .force(r, Vec3(0, 0, -100))
        case .torque: load = .torque(r, center: r.middle, axis: Vec3(0, 0, 1), moment: 1000)
        case .pressure: load = .pressure(r, direction: Vec3(0, 0, -1), pressure: 0.1)
        }
        named(String(localized: "Add Load")) { study.cases[c].loads.append(load) }
        select(.load(load.id))
    }

    func addCase() {
        named(String(localized: "Add Load Case")) { study.cases.append(StudyLoadCase(name: String(localized: "Case \(study.cases.count + 1)"))) }
        activeCase = study.cases.count - 1
    }

    func removeCase(_ i: Int) {
        guard study.cases.indices.contains(i), study.cases.count > 1 else { return }
        var s = study
        s.cases.remove(at: i)
        s.dynamics.impacts.removeAll { $0.caseIndex == i }
        for k in s.dynamics.impacts.indices where s.dynamics.impacts[k].caseIndex > i { s.dynamics.impacts[k].caseIndex -= 1 }
        named(String(localized: "Remove Load Case")) { study = s }
        activeCase = min(activeCase, study.cases.count - 1)
        if case .load(let id)? = selection, load(id) == nil { selection = nil }
    }

    func addKeepOut() {
        let k = Study.Keyed(smallBox)
        named(String(localized: "Add Keep-Out")) { study.keepOut.append(k) }
        select(.keepOut(k.id))
    }

    func addKeepIn() {
        let k = Study.Keyed(smallBox)
        named(String(localized: "Add Keep-In")) { study.keepIn.append(k) }
        select(.keepIn(k.id))
    }

    // MARK: Templates

    /// A study set up for one of the classic parts, world mm, z up.
    static func study(_ t: Template) -> Study {
        var s = Study()
        switch t {
        case .cantilever:
            s.name = "Cantilever"
            s.min = Vec3(0, 0, 0)
            s.max = Vec3(120, 30, 40)
            s.voxel = 2
            s.supports = [StudySupport(region: .box(Vec3(0, 0, 0), Vec3(2, 30, 40)))]
            s.cases = [StudyLoadCase(name: "Tip load", loads: [.force(.box(Vec3(116, 11, 0), Vec3(120, 19, 4)), Vec3(0, 0, -1000))])]
            s.volumeFraction = 0.15
            s.symmetry = [false, true, false]
            s.variants = 3
        case .bracket:
            s.name = "Bracket"
            s.min = Vec3(0, 0, 0)
            s.max = Vec3(80, 40, 80)
            s.voxel = 2
            s.supports = [10.0, 30.0].map { y in
                StudySupport(region: .cylinder(base: Vec3(0, y, 70), axis: Vec3(1, 0, 0), radius: 4, length: 4))
            }
            let bore = StudyRegion.cylinder(base: Vec3(70, 0, 12), axis: Vec3(0, 1, 0), radius: 6, length: 40)
            s.cases = [
                StudyLoadCase(name: "Hanging load", loads: [.force(bore, Vec3(0, 0, -1500))]),
                StudyLoadCase(name: "Side push", loads: [.force(bore, Vec3(0, 400, 0))], weight: 0.5),
            ]
            s.keepOut = [Study.Keyed(.box(Vec3(24, 0, 30), Vec3(80, 40, 80)))]
            s.keepIn = [Study.Keyed(.cylinder(base: Vec3(70, 0, 12), axis: Vec3(0, 1, 0), radius: 9, length: 40))]
            s.volumeFraction = 0.2
            s.symmetry = [false, true, false]
            s.variants = 3
        case .motorMount:
            s.name = "Motor mount"
            s.min = Vec3(0, 0, 0)
            s.max = Vec3(80, 80, 16)
            s.voxel = 1.6
            let corners = [Vec3(8, 8, 0), Vec3(72, 8, 0), Vec3(8, 72, 0), Vec3(72, 72, 0)]
            s.supports = corners.map { StudySupport(region: .cylinder(base: $0, axis: Vec3(0, 0, 1), radius: 3.5, length: 16)) }
            let hub = StudyRegion.cylinder(base: Vec3(40, 40, 0), axis: Vec3(0, 0, 1), radius: 16, length: 16)
            s.cases = [StudyLoadCase(name: "Drive", loads: [
                .torque(hub, center: Vec3(40, 40, 8), axis: Vec3(0, 0, 1), moment: 3000),
                .force(hub, Vec3(0, 0, -150)),
            ])]
            s.keepIn = [Study.Keyed(hub)] + corners.map { Study.Keyed(.cylinder(base: $0, axis: Vec3(0, 0, 1), radius: 6, length: 16)) }
            s.manufacturing = StudyManufacturing(process: .milling, direction: Vec3(0, 0, 1))
            s.volumeFraction = 0.25
            s.dynamics.modes = 4
            s.variants = 2
        case .bridge:
            s.name = "Bridge"
            s.min = Vec3(0, 0, 0)
            s.max = Vec3(200, 40, 50)
            s.voxel = 2.5
            s.material = StudyMaterial.presets[2]
            s.supports = [
                StudySupport(region: .box(Vec3(0, 0, 0), Vec3(8, 40, 4))),
                StudySupport(region: .box(Vec3(192, 0, 0), Vec3(200, 40, 4)), fix: [false, true, true]),
            ]
            let deck = StudyRegion.box(Vec3(0, 0, 46), Vec3(200, 40, 50))
            s.cases = [
                StudyLoadCase(name: "Deck", loads: [.pressure(deck, direction: Vec3(0, 0, -1), pressure: 0.2)]),
                StudyLoadCase(name: "Self weight", acceleration: Vec3(0, 0, -9810), weight: 0.2),
            ]
            s.keepIn = [Study.Keyed(deck)]
            s.symmetry = [true, true, false]
            s.volumeFraction = 0.15
            s.dynamics = StudyDynamics(modes: 3, impacts: [StudyImpact(caseIndex: 0, duration: 0.004, window: 0.02, steps: 200, damping: 0.02)])
            s.variants = 2
        }
        return s
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Seconds as people read them: "8 s", "2 min 10 s", "1 h 5 min".
func readableDuration(_ s: Double) -> String {
    guard s.isFinite else { return "–" }
    if s < 1 { return "under 1 s" }
    if s < 60 { return "\(Int(s.rounded())) s" }
    let m = Int(s / 60)
    if m < 60 { return "\(m) min \(Int(s) % 60) s" }
    return "\(m / 60) h \(m % 60) min"
}
