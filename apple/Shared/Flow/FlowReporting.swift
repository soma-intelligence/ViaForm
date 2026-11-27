import Foundation
import SwiftUI

/// What each workspace builds, reported to the pipeline, in one place so the Mac and the iPad
/// windows report the same way: the design (undo-safe, by content), the generated frame (a job
/// with its expected time, cancel reaching the study), the board (by content), the assembly
/// (its components, joints and linked board, by content), the flight, the training (a job counting its iterations, cancel
/// reaching the trainer), renders and exports. It also fills the trees of the design, assemble
/// and electronics stages.
///
/// Nothing in the workspaces' own modules knows about the pipeline: this reads their models.
struct FlowReporting: ViewModifier {
    let flow: FlowModel
    let design: DesignModel
    let pcb: PCBModel
    let generate: GenerateModel
    let sim: SimModel
    @State private var generateJob: Int?
    @State private var generateVersion = 0
    @State private var trainJob: Int?
    /// The paused state last told to the pipeline for the Generate job.
    @State private var generatePaused = false
    /// The joint count and the assembly read the engine's joint list: done off the main actor,
    /// once the design settles and only when its revision moved (FRONTEND-SPEC 7.2, nothing
    /// heavy on the hot path; UI-UX-AUDIT P0-11).
    @State private var jointsPass: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear {
                DesignJoints.forget(design)
                scheduleJointsPass(after: .zero)
                flow.reportDesign(design.snapshot)
                reportDesignTree()
                reportBoard()
                reportGenerated()
            }
            .onChange(of: design.snapshot.revision) { _, _ in
                flow.reportDesign(design.snapshot)
                reportDesignTree()
                scheduleJointsPass()
            }
            .onChange(of: design.snapshot.path) { _, path in documentPathChanged(path) }
            .onChange(of: flow.documentEpoch) { _, _ in
                // A fresh pipeline for another document: report what the workspaces hold now.
                DesignJoints.forget(design)
                scheduleJointsPass(after: .zero)
                flow.reportDesign(design.snapshot)
                reportDesignTree()
                reportBoard()
                reportGenerated()
            }
            .onChange(of: generate.running) { _, on in generateChanged(on) }
            .onChange(of: generate.progress) { _, p in
                guard let j = generateJob, let p else { return }
                let total = max(p.iterations, 1) * max(p.variants, 1)
                flow.progress(job: j, fraction: min(max(p.fraction, 0), 1), done: min(p.variant * max(p.iterations, 1) + p.iteration, total), total: total)
            }
            .onChange(of: generate.paused) { _, on in
                // Paused from the study's own button: the jobs list and the capsule follow.
                guard let j = generateJob, on != generatePaused else { return }
                generatePaused = on
                if on { flow.pause(job: j) } else { flow.resume(job: j) }
            }
            .onChange(of: generate.project) { _, _ in reportGenerated() }
            .onChange(of: generate.assemblyLoaded) { _, _ in reportGenerated() }
            .onChange(of: pcb.revision) { _, _ in reportBoard() }
            .onChange(of: pcb.linkedRevision) { _, _ in reportAssembly() }
            .onChange(of: sim.outcome) { _, o in
                if let o { flow.produce("simulate.flight", summary: o) }
            }
            .onChange(of: sim.training.running) { _, on in trainingChanged(on) }
            .onChange(of: sim.training.history.count) { _, n in
                if let j = trainJob { flow.progress(job: j, done: n, total: max(sim.training.total, n)) }
            }
            .onChange(of: design.lastRun) { _, r in
                guard let r, r.ok else { return }
                if ["render.start", "render.batch", "render.export"].contains(r.id) {
                    flow.produce("render.shots", summary: r.id == "render.export" ? "Render exported" : "Render made")
                } else if r.id.hasPrefix("file.export") || r.id == "export.step" {
                    flow.produce("make.bundle", summary: "Design exported")
                }
            }
    }

    /// Reads the engine's joint list once the design has been still for a moment (a drag or a
    /// typed value sends many revisions), off the main actor and only for a revision not read
    /// yet: the joint count and the assembly follow.
    private func scheduleJointsPass(after delay: Duration = .milliseconds(300)) {
        jointsPass?.cancel()
        jointsPass = Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let joints = await DesignJoints.read(design)
            guard !Task.isCancelled else { return }
            countJoints(joints)
            reportAssembly(joints)
        }
    }

    /// Joints from the engine's own list, motors from the bodies named so: the counts follow
    /// the open design, New and Open included.
    private func countJoints(_ joints: DesignJoints.Summary) {
        let motors = design.snapshot.bodies.filter { $0.name.localizedCaseInsensitiveContains("motor") || $0.name.localizedCaseInsensitiveContains("servo") }.count
        if flow.designJoints != joints.count { flow.designJoints = joints.count }
        if flow.designMotors != motors { flow.designMotors = motors }
    }

    /// The design file changed under the pipeline (Save As, or a design opened some other way
    /// than the File menu): a first path keeps the pipeline under it, another document brings
    /// its own back. A `.viaform` project carries its pipeline itself.
    private func documentPathChanged(_ path: String?) {
        guard let path, !flow.isProjectFile, path != flow.documentKey else { return }
        if flow.documentKey == nil { flow.adoptDocument(path) } else { flow.openDocument(path) }
    }

    private func generateChanged(_ on: Bool) {
        if on {
            generateVersion = generate.outcomeVersion
            generatePaused = false
            let g = generate
            let p = generate.progress
            generateJob = flow.startJob("generate.frame", verb: String(localized: "Generating"), label: String(localized: "Generative study"),
                                        total: p.map { max($0.iterations, 1) * max($0.variants, 1) },
                                        expected: generate.expected > 0 ? generate.expected : nil,
                                        controls: .init(pause: { g.setPaused(true) }, resume: { g.setPaused(false) }, cancel: { g.cancel() }))
            return
        }
        guard let j = generateJob ?? flow.job(on: "generate.frame")?.id else { return }
        generateJob = nil
        if let e = generate.error {
            flow.end(job: j, error: e)
        } else if generate.outcomeVersion != generateVersion, let o = generate.outcome {
            flow.end(job: j, summary: String(localized: "\(o.candidates.count) candidates"))
        } else {
            // Stopped from the study's own button: the frame keeps its last build.
            flow.cancel(job: j)
        }
    }

    private func trainingChanged(_ on: Bool) {
        let t = sim.training
        if on {
            trainJob = flow.startJob("train.policy", verb: String(localized: "Training"), label: t.target.name, total: t.total,
                                     controls: .init(cancel: { t.cancel() }))
            return
        }
        guard let j = trainJob ?? flow.job(on: "train.policy")?.id else { return }
        trainJob = nil
        if let e = t.error {
            flow.end(job: j, error: e)
        } else if t.brainJSON != nil {
            let held = t.heldOut.map { String(format: ", held-out cost %.3f to %.3f", $0.before, $0.after) } ?? ""
            flow.end(job: j, summary: t.target.name + held)
        } else {
            flow.cancel(job: j)
        }
    }

    private func reportBoard() {
        guard let p = pcb.project else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let fp = (try? enc.encode(p)).map { FlowFingerprint.of([String(decoding: $0, as: UTF8.self)]) }
        if !p.components.isEmpty {
            flow.produce("electronics.board", summary: "\(p.components.count) parts, \(p.nets.count) nets", fingerprint: fp, amendWithin: 2, source: "edit")
        }
        flow.reportTree("electronics", items: p.components.map {
            .init(id: "ref:\($0.reference)", name: "\($0.reference) \($0.value)", kind: "component", links: ["ref:\($0.reference)"])
        } + p.nets.map { .init(id: "net:\($0.id)", name: $0.name, kind: "net") })
    }

    /// The assembly is the design's components, their placements, its joints and the board the
    /// link put in it. It is reported when that changes, by content, so a body edit that leaves
    /// the components and joints as they were adds no assembly revision, and an undo comes back
    /// to the earlier one. Nothing is reported while the design has no component (no assembly
    /// exists yet), nor while the 3D board is behind the board (the assembly would claim a board
    /// revision it does not hold).
    private func reportAssembly(_ joints: DesignJoints.Summary? = nil) {
        guard !design.assembly.isEmpty, !pcb.boardOutOfDate else { return }
        Self.rebuildAssembly(flow: flow, design: design, pcb: pcb, source: "edit", joints: joints)
    }

    /// Records the assembly from what the design and the board hold now, on the current
    /// revisions of its inputs. This is what "Re-run" on a stale Assembly does: it reads, it
    /// never changes the design (sending the board to 3D is the Electronics stage's own verb).
    /// The joint list comes from `joints`, else the one read for this design revision, else it
    /// is read off the main actor first.
    @MainActor
    static func rebuildAssembly(flow: FlowModel, design: DesignModel, pcb: PCBModel, source: String = "rebuild", joints: DesignJoints.Summary? = nil) {
        if let joints = joints ?? DesignJoints.cached(design) {
            produceAssembly(flow: flow, design: design, pcb: pcb, source: source, joints: joints)
            return
        }
        Task { @MainActor in
            let joints = await DesignJoints.read(design)
            guard !design.assembly.isEmpty, !pcb.boardOutOfDate else { return }
            produceAssembly(flow: flow, design: design, pcb: pcb, source: source, joints: joints)
        }
    }

    @MainActor
    private static func produceAssembly(flow: FlowModel, design: DesignModel, pcb: PCBModel, source: String, joints: DesignJoints.Summary) {
        let parts = design.assembly
        let jointKey = joints.keys
        let partKey = parts.map { "\($0.id):\($0.name):\($0.occurrence ?? ""):\($0.grounded):\($0.bodies.sorted().joined(separator: ",")):\($0.linkedPCB)" }.sorted()
        let board = pcb.linkedRevision.map { "board:\($0)" } ?? "board:none"
        let fp = FlowFingerprint.of(partKey + jointKey + [board])
        var summary = "\(parts.count) component\(parts.count == 1 ? "" : "s"), \(joints.count) joint\(joints.count == 1 ? "" : "s")"
        if pcb.linkedRevision != nil, let b = flow.node("electronics.board")?.revisionName { summary += ", \(b)" }
        flow.produce("assemble.assembly", summary: summary, fingerprint: fp, amendWithin: source == "edit" ? 2 : nil, source: source)
    }

    /// The Generate stage's browser: every part of the project's assembly.json (generated,
    /// made, and the real components grouped by component_ref, one row per placed instance).
    /// When the product has a frame artifact, the assembly on disk is that frame, built: it is
    /// reported by content, so a regenerated assembly is a new revision and the same file is not.
    private func reportGenerated() {
        guard let p = generate.project, let url = p.assembly,
              let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let items = Self.generatedTree(o, inserted: generate.assemblyLoaded)
        flow.reportTree("generate", items: items)
        if flow.node("generate.frame") != nil, flow.job(on: "generate.frame") == nil {
            let parts = o["parts"] as? [[String: Any]] ?? []
            let generated = parts.filter { ($0["kind"] as? String) == "generative" }.count
            let components = parts.filter { ($0["kind"] as? String) == "component" }.count
            let fp = FlowFingerprint.of([p.name, String(decoding: data, as: UTF8.self)])
            flow.produce("generate.frame", summary: "\(generated) generated parts, \(components) components placed", fingerprint: fp, source: "assembly")
        }
    }

    /// The rows of `generatedTree`: folders for generated parts, made parts and components,
    /// a component folder per component_ref holding its placed instances.
    static func generatedTree(_ asm: [String: Any], inserted: Bool) -> [FlowModel.TreeItem] {
        let parts = asm["parts"] as? [[String: Any]] ?? []
        func name(_ p: [String: Any], _ i: Int) -> String { (p["name"] as? String) ?? (p["ref"] as? String) ?? "part \(i + 1)" }
        func mass(_ p: [String: Any]) -> String? { (p["mass_g"] as? Double).map { VFFormat.mass($0) } }
        let state = inserted ? "inserted" : "not inserted"
        var items: [FlowModel.TreeItem] = []
        var made: [FlowModel.TreeItem] = [], generated: [FlowModel.TreeItem] = [], comps: [FlowModel.TreeItem] = []
        var refs: [String: Int] = [:], refOrder: [String] = [], refDetail: [String: String] = [:]
        for (i, p) in parts.enumerated() {
            let kind = p["kind"] as? String ?? ""
            let n = name(p, i)
            switch kind {
            case "generative":
                generated.append(.init(id: "gen:part:\(i)", name: n, kind: "body", parent: "gen:folder:generated", links: ["part:\(n)"],
                                       detail: [p["material"] as? String, mass(p)].compactMap { $0 }.joined(separator: " · ")))
            case "component":
                let ref = (p["component_ref"] as? String) ?? (p["ref"] as? String) ?? "?"
                if refs[ref] == nil { refOrder.append(ref); refDetail[ref] = (p["description"] as? String) ?? (p["part_number"] as? String) }
                refs[ref, default: 0] += 1
                comps.append(.init(id: "gen:comp:\(i)", name: n, kind: "component", parent: "gen:ref:\(ref)", links: ["ref:\(ref)"], detail: mass(p)))
            default:
                made.append(.init(id: "gen:part:\(i)", name: n, kind: "body", parent: "gen:folder:made", links: ["part:\(n)"],
                                  detail: [p["material"] as? String, mass(p)].compactMap { $0 }.joined(separator: " · ")))
            }
        }
        if !generated.isEmpty {
            items.append(.init(id: "gen:folder:generated", name: "Generated parts", kind: "folder", detail: "\(generated.count), \(state)"))
            items += generated
        }
        if !made.isEmpty {
            items.append(.init(id: "gen:folder:made", name: "Made parts", kind: "folder", detail: "\(made.count)"))
            items += made
        }
        if !comps.isEmpty {
            items.append(.init(id: "gen:folder:components", name: "Components", kind: "folder", detail: "\(comps.count) placed, \(refOrder.count) lines"))
            for ref in refOrder {
                items.append(.init(id: "gen:ref:\(ref)", name: ref, kind: "component", parent: "gen:folder:components", links: ["ref:\(ref)"],
                                   detail: ["×\(refs[ref] ?? 0)", refDetail[ref]].compactMap { $0 }.joined(separator: " ")))
            }
            items += comps
        }
        return items
    }

    private func reportDesignTree() {
        let s = design.snapshot
        flow.reportTree("design", items: s.bodies.map {
            .init(id: "body:\($0.name)", name: $0.name, kind: "body", links: ["part:\($0.name)"],
                  detail: $0.material)
        } + s.sketches.map { .init(id: "sketch:\($0.id)", name: $0.name, kind: "sketch") })
        flow.reportTree("assemble", items: design.assembly.map { p in
            .init(id: "occ:\(p.id)", name: p.occurrence ?? p.name, kind: p.grounded ? "grounded" : "occurrence",
                  links: p.bodies.map { "part:\($0)" } + (p.linkedPCB ? ["board"] : []))
        })
    }
}

