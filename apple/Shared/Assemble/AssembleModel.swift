import Foundation
import Observation
import simd

/// The Assemble stage (VIAFORM-SPEC 7.3): the product's physical model (`assembly.json`) with
/// its joints, drives, mass properties, interference and motion studies, plus the kinematic
/// tools on top of it: the end effector drag (7.10.4) and the hand grasp editor (7.10.5).
///
/// The document lives in the Rust assembly engine (`vf_asm_*`); the kinematic model is built
/// from it once per document change (`kin_model`) and loaded into `vf_kin_*`. Joint values are
/// degrees (mm for sliders) here and in the document, radians inside kin.
///
/// Used on the main thread only (the views, the canvas and the drag); `@unchecked Sendable` so
/// the playback timer and the study task can hold it.
@Observable
final class AssembleModel: @unchecked Sendable {
    enum Product: String { case none, arm, hand }

    /// The ribbon tabs of the Assemble stage.
    enum Tab: String, CaseIterable, Identifiable {
        case assembly = "ASSEMBLY", joints = "JOINTS", motion = "MOTION", check = "CHECK"
        var id: String { rawValue }
        /// The tab's name (the ribbon shows it in capitals).
        var title: String {
            switch self {
            case .assembly: String(localized: "Assembly")
            case .joints: String(localized: "Joints")
            case .motion: String(localized: "Motion")
            case .check: String(localized: "Check")
            }
        }
    }

    /// What a drag on the canvas does.
    enum Tool: String { case select, rotateJoint, dragTip, grasp }

