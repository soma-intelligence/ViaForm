#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Runs a command of the flow catalog wherever it lives: a design registry command through
/// `CommandRouter`, a stage verb on the workspace's own model (study, flight, training, board),
/// "Go to stage", and the pipeline's update. The ribbon, the palette, the update popover and the
/// inspector all go through here, so a verb does the same thing from every place.
@MainActor
struct StageActions {
    let model: DesignModel
    let pcb: PCBModel
    let flow: FlowModel
    let sim: SimModel
    let generate: GenerateModel
    /// Opens a workspace.
    var open: (Workspace) -> Void
    /// Opens a ribbon tab of the design workspaces (raw engine tab name).
    var openTab: (Workspace, String) -> Void = { _, _ in }
    var showBom: () -> Void = {}
    var showLibrary: () -> Void = {}
    var showFlow: (Workspace) -> Void = { _ in }

    /// The design workspaces share the 3D model and its registry ribbon.
    static let designLike: Set<Workspace> = [.design, .assemble, .render]

    /// False for a verb that is not wired yet (it stays in the palette, greyed).
    func canRun(_ id: String) -> Bool {
        switch id {
        case "generate.run": !generate.running
        case "generate.cancel": generate.running
        case "generate.use_as_frame": generate.candidate != nil && !generate.building
        case "generate.stress_here", "simulate.record": false
        case "train.start": !sim.training.running
        case "train.stop": sim.training.running
        case "train.fly_policy": sim.training.brainJSON != nil
        case "electronics.send_to_3d", "make.kicad": pcb.project != nil
        // No hardware link before phase 7 (robot-protocol, task P7-2).
        case _ where id.hasPrefix("robot."): false
        case _ where id.hasPrefix("simulate.") && flow.isHandProduct: false
        case "simulate.rerun": sim.generatedFrame != nil || flow.node("generate.frame")?.revision ?? 0 > 0
        default: true
        }
    }

    func run(_ id: String) {
        if id.hasPrefix("stage.") {
            if let w = Workspace(stage: String(id.dropFirst(6))) { open(w) }
            return
        }
        if id.hasPrefix("pcb.") {
            // Board commands take their arguments on the canvas: open the workspace that has them.
            open(.electronics)
            return
        }
        switch id {
        case "generate.run": open(.generate); generate.run()
        case "generate.cancel": generate.cancel()
        case "generate.use_as_frame":
            generate.build(into: model)
            open(.design)
        case "simulate.fly": open(.simulation); fly()
        case "simulate.rerun":
            open(.simulation)
            sim.reloadGeneratedFrame()
            if sim.generatedFrame != nil { sim.useGeneratedFrame = true }
            fly()
        case "simulate.race": open(.simulation); mission("race"); fly()
        case "simulate.stress": open(.simulation); mission("stress"); fly()
        case "simulate.wind":
            open(.simulation)
            let d = sim.catalog?.disturbances ?? []
            sim.disturb(d.first { $0.lowercased().contains("gust") || $0.lowercased().contains("wind") } ?? d.first ?? "gust")
        case "train.start": open(.train); sim.training.start()
        case "train.stop": sim.training.cancel()
        case "train.fly_policy":
            if let b = sim.training.brainJSON { open(.simulation); sim.flyTrained(b) }
        case "render.shots":
            open(.render)
            openTab(.render, "RENDER")
            if let c = model.commands.first(where: { $0.id == "render.start" }) { CommandRouter.run(c, model) }
        case "make.export": FileActions.export(model)
        case "make.bom": showBom()
        case "make.kicad": exportKiCad()
        case "electronics.drc":
            open(.electronics)
            pcb.refresh()
            let n = pcb.findings.count
            pcb.message = n == 0 ? "Rule checks passed" : "\(n) rule check finding\(n == 1 ? "" : "s")"
            pcb.messageIsError = n > 0
        case "electronics.send_to_3d":
            pcb.sendTo3D(model)
            open(.assemble)
        case "assemble.rebuild":
            open(.assemble)
            FlowReporting.rebuildAssembly(flow: flow, design: model, pcb: pcb)
        case "library.open": showLibrary()
        case "flow.show": showFlow(currentStageForFlow)
        case "flow.update": updateAll()
        default:
            if let c = model.commands.first(where: { $0.id == id }) {
                if !Self.designLike.contains(currentStageForFlow) { open(.design) }
                if !c.tab.isEmpty { openTab(currentStageForFlow, c.tab) }
                CommandRouter.run(c, model)
            }
        }
    }

    /// The workspace the actions were made for (set by the window).
    var current: Workspace = .design
    private var currentStageForFlow: Workspace { current }

    /// Rebuilds a stale chain in build order. A step that rebuilds at once (the assembly, from
    /// what the design and board hold) is done and the next one follows; a step that runs
    /// (a study, a flight, a training, a render) is started in its stage and the chain stops
    /// there, to go on when it ends. A step with no verb (the design, the board, the bundle,
    /// which only a person changes) opens its stage.
    func update(_ plan: [String]) {
        for id in plan {
            guard let stage = flow.node(id)?.stage, let w = Workspace(stage: stage) else { continue }
            if id == "assemble.assembly" {
                FlowReporting.rebuildAssembly(flow: flow, design: model, pcb: pcb)
                if id == plan.last { open(w) }
                continue
            }
            open(w)
            if let verb = Self.verb(of: w), canRun(verb) { run(verb) }
            return
        }
    }

    /// Whether `update(plan)` rebuilds something, or only opens a stage.
    func rebuilds(_ plan: [String]) -> Bool {
        plan.contains { id in
            guard let w = flow.node(id).flatMap({ Workspace(stage: $0.stage) }) else { return false }
            return id == "assemble.assembly" || Self.verb(of: w) != nil
        }
    }

    /// Every stale stage, upstream first.
    func updateAll() {
        let stale = flow.outputs().filter { $0.status == .stale || $0.status == .failed }
        if let a = stale.compactMap(\.action).first { update(a.plan) }
    }

    /// The verb that rebuilds a stage's artifact, when the stage has one.
    static func verb(of w: Workspace) -> String? {
        switch w {
        case .generate: "generate.run"
        case .simulation: "simulate.rerun"
        case .train: "train.start"
        case .render: "render.shots"
        case .assemble: "assemble.rebuild"
        case .design, .electronics, .make, .robot: nil
        }
    }

    private func fly() {
        sim.reset()
        sim.play()
    }

    private func mission(_ kind: String) {
        if let m = sim.catalog?.missions.first(where: { $0.id == kind || $0.id.contains(kind) }) {
            sim.options.mission = m.id
        }
    }

    private func exportKiCad() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "board.kicad_pcb"
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let url = p.url { pcb.exportKiCad(to: url) }
    }
}
#endif