/// The design's joint list (`joint.list`) as the pipeline needs it: a count and one sorted key
/// per joint. Read off the main actor (the design engine holds its own lock), once per design
/// revision; the last read is kept per design.
@MainActor
enum DesignJoints {
    struct Summary: Sendable, Equatable {
        var count = 0
        var keys: [String] = []
    }

    private struct Entry { var revision: Int; var summary: Summary }
    private static var last: [ObjectIdentifier: Entry] = [:]
    /// Reads of `joint.list` since launch (the self-test checks that a still design is read once).
    private(set) static var reads = 0

    /// The summary read for the design's current revision, if any.
    static func cached(_ design: DesignModel) -> Summary? {
        guard let e = last[ObjectIdentifier(design)], e.revision == design.snapshot.revision else { return nil }
        return e.summary
    }

    /// Drops the last read (another document came in, whose revision may repeat a number).
    static func forget(_ design: DesignModel) { last[ObjectIdentifier(design)] = nil }

    /// The joint list of the design's current revision: the kept one, else read off the main actor.
    static func read(_ design: DesignModel) async -> Summary {
        if let s = cached(design) { return s }
        let revision = design.snapshot.revision
        let engine = design.engine
        reads += 1
        let s = await Task.detached(priority: .userInitiated) { summarize(engine) }.value
        if design.snapshot.revision == revision { last[ObjectIdentifier(design)] = Entry(revision: revision, summary: s) }
        return s
    }

    nonisolated private static func summarize(_ engine: CADEngine) -> Summary {
        let list = ((try? engine.execute("joint.list")) as? [String: Any])?["joints"] as? [[String: Any]] ?? []
        let keys = list.map { j in
            ["name", "type", "kind", "component1", "component2", "occurrence1", "occurrence2"]
                .compactMap { j[$0].map { "\($0)" } }.joined(separator: "/")
        }.sorted()
        return Summary(count: list.count, keys: keys)
    }
}

extension View {
    /// Reports what the workspaces build to `flow` (see `FlowReporting`).
    func reportsToFlow(_ flow: FlowModel, design: DesignModel, pcb: PCBModel, generate: GenerateModel, sim: SimModel) -> some View {
        modifier(FlowReporting(flow: flow, design: design, pcb: pcb, generate: generate, sim: sim))
    }
}