    enum Posture: String, CaseIterable, Identifiable {
        case current = "Nearest", midRange = "Mid range"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .current: String(localized: "Nearest")
            case .midRange: String(localized: "Mid range")
            }
        }
    }

    struct IKState: Equatable {
        /// Target of the tool frame, mm and degrees (roll, pitch, yaw), world frame.
        var target = SIMD3<Double>(0, 0, 0)
        var rpy = SIMD3<Double>(0, 0, 0)
        var solver = "Numerical"
        var reached = true
        /// How far the tip stops short of the target, mm (0 when reached).
        var shortBy = 0.0
        var keepOrientation = false
        var posture = Posture.current
        var locked: Set<String> = []
        var dragging = false
    }

    struct GraspFinger: Identifiable, Equatable {
        var id: String { frame }
        var frame: String
        var title: String
        var priority: Int
        /// Target on the object surface and its outward normal, mm, world.
        var point: SIMD3<Double>
        var normal: SIMD3<Double>
        var reached = false
        var distanceMM = 0.0
        var drive = "Motor"
        var joints: [Double] = []
    }

    struct GraspState: Equatable {
        var shape = "cylinder"
        /// Cylinder: diameter, height; box: x, y, z; sphere: diameter. mm.
        var size = SIMD3<Double>(40, 120, 0)
        var center = SIMD3<Double>(0, 0, 0)
        var axis = SIMD3<Double>(0, 0, 1)
        var fingers: [GraspFinger] = []
        var actuators: [(name: String, value: Double, tendon: Bool)] = []
        var savedID: String?
        static func == (a: Self, b: Self) -> Bool { a.fingers == b.fingers && a.size == b.size && a.shape == b.shape && a.savedID == b.savedID }
    }

    // MARK: State

    private(set) var product = Product.none
    private(set) var doc: AsmDocument?
    /// Joint values now, by joint id (deg or mm).
    private(set) var q: [String: Double] = [:]
    var selectedJoint: String?
    var tab = Tab.joints
    var tool = Tool.select { didSet { if tool != oldValue { toolChanged() } } }
    /// Folders closed in the browser outline (kept across stage switches).
    var outlineClosed: Set<String> = []
    private(set) var mass: AsmMassProps?
    /// nil until the check ran on this pose.
    private(set) var interference: [AsmInterference]?
    private(set) var studies: [(id: String, title: String)] = []
    private(set) var study: AsmMotionStudy?
    var studyID = "" { didSet { if studyID != oldValue { runStudy() } } }
    private(set) var playhead = 0.0
    private(set) var playing = false
    var ik = IKState()
    var grasp = GraspState()
    private(set) var error: String?
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// Names of the steps the engine can undo and redo, newest last ("Save Pose"). Only steps
    /// made from this screen are named; older ones (the template) read as a plain "Undo".
    private var undoNames: [String] = []
    private var redoNames: [String] = []
    /// "Save Pose": the menu reads "Undo Save Pose". nil when the step has no name.
    var undoName: String? { canUndo ? undoNames.last : nil }
    var redoName: String? { canRedo ? redoNames.last : nil }
    /// Fraction of the motion study sampled so far; nil when no study is being sampled.
    private(set) var studyProgress: Double?
    /// The last failed action that can be tried again (the error banner's Try Again).
    @ObservationIgnored private(set) var retry: (() -> Void)?
    /// The flow revision the last commit recorded ("Assembly v2").
    private(set) var committed: String?
    /// Bumped when the document (components, joints) changes: the canvas rebuilds its nodes.
    private(set) var documentRevision = 0
    /// Bumped when the pose changes outside a drag: the canvas moves its nodes.
    private(set) var poseRevision = 0
    /// Component poses (mm, world) for the canvas, by component id.
    @ObservationIgnored private(set) var poses: [String: simd_float4x4] = [:]

    @ObservationIgnored let engine = AssembleEngine()
    /// kin's links (component ids) and joints (asm joint ids), in kin order.
    @ObservationIgnored private(set) var kinLinks: [String] = []
    @ObservationIgnored private(set) var kinJoints: [String] = []
    /// Each kin link's world pose at the home pose (mm), inverted: comp = link(q) * homeInverse.
    @ObservationIgnored private var homeInverse: [simd_float4x4] = []
    @ObservationIgnored private(set) var toolComponent = ""
    /// Hand bones: the points each bone reaches at home (mm), drawn as capsules.
    @ObservationIgnored private(set) var boneTips: [String: [SIMD3<Double>]] = [:]
    @ObservationIgnored private(set) var tipHomeMM = SIMD3<Double>(0, 0, 0)
    /// The canvas the drag writes to directly (60 fps, no SwiftUI on the way).
    @ObservationIgnored weak var sink: AssemblePoseSink?
    @ObservationIgnored private var dragQ: [Double] = []
    @ObservationIgnored private var dragLinks: [Float] = []
    @ObservationIgnored private var lastPublish = 0.0
    @ObservationIgnored private var player: Timer?
    @ObservationIgnored private var flow: FlowModel?
    /// The saved pose each motion study starts from (the other joints stay there).
    @ObservationIgnored private var studyPose: [String: String] = [:]
    @ObservationIgnored private var studyTask: Task<Void, Never>?
    /// A scrub or a play asked for while the study was still being sampled.
    @ObservationIgnored private var pendingScrub: Double?
    @ObservationIgnored private var playWhenReady = false

    var isActive: Bool { product != .none && doc != nil }
    var joints: [AsmJoint] { doc?.joints ?? [] }
    var components: [AsmComponent] { doc?.components ?? [] }
    var selected: AsmJoint? { joints.first { $0.id == selectedJoint } }
    var dof: Int { joints.filter { $0.kind != "fixed" }.count }
    /// Work the stage is doing that Stop (Command-.) can end: sampling a motion study.
    var isBusy: Bool { studyProgress != nil }

    /// Stops the running work (Command-., the Stop button). Never bound to Esc.
    func stopWork() { cancelStudy() }

    // MARK: Open

    /// Opens the template arm: six STS3215 joints, BOM lines, saved poses; posed at "ready".
    func openArm(flow: FlowModel?) {
        self.flow = flow
        do {
            cancelStudy()
            try engine.call("template", ["name": "arm"])
            // A stowed pose and a second study from it: the wrist folds the gripper back onto
            // the shoulder near the top of its range.
            try engine.call("save_pose", ["id": "tuck", "q_deg": ["shoulder_pan": 0, "shoulder_lift": -30, "elbow": 135,
                                                                  "wrist_pitch": 0, "wrist_roll": 0, "gripper": 0]])
            try engine.call("add_study", ["study": ["id": "wrist_sweep", "joint": "wrist_pitch", "steps": 40,
                                                    "pose": "tuck", "duration_s": 3.0]])
            product = .arm
            undoNames = []
            redoNames = []
            try reloadDocument()
            if let ready = doc?.poses?.first(where: { $0.id == "ready" }) { try drive(ready.q_deg) }
            selectedJoint = "elbow"
            studyID = "elbow_sweep"
            computeMass()
            commit()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The hand product: the five-finger kinematic hand (kin `hand5`, tendons and couplings) as
    /// an assembly of bones, for the grasp editor.
    func openHand(flow: FlowModel?) {
        self.flow = flow
        cancelStudy()
        do {
            try engine.kinCall("model.load", ["builtin": "hand5"])
            let built = try HandAssembly.build(engine)
            guard engine.open(json: built.json) else { throw AssembleError("the hand assembly does not read") }
            kinLinks = built.links
            kinJoints = built.joints
            boneTips = built.tips
            product = .hand
            undoNames = []
            redoNames = []
            try reloadDocument(kinBuiltin: true)
            tab = .motion
            tool = .grasp
            computeMass()
            commit()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func close() {
        stop()
        cancelStudy()
        undoNames = []
        redoNames = []
        product = .none
        doc = nil
        q = [:]
        poses = [:]
        documentRevision += 1
    }

    /// Reads the document back and rebuilds the kinematic model from it.
    private func reloadDocument(kinBuiltin: Bool = false) throws {
        let r = try engine.call("get")
        doc = AssembleEngine.decode(AsmDocument.self, r["assembly"])
        if let state = r["state"] as? [String: Any] { applyState(state) }
        studies = ((r["assembly"] as? [String: Any])?["motion_studies"] as? [[String: Any]] ?? []).compactMap { s in
            guard let id = s["id"] as? String, let j = s["joint"] as? String else { return nil }
            studyPose[id] = s["pose"] as? String ?? "home"
            let joint = j.replacingOccurrences(of: "_", with: " ")
            let pose = studyPose[id] ?? "home"
            return (id, pose == "home" ? String(localized: "Sweep \(joint)")
                                       : String(localized: "Sweep \(joint) from \(pose.replacingOccurrences(of: "_", with: " "))"))
        }
        if product == .arm, !studies.contains(where: { $0.id == Self.poseStudy }) { studies.append((Self.poseStudy, String(localized: "Home to ready"))) }
        if !kinBuiltin {
            let k = try engine.call("kin_model")
            try engine.kinCall("model.load", ["model": k["model"] ?? [:]])
            kinLinks = k["links"] as? [String] ?? []
            kinJoints = k["joints"] as? [String] ?? []
            let tool = k["tool"] as? [String: Any]
            toolComponent = tool?["component"] as? String ?? ""
            let tip = tool?["tip_mm"] as? [Double] ?? [0, 0, 0]
            tipHomeMM = SIMD3(tip[0], tip[1], tip[2])
        }
        let zero = Array(repeating: 0.0, count: kinJoints.count)
        let fk = try engine.kinCall("fk", ["q": zero])
        homeInverse = (fk["links"] as? [[String: Any]] ?? []).map { simd_inverse(Self.matrix(pose: $0)) }
        ik.solver = ((try? engine.kinCall("model.info"))?["frames"] as? [[String: Any]])?.first(where: { ($0["name"] as? String) == "tool" })?["analytic"] as? Bool == true ? "Analytic" : "Numerical"
        documentRevision += 1
        refreshUndo()
        syncTip()
    }

    private func applyState(_ state: [String: Any]) {
        if let qd = state["q"] as? [String: Double] { q = qd }
        if let list = AssembleEngine.decode([AsmComponentPose].self, state["poses"]) {
            poses = Dictionary(list.map { ($0.component, $0.simd) }, uniquingKeysWith: { a, _ in a })
        }
        poseRevision += 1
    }

    private func refreshUndo() {
        let r = try? engine.call("get")
        let s = r?["state"] as? [String: Any]
        canUndo = s?["can_undo"] as? Bool ?? false
        canRedo = s?["can_redo"] as? Bool ?? false
    }

    // MARK: Joints

    /// Drives joints to values (deg or mm), held at their limits.
    func drive(_ values: [String: Double]) throws {
        let r = try engine.call("drive", ["q": values])
        if let s = r["state"] as? [String: Any] { applyState(s) }
        interference = nil
        syncTip()
    }

    /// Joint drag and the inspector slider: one joint to a value, live.
    func setJoint(_ id: String, value: Double) {
        do {
            try drive([id: value])
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Edits a joint's fields (limits, motor, damping, friction): one undo step, then commit.
    func editJoint(_ id: String, _ patch: [String: Any]) {
        var p = patch
        p["id"] = id
        let name: String = if patch["limits"] != nil { String(localized: "Change Limits") }
            else if patch["motor"] != nil { String(localized: "Edit Motor") }
            else if patch["damping"] != nil { String(localized: "Change Damping") }
            else if patch["friction"] != nil { String(localized: "Change Friction") }
            else { String(localized: "Edit Joint") }
        let before = doc
        do {
            try engine.call("set_joint", p)
            try reloadDocument()
            recordStep(name, changed: doc != before)
            computeMass()
            commit()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func limitState(_ j: AsmJoint) -> LimitState {
        guard let r = j.range, let v = q[j.id] else { return .free }
        let span = max(r.upperBound - r.lowerBound, 1e-6)
        let edge = min(v - r.lowerBound, r.upperBound - v)
        if edge <= 0.5 { return .at }
        if edge <= max(span * 0.06, 4) { return .near }
        return .free
    }

    enum LimitState { case free, near, at }

    func pose(named id: String) {
        guard let p = doc?.poses?.first(where: { $0.id == id }) else { return }
        do { try drive(p.q_deg) } catch { self.error = error.localizedDescription }
    }

    /// "Save pose": the current values as a named pose (`asm.save_pose`), one undo step.
    @discardableResult
    func savePose(_ name: String? = nil) -> String? {
        let n = (doc?.poses?.count ?? 0) + 1
        let id = name ?? "pose_\(n)"
        let before = doc
        do {
            try engine.call("save_pose", ["id": id])
            try reloadDocument()
            recordStep(String(localized: "Save Pose"), changed: doc != before)
            commit()
            return id
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func undo() { step("undo") }
    func redo() { step("redo") }

    /// A named step went into the engine's undo stack (only when the document changed).
    private func recordStep(_ name: String, changed: Bool) {
        guard changed else { return }
        undoNames.append(name)
        redoNames = []
        refreshUndo()
    }

    private func step(_ op: String) {
        do {
            try engine.call(op)
            if op == "undo" {
                if let n = undoNames.popLast() { redoNames.append(n) }
            } else if let n = redoNames.popLast() {
                undoNames.append(n)
            }
            try reloadDocument()
            computeMass()
            commit()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Checks

    func computeMass() {
        do {
            let r = try engine.call("mass_props")
            let t = r["total"] as? [String: Any] ?? [:]
            let com = t["center_of_mass_mm"] as? [Double] ?? [0, 0, 0]
            let rows = (r["components"] as? [[String: Any]] ?? []).map { ($0["component"] as? String ?? "", $0["mass_kg"] as? Double ?? 0) }
            mass = AsmMassProps(totalKg: t["mass_kg"] as? Double ?? 0, comMM: SIMD3(com[0], com[1], com[2]),
                                inertia: t["inertia_kg_mm2"] as? [Double] ?? [], boughtKg: r["bought_mass_kg"] as? Double ?? 0,
                                perComponent: rows.map { (id: $0.0, kg: $0.1) },
                                warnings: (r["warnings"] as? [Any] ?? []).map { "\($0)" })
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Interference at the current pose; pairs drawn on the canvas.
    func checkInterference() {
        do {
            let r = try engine.call("interference", ["include_adjacent": false])
            interference = (r["pairs"] as? [[String: Any]] ?? []).map(Self.pair)
            poseRevision += 1
        } catch {
            fail(error, retry: { [weak self] in self?.checkInterference() })
        }
    }

    private static func pair(_ h: [String: Any]) -> AsmInterference {
        let region = h["region"] as? [String: Any]
        let lo = region?["min"] as? [Double] ?? [0, 0, 0], hi = region?["max"] as? [Double] ?? [0, 0, 0]
        return AsmInterference(a: h["a"] as? String ?? "", b: h["b"] as? String ?? "", volumeMM3: h["volume_mm3"] as? Double ?? 0,
                               regionMin: SIMD3(lo[0], lo[1], lo[2]), regionMax: SIMD3(hi[0], hi[1], hi[2]))
    }

    // MARK: Motion study

    static let poseStudy = "home_to_ready"

    /// Samples the selected study. A sweep is one engine call; the pose-to-pose study samples
    /// step by step off the event path, with progress and Stop (`stopWork`).
    func runStudy(thenPlay: Bool = false) {
        stop()
        cancelStudy()
        guard isActive, !studyID.isEmpty else { study = nil; return }
        playWhenReady = thenPlay
        let id = studyID
        guard id == Self.poseStudy else {
            do {
                study = try sweep(id)
                playhead = 0
                studyReady()
            } catch {
                study = nil
                fail(error, retry: { [weak self] in self?.runStudy(thenPlay: thenPlay) })
            }
            return
        }
        study = nil
        studyProgress = 0
        studyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let s = try await self.poseToPose(from: "home", to: "ready", steps: 40, duration: 4)
                guard !Task.isCancelled, self.studyID == id else { return }
                self.study = s
                self.playhead = 0
                self.studyProgress = nil
                self.studyTask = nil
                self.studyReady()
            } catch is CancellationError {
                return
            } catch {
                self.studyProgress = nil
                self.studyTask = nil
                self.study = nil
                self.fail(error, retry: { [weak self] in self?.runStudy(thenPlay: thenPlay) })
            }
        }
    }

    /// Stops sampling the study (the study stays empty until it runs again).
    func cancelStudy() {
        studyTask?.cancel()
        studyTask = nil
        if studyProgress != nil { studyProgress = nil }
        pendingScrub = nil
        playWhenReady = false
    }

    private func studyReady() {
        if let t = pendingScrub { pendingScrub = nil; scrub(to: t) }
        if playWhenReady { playWhenReady = false; play() }
    }

    private func sweep(_ id: String) throws -> AsmMotionStudy {
        let r = try engine.call("motion_study", ["study": id])
        let joint = r["joint"] as? String ?? ""
        let raw = r["steps"] as? [[String: Any]] ?? []
        let n = max(raw.count - 1, 1)
        var base = q
        let poseID = studyPose[id] ?? "home"
        if let p = doc?.poses?.first(where: { $0.id == poseID }) { base = p.q_deg }
        let steps: [AsmMotionStudy.Step] = raw.enumerated().map { i, s in
            var qs = Dictionary(uniqueKeysWithValues: joints.map { ($0.id, base[$0.id] ?? 0) })
            qs[joint] = s["value"] as? Double ?? 0
            let t = s["time_s"] as? Double ?? Double(i) / Double(n) * 2
            let poses = AssembleEngine.decode([AsmComponentPose].self, s["poses"]) ?? []
            let hits = (s["collisions"] as? [[String: Any]] ?? []).map { "\($0["a"] as? String ?? "") / \($0["b"] as? String ?? "")" }
            return .init(time: t, q: qs, poses: Dictionary(poses.map { ($0.component, $0.simd) }, uniquingKeysWith: { a, _ in a }), collisions: hits)
        }
        // One row per pair, the earliest contact.
        var seen = Set<String>()
        let contacts = (r["first_contacts"] as? [[String: Any]] ?? []).map {
            AsmMotionStudy.Contact(a: $0["a"] as? String ?? "", b: $0["b"] as? String ?? "", time: $0["time_s"] as? Double ?? 0)
        }.sorted { $0.time < $1.time }.filter { seen.insert([$0.a, $0.b].sorted().joined(separator: "/")).inserted }
        return AsmMotionStudy(id: id, title: studies.first { $0.id == id }?.title ?? id, steps: steps, firstContacts: contacts)
    }

    /// Every joint from one saved pose to another, eased, with interference at each step. Gives
    /// the main thread back between steps so the window stays live; throws when cancelled.
    @MainActor
    private func poseToPose(from a: String, to b: String, steps n: Int, duration: Double) async throws -> AsmMotionStudy {
        let pa = doc?.poses?.first { $0.id == a }?.q_deg ?? [:]
        let pb = doc?.poses?.first { $0.id == b }?.q_deg ?? [:]
        var steps: [AsmMotionStudy.Step] = []
        var contacts: [AsmMotionStudy.Contact] = []
        for i in 0...n {
            let s = Double(i) / Double(n)
            let e = s * s * (3 - 2 * s)
            var qs: [String: Double] = [:]
            for j in joints { qs[j.id] = (pa[j.id] ?? 0) + ((pb[j.id] ?? 0) - (pa[j.id] ?? 0)) * e }
            let fk = try engine.call("fk", ["q": qs])
            let poses = AssembleEngine.decode([AsmComponentPose].self, fk["poses"]) ?? []
            let hits = ((try? engine.call("interference", ["q": qs]))?["pairs"] as? [[String: Any]] ?? []).map(Self.pair)
            for h in hits where !contacts.contains(where: { $0.a == h.a && $0.b == h.b }) {
                contacts.append(.init(a: h.a, b: h.b, time: s * duration))
            }
            steps.append(.init(time: s * duration, q: qs, poses: Dictionary(poses.map { ($0.component, $0.simd) }, uniquingKeysWith: { a, _ in a }),
                               collisions: hits.map { "\($0.a) / \($0.b)" }))
            studyProgress = Double(i + 1) / Double(n + 1)
            try await Task.sleep(for: .milliseconds(1))
        }
        return AsmMotionStudy(id: Self.poseStudy, title: String(localized: "Home to ready"), steps: steps, firstContacts: contacts)
    }

    /// Scrubs the study: the canvas shows the sampled pose at time t.
    func scrub(to t: Double) {
        if studyProgress != nil { pendingScrub = t; return }
        guard let s = study, !s.steps.isEmpty else { return }
        playhead = min(max(t, 0), s.duration)
        let i = s.steps.lastIndex { $0.time <= playhead + 1e-9 } ?? 0
        let step = s.steps[i]
        poses = step.poses
        q = step.q
        poseRevision += 1
    }

    func togglePlay() { playing ? stop() : play() }

    func play() {
        if studyProgress != nil { playWhenReady = true; return }
        guard let s = study, s.duration > 0 else { return }
        if playhead >= s.duration { playhead = 0 }
        playing = true
        let start = Date().addingTimeInterval(-playhead)
        player = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let now = Date().timeIntervalSince(start)
            if now >= s.duration { self.scrub(to: s.duration); self.stop() } else { self.scrub(to: now) }
        }
    }

    func stop() {
        player?.invalidate()
        player = nil
        playing = false
    }

    /// Leaves the study: back to the live pose.
    func endScrub() {
        stop()
        if let r = try? engine.call("fk") {
            if let list = AssembleEngine.decode([AsmComponentPose].self, r["poses"]) {
                poses = Dictionary(list.map { ($0.component, $0.simd) }, uniquingKeysWith: { a, _ in a })
            }
            if let qd = r["q"] as? [String: Double] { q = qd }
            poseRevision += 1
        }
    }

    // MARK: Flow

    /// `commit` -> `{produce}`, handed to `vf_flow_command`: "Assembly vN" in the pipeline.
    func commit() {
        guard let flow else { return }
        do {
            let r = try engine.call("commit")
            guard let produce = r["produce"] as? [String: Any] else { return }
            nonisolated(unsafe) let command = produce
            committed = MainActor.assumeIsolated {
                flow.command(command)
                return flow.node("assemble.assembly")?.revisionName
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearError() {
        error = nil
        retry = nil
    }

    /// Shows the error; `retry` backs the banner's Try Again.
    private func fail(_ e: Error, retry: (() -> Void)? = nil) {
        error = e.localizedDescription
        self.retry = retry
    }

    // MARK: IK drag (7.10.4)

    /// The tool frame's pose now (mm, world) from kin.
    private func syncTip() {
        guard !ik.dragging, let frame = toolFrameNow() else { return }
        ik.target = frame.pos
        ik.rpy = frame.rpy
        ik.reached = true
        ik.shortBy = 0
    }

    private func toolFrameNow() -> (pos: SIMD3<Double>, rpy: SIMD3<Double>)? {
        guard product == .arm, let r = try? engine.kinCall("fk", ["q": kinQ()]),
              let f = (r["frames"] as? [String: Any])?["tool"] as? [String: Any] else { return nil }
        let m = Self.matrix(pose: f)
        let p = SIMD3<Double>(Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z))
        return (p, Self.rpy(m))
    }

    /// The current joint values in kin order (rad or m).
    func kinQ() -> [Double] {
        kinJoints.map { id in
            let v = q[id] ?? 0
            return joints.first { $0.id == id }?.angular == false ? v / 1000 : v * .pi / 180
        }
    }

    func beginDrag() -> Bool {
        guard product == .arm, !kinJoints.isEmpty else { return false }
        stop()
        var p: [String: Any] = ["frame": "tool", "q": kinQ(), "keep_orientation": ik.keepOrientation,
                                "locked": Array(ik.locked)]
        if ik.posture == .midRange { p["posture"] = "mid_range" }
        do {
            try engine.kinCall("ik_drag_begin", p)
        } catch {
            self.error = error.localizedDescription
            return false
        }
        dragQ = Array(repeating: 0, count: kinJoints.count)
        dragLinks = Array(repeating: 0, count: kinLinks.count * 16)
        ik.dragging = true
        return true
    }

    /// One pointer move: target in mm and rpy degrees. Writes the canvas directly; the inspector
    /// numbers follow at 30 Hz.
    func dragMove(to target: SIMD3<Double>, rpy: SIMD3<Double>) {
        guard ik.dragging else { return }
        let qw = Self.quat(rpy: rpy)
        let t = [target.x / 1000, target.y / 1000, target.z / 1000, qw.real, qw.imag.x, qw.imag.y, qw.imag.z]
        let r = engine.dragMove(t, q: &dragQ, links: &dragLinks)
        guard r >= 0 else { return }
        var comp: [String: simd_float4x4] = [:]
        for (i, id) in kinLinks.enumerated() where i < homeInverse.count {
            let base = i * 16
            var m = simd_float4x4(columns: (SIMD4(dragLinks[base], dragLinks[base + 1], dragLinks[base + 2], dragLinks[base + 3]),
                                            SIMD4(dragLinks[base + 4], dragLinks[base + 5], dragLinks[base + 6], dragLinks[base + 7]),
                                            SIMD4(dragLinks[base + 8], dragLinks[base + 9], dragLinks[base + 10], dragLinks[base + 11]),
                                            SIMD4(dragLinks[base + 12] * 1000, dragLinks[base + 13] * 1000, dragLinks[base + 14] * 1000, 1)))
            m = m * homeInverse[i]
            comp[id] = m
        }
        poses = comp
        let short = r == 1 ? (engine.dragError()?.distance ?? 0) * 1000 : 0
        var values: [String: Double] = [:]
        for (i, id) in kinJoints.enumerated() {
            let ang = joints.first { $0.id == id }?.angular ?? true
            values[id] = ang ? dragQ[i] * 180 / .pi : dragQ[i] * 1000
        }
        sink?.apply(poses: comp, q: values, target: target, shortByMM: short)
        let now = CACurrentMediaTimeShim.now()
        if now - lastPublish > 1.0 / 30 {
            lastPublish = now
            q = values
            ik.target = target
            ik.rpy = rpy
            ik.reached = short < 0.5
            ik.shortBy = short
        }
    }

    /// Release (commit = true) keeps the pose in the document's current values; Esc (false)
    /// restores the pose from before the drag.
    func endDrag(commit keep: Bool) {
        guard ik.dragging else { return }
        ik.dragging = false
        let r = try? engine.kinCall("ik_drag_end", keep ? [:] : ["cancel": true])
        let qk = r?["q"] as? [Double] ?? dragQ
        var values: [String: Double] = [:]
        for (i, id) in kinJoints.enumerated() where i < qk.count {
            let ang = joints.first { $0.id == id }?.angular ?? true
            values[id] = ang ? qk[i] * 180 / .pi : qk[i] * 1000
        }
        let short = keep ? ik.shortBy : 0
        do { try drive(values) } catch { self.error = error.localizedDescription }
        if keep && short > 0.5 {
            // Keep the unreached target and the gap on screen after release.
            ik.reached = false
            ik.shortBy = short
        }
    }

    /// Typed target in the inspector: one solve to it.
    func solveTo(target: SIMD3<Double>, rpy: SIMD3<Double>) {
        guard beginDrag() else { return }
        dragMove(to: target, rpy: rpy)
        let short = (engine.dragError()?.distance ?? 0) * 1000
        endDrag(commit: true)
        ik.target = target
        ik.rpy = rpy
        ik.reached = short < 0.5
        ik.shortBy = short < 0.5 ? 0 : short
        sink?.apply(poses: poses, q: q, target: target, shortByMM: ik.shortBy)
    }

    private func toolChanged() {
        if tool != .dragTip { ik.shortBy = 0; ik.reached = true; syncTip() }
        if tool == .grasp, product == .hand, grasp.fingers.isEmpty { setUpGrasp() }
        poseRevision += 1
    }

    // MARK: Grasp (7.10.5)

    /// Places the object in the hand and puts one target per fingertip on its surface.
    func setUpGrasp() {
        guard product == .hand else { return }
        do {
            try HandGrasp.place(self)
            solveGrasp()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setGraspPlacement(center: SIMD3<Double>, axis: SIMD3<Double>, fingers: [GraspFinger]) {
        grasp.center = center
        grasp.axis = axis
        grasp.fingers = fingers
    }

    /// Moves a fingertip target (already on the surface) and solves again.
    func moveFingertip(_ frame: String, to point: SIMD3<Double>, normal: SIMD3<Double>, solve: Bool = true) {
        guard let i = grasp.fingers.firstIndex(where: { $0.frame == frame }) else { return }
        grasp.fingers[i].point = point
        grasp.fingers[i].normal = normal
        if solve { solveGrasp() }
    }

    func setPriority(_ frame: String, _ p: Int) {
        guard let i = grasp.fingers.firstIndex(where: { $0.frame == frame }) else { return }
        grasp.fingers[i].priority = max(1, min(5, p))
        solveGrasp()
    }

    func setObjectSize(_ size: SIMD3<Double>) {
        grasp.size = size
        setUpGrasp()
    }

    /// Multi-task IK with tendon couplings (kin `ik_hand`), from the current pose.
    func solveGrasp() {
        guard product == .hand, !grasp.fingers.isEmpty else { return }
        let tips: [[String: Any]] = grasp.fingers.map { f in
            ["frame": f.frame, "point": [f.point.x / 1000, f.point.y / 1000, f.point.z / 1000], "priority": f.priority]
        }
        do {
            let r = try engine.kinCall("ik_hand", ["q0": kinQ(), "fingertips": tips])
            let ikr = r["ik"] as? [String: Any] ?? [:]
            let qk = ikr["q"] as? [Double] ?? []
            var values: [String: Double] = [:]
            for (i, id) in kinJoints.enumerated() where i < qk.count { values[id] = qk[i] * 180 / .pi }
            let reached = r["reached"] as? [Bool] ?? []
            let dist = r["distance"] as? [Double] ?? []
            let drives = r["drives"] as? [String] ?? []
            for i in grasp.fingers.indices {
                grasp.fingers[i].reached = i < reached.count ? reached[i] : false
                grasp.fingers[i].distanceMM = i < dist.count ? dist[i] * 1000 : 0
                grasp.fingers[i].drive = i < drives.count ? drives[i].capitalized : "Motor"
                let prefix = grasp.fingers[i].frame.replacingOccurrences(of: "_tip", with: "")
                grasp.fingers[i].joints = kinJoints.filter { $0.hasPrefix(prefix + "_") && !$0.hasSuffix("_abd") }.compactMap { values[$0] }
            }
            let names = ikr["actuator_names"] as? [String] ?? []
            let acts = ikr["actuators"] as? [Double] ?? []
            let info = (try? engine.kinCall("model.info"))?["actuators"] as? [[String: Any]] ?? []
            grasp.actuators = zip(names, acts).map { n, v in
                let tendon = info.first { ($0["name"] as? String) == n }?["drive"] as? String == "tendon"
                return (n, tendon ? v * 1000 : v * 180 / .pi, tendon)
            }
            try drive(values)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "Save grasp" (`asm.save_grasp`): the object, fingertip targets, joint values, actuators.
    @discardableResult
    func saveGrasp() -> String? {
        let n = (doc?.grasps?.count ?? 0) + 1
        let id = grasp.savedID ?? "\(grasp.shape)_\(Int(grasp.size.x))_\(n)"
        let size: [Double] = grasp.shape == "box" ? [grasp.size.x, grasp.size.y, grasp.size.z].map { $0 / 1000 }
                           : grasp.shape == "sphere" ? [grasp.size.x / 1000] : [grasp.size.x / 1000, grasp.size.y / 1000]
        let g: [String: Any] = [
            "id": id,
            "object": ["shape": grasp.shape, "size_m": size],
            "fingertips": grasp.fingers.map { f in
                ["frame": f.frame, "point_m": [f.point.x, f.point.y, f.point.z].map { $0 / 1000 },
                 "normal": [f.normal.x, f.normal.y, f.normal.z], "priority": f.priority] as [String: Any]
            },
            "q_deg": q,
            "actuators": Dictionary(grasp.actuators.map { ($0.name, $0.tendon ? $0.value / 1000 : $0.value) }, uniquingKeysWith: { a, _ in a }),
        ]
        do {
            let before = doc
            try engine.call("save_grasp", ["grasp": g])
            try reloadDocument(kinBuiltin: product == .hand)
            recordStep(String(localized: "Save Grasp"), changed: doc != before)
            grasp.savedID = id
            commit()
            return id
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: Math

    /// A kin pose `{"xyz", "quat_wxyz"}` (m) as a 4x4 in mm.
    static func matrix(pose: [String: Any]) -> simd_float4x4 {
        let p = pose["xyz"] as? [Double] ?? [0, 0, 0]
        let q = pose["quat_wxyz"] as? [Double] ?? [1, 0, 0, 0]
        let r = simd_quatf(ix: Float(q[1]), iy: Float(q[2]), iz: Float(q[3]), r: Float(q[0]))
        var m = simd_float4x4(r)
        m.columns.3 = SIMD4(Float(p[0] * 1000), Float(p[1] * 1000), Float(p[2] * 1000), 1)
        return m
    }

    /// URDF fixed-axis roll, pitch, yaw (deg) of a rotation.
    static func rpy(_ m: simd_float4x4) -> SIMD3<Double> {
        let r20 = Double(m.columns.0.z), r21 = Double(m.columns.1.z), r22 = Double(m.columns.2.z)
        let r10 = Double(m.columns.0.y), r00 = Double(m.columns.0.x)
        let pitch = asin(max(-1, min(1, -r20)))
        let roll = atan2(r21, r22)
        let yaw = atan2(r10, r00)
        return SIMD3(roll, pitch, yaw) * 180 / .pi
    }

    static func quat(rpy d: SIMD3<Double>) -> simd_quatd {
        let r = d * .pi / 180
        let qx = simd_quatd(angle: r.x, axis: SIMD3(1, 0, 0))
        let qy = simd_quatd(angle: r.y, axis: SIMD3(0, 1, 0))
        let qz = simd_quatd(angle: r.z, axis: SIMD3(0, 0, 1))
        return (qz * qy * qx).normalized
    }
}

/// Where the 60 fps drag writes: the canvas's nodes, without SwiftUI.
protocol AssemblePoseSink: AnyObject {
    func apply(poses: [String: simd_float4x4], q: [String: Double], target: SIMD3<Double>, shortByMM: Double)
}

enum CACurrentMediaTimeShim {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

extension FlowModel {
    /// Sends a ready-made `vf_flow_command` (the asm `commit` reply's `produce`).
    @discardableResult
    func command(_ object: [String: Any]) -> [String: Any]? {
        var c: [String: Any?] = [:]
        for (k, v) in object { c[k] = v is NSNull ? Optional<Any>.none : Optional<Any>.some(v) }
        return sendCommand(c)
    }
}
