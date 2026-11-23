import Foundation

/// Everything one workspace puts into the shared window, as plain values made from the
/// pipeline: the title and revision, the ribbon groups (from the command catalog), the one
/// primary action ("Re-run on Frame v12"), the browser rows, PIPELINE OUTPUTS, which inspector,
/// viewport and bottom panel to show, and the status line. The Mac and iPad windows build their
/// views from it, so a stage looks the same wherever it opens, and a preview or a check can
/// make one from `FlowModel.preview()` with no engine.
struct StageScreen: Equatable {
    enum Inspector: String { case design, study, joints, component, scenario, training, render, manufacture, robot }
    enum Viewport: String { case model, outcomes, assembly, board, flight, curves, renders, overview, twin }
    enum Bottom: String { case timeline, outcomes, telemetry, layers, none }

    struct RibbonGroup: Equatable, Identifiable {
        let name: String
        let commands: [FlowModel.Command]
        var id: String { name }
    }

    /// A button the stage puts first: a fix for a stale stage, or its main verb.
    struct PrimaryAction: Equatable {
        let label: String
        /// A command id of the catalog, or `flow.update` with the plan.
        let command: String
        var plan: [String] = []
        var prominent = false
    }

    var workspace: Workspace
    var product: String
    /// "Frame v12".
    var revision: String?
    var status: FlowModel.Status
    var reason: String
    var primary: [PrimaryAction]
    var ribbon: [RibbonGroup]
    var browser: [FlowModel.TreeRow]
    var outputs: [FlowModel.Output]
    var selection: FlowModel.Selection
    var job: FlowModel.RunningJob?
    var inspector: Inspector
    var viewport: Viewport
    var bottom: Bottom
    var statusLine: String

    /// The stage's verb when it has nothing to fix.
    private static func verb(_ w: Workspace) -> PrimaryAction? {
        switch w {
        case .generate: PrimaryAction(label: "Run Study", command: "generate.run")
        case .simulation: PrimaryAction(label: "Fly", command: "simulate.fly")
        case .train: PrimaryAction(label: "Start Training", command: "train.start")
        case .render: PrimaryAction(label: "Render Shots", command: "render.shots")
        case .make: PrimaryAction(label: "Export Design", command: "make.export")
        case .electronics: PrimaryAction(label: "Send Board to 3D", command: "electronics.send_to_3d")
        case .robot: PrimaryAction(label: "Connect Robot", command: "robot.connect")
        case .design, .assemble: nil
        }
    }

    private static func layout(_ w: Workspace) -> (Inspector, Viewport, Bottom) {
        switch w {
        case .design: (.design, .model, .timeline)
        case .generate: (.study, .outcomes, .outcomes)
        case .assemble: (.joints, .assembly, .timeline)
        case .electronics: (.component, .board, .layers)
        case .simulation: (.scenario, .flight, .telemetry)
        case .train: (.training, .curves, .telemetry)
        case .render: (.render, .renders, .none)
        case .make: (.manufacture, .overview, .none)
        case .robot: (.robot, .twin, .telemetry)
        }
    }

    /// The ribbon of a stage: its commands grouped by panel, in catalog order, the groups with
    /// a shortcut first. At most `perGroup` commands a group (the rest are in the palette).
    static func ribbon(_ commands: [FlowModel.Command], perGroup: Int = 6) -> [RibbonGroup] {
        var order: [String] = []
        var groups: [String: [FlowModel.Command]] = [:]
        for c in commands where c.group != "WORKSPACE" {
            if groups[c.group] == nil { order.append(c.group) }
            groups[c.group, default: []].append(c)
        }
        return order.map { g in
            let list = groups[g] ?? []
            let keyed = list.filter { $0.key != nil }
            return RibbonGroup(name: g, commands: Array((keyed + list.filter { $0.key == nil }).prefix(perGroup)))
        }
    }

    @MainActor
    static func make(_ w: Workspace, flow: FlowModel) -> StageScreen {
        let stage = flow.stage(w)
        let status = stage?.status ?? .empty
        var primary: [PrimaryAction] = []
        if let a = stage?.action, status == .stale || status == .failed {
            primary.append(PrimaryAction(label: a.label, command: "flow.update", plan: a.plan, prominent: true))
        }
        // The hand's Simulation stage is a grasp test run in its own view: no "Fly".
        if let v = verb(w), !(w == .simulation && flow.isHandProduct) { primary.append(PrimaryAction(label: v.label, command: v.command, prominent: primary.isEmpty)) }
        let (inspector, viewport, bottom) = layout(w)
        let job = flow.queue.on(stage: w.stage)
        let sel = flow.selection
        var line = sel.stage == w.stage && !sel.isEmpty ? "\(sel.title) selected" : (stage.map { "\($0.name) \(PipelineWords.describe($0.status))" } ?? w.title)
        if let job { line += " · " + job.caption }
        return StageScreen(
            workspace: w,
            product: flow.product,
            revision: flow.revisionName(of: w.stage),
            status: status,
            reason: stage?.reason ?? "",
            primary: primary,
            // The drone's flight verbs (fly, race, stress, wind) mean nothing for the hand.
            ribbon: ribbon(flow.commands(stage: w.stage).filter { !(w == .simulation && flow.isHandProduct) || !$0.id.hasPrefix("simulate.") }),
            browser: flow.tree(w.stage),
            outputs: flow.outputs(),
            selection: sel,
            job: job,
            inspector: inspector,
            viewport: viewport,
            bottom: bottom,
            statusLine: line
        )
    }
}

/// The words a status reads as, shared by every front end.
enum PipelineWords {
    static func describe(_ s: FlowModel.Status) -> String {
        switch s {
        case .current: "up to date"
        case .empty: "not built yet"
        case .stale: "stale, an input changed"
        case .running: "running"
        case .failed: "failed"
        }
    }
}
