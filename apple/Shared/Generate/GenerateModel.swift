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

    var study = GenerateModel.study(.cantilever)
    var display = Display.setup
    var pane = Pane.study
    var selection: RegionKey?
    /// The load case the regions pane edits; its loads draw in full colour.
    var activeCase = 0
    private(set) var outcome: StudyOutcome?
    /// The study the candidates came from: building reruns exactly that one.
    private(set) var studied: Study?
    /// Preview geometry per candidate, built off the main actor with the outcome.
    private(set) var previews: [PreviewMesh] = []
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

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let name = GenerateProject.launchSample { openSample(name) }
        if let pick = args.first(where: { $0.hasPrefix("--generate-study=") })?.dropFirst(17), let e = project?.studies.first(where: { $0.name == pick }) { load(e) }
        if args.contains("--generate-run") { run() }
        // `--generate-explore`: run the default variants at once, then push the lightest
        // feasible one (else the first) to the results.
        if args.contains("--generate-explore") {
            pane = .variants
            explore()
        }
    }

    /// The setup changed since the candidates were made.
    var stale: Bool { outcome != nil && studied != study && pickedVariant == nil }

    var candidate: StudyCandidate? {
        guard let o = outcome, let s = selected, o.candidates.indices.contains(s) else { return nil }
        return o.candidates[s]
    }

    func apply(_ t: Template) {
        let material = study.material
        study = Self.study(t)
        if t != .bridge { study.material = material }
        selection = nil
        activeCase = 0
        display = .setup
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

    /// Runs the study in the engine on its own thread, following its iterations; Cancel stops
    /// it at the next one.
    func run() {
        let study = study
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
            self.running = false
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
                if o.candidates.isEmpty { self.error = "The study gave no candidates" }
                Self.calibrate(seconds: o.seconds > 0 ? o.seconds : Date().timeIntervalSince(self.startedAt ?? Date()), units: units, overhead: overhead)
                self.afterRun?()
                self.afterRun = nil
            case .failure(let e):
                if e.localizedDescription == "cancelled" { self.notice = "Cancelled" } else { self.error = e.localizedDescription }
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

    /// Holds the running study after its current iteration, or lets it go on.
    func togglePause() {
        guard running, let job = runningJob else { return }
        paused.toggle()
        job.setPaused(paused)
    }

    /// Stops the running study: the engine stops at its next iteration and its answer is dropped.
    func cancel() {
        guard running else { return }
        runningJob?.cancel()
        runningJob = nil
        runID += 1
        running = false
        paused = false
        notice = "Cancelled"
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

    /// Opens `docs/generative/<name>` and loads its first study.
    func openSample(_ name: String) {
        do {
            let p = try GenerateProject.open(name)
            project = p
            assemblyLoaded = false
            joints = p.assembly.map(AssemblyJoint.read) ?? []
            assemblySummary = p.assembly.map(AssemblyJoint.summary)
            pane = .project
            if let first = p.firstStudy { load(first) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Makes a project study the setup.
    func load(_ e: GenerateProject.Entry) {
        guard !running else { return }
        study = e.study
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

    /// Drives one joint of the inserted assembly (degrees), as the joint tool does.
    func drive(_ name: String, to value: Double, design: DesignModel, redraw: Bool = true) {
        guard assemblyLoaded, !EngineGate.shared.shut, let i = joints.firstIndex(where: { $0.name == name }) else { return }
        let v = min(max(value, joints[i].limits.lowerBound), joints[i].limits.upperBound)
        joints[i].value = v
        do {
            _ = try design.engine.execute("joint.drive", ["joint": name, "values": [String(format: "%.3f deg", v)]])
        } catch {
            design.flash("\(name): \(error.localizedDescription)", error: true)
        }
        if redraw { design.rebuildScene() }
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
        design.refresh()
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
                design.flash(String(format: "Built %@ from candidate %d: %.1f g in %d commands", built.body, selected + 1, mass, built.commands))
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

    func remove(_ key: RegionKey) {
        switch key {
        case .support(let id): study.supports.removeAll { $0.id == id }
        case .load(let id): if let (c, l) = load(id) { study.cases[c].loads.remove(at: l) }
        case .keepOut(let id): study.keepOut.removeAll { $0.id == id }
        case .keepIn(let id): study.keepIn.removeAll { $0.id == id }
        }
        if selection == key { selection = nil }
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

    func endMove() { moving = nil }

    // MARK: Adding

    /// A region a tenth of the design space, at its centre.
    private var smallBox: StudyRegion {
        let mid = (study.min + study.max) / 2, half = study.size / 10
        return .box(mid - half, mid + half)
    }

    func addSupport() {
        let lo = simd_min(study.min, study.max), hi = simd_max(study.min, study.max)
        let s = StudySupport(region: .box(lo, Vec3(lo.x + max(study.voxel, 1), hi.y, hi.z)))
        study.supports.append(s)
        select(.support(s.id))
    }

    func addLoad(_ kind: StudyLoad.Kind) {
        if study.cases.isEmpty { study.cases = [StudyLoadCase(name: "Case 1")] }
        let c = min(max(activeCase, 0), study.cases.count - 1)
        let r = smallBox
        let load: StudyLoad
        switch kind {
        case .force: load = .force(r, Vec3(0, 0, -100))
        case .torque: load = .torque(r, center: r.middle, axis: Vec3(0, 0, 1), moment: 1000)
        case .pressure: load = .pressure(r, direction: Vec3(0, 0, -1), pressure: 0.1)
        }
        study.cases[c].loads.append(load)
        select(.load(load.id))
    }

    func addCase() {
        study.cases.append(StudyLoadCase(name: "Case \(study.cases.count + 1)"))
        activeCase = study.cases.count - 1
    }

    func removeCase(_ i: Int) {
        guard study.cases.indices.contains(i), study.cases.count > 1 else { return }
        study.cases.remove(at: i)
        study.dynamics.impacts.removeAll { $0.caseIndex == i }
        for k in study.dynamics.impacts.indices where study.dynamics.impacts[k].caseIndex > i { study.dynamics.impacts[k].caseIndex -= 1 }
        activeCase = min(activeCase, study.cases.count - 1)
        if case .load(let id)? = selection, load(id) == nil { selection = nil }
    }

    func addKeepOut() {
        let k = Study.Keyed(smallBox)
        study.keepOut.append(k)
        select(.keepOut(k.id))
    }

    func addKeepIn() {
        let k = Study.Keyed(smallBox)
        study.keepIn.append(k)
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
