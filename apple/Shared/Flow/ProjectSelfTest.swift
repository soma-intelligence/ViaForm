import Foundation

/// `--selftest` checks of the verification follow-ups: the "edited" mark counts the BOM, the
/// pipeline and the Generate study (P0-2); the Edit menu names the design's and the board's
/// steps (P0-1); a toast's Undo only undoes its own step (P0-10).
@MainActor
enum ProjectSelfTest {
    static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let design = DesignModel()
        let pcb = PCBModel(sample: true)
        let bom = BomModel()
        let flow = FlowModel(service: RustFlow(), autosave: nil)
        let generate = GenerateModel()
        let c = ProjectFiles.Context(design: design, pcb: pcb, bom: bom, flow: flow, generate: generate)
        ProjectFiles.register(c)
        ProjectFiles.markSaved(c)
        out.append((!ProjectFiles.isEdited(c), "P0-2 a fresh project is not edited"))

        bom.setBuilds(3)
        spin { await bom.settle() }
        out.append((ProjectFiles.isEdited(c), "P0-2 a BOM change marks the project edited"))
        ProjectFiles.markSaved(c)
        flow.setProduct("Edited product")
        out.append((ProjectFiles.isEdited(c), "P0-2 a pipeline change marks the project edited"))
        ProjectFiles.markSaved(c)
        generate.study = GenerateModel.study(.bridge)
        out.append((ProjectFiles.isEdited(c), "P0-2 a Generate study change marks the project edited"))
        ProjectFiles.markSaved(c)
        flow.reportDesign(design.snapshot)
        out.append((!ProjectFiles.isEdited(c), "P0-2 the pipeline's own reporting does not mark it edited"))

        // P0-1: the design's and the board's steps by name.
        design.run("solid.box", ["length": 10, "width": 10, "height": 10, "corner": [0, 0, 0], "body_name": "Box A"])
        let boxLabel = CADEngine.commands.first { $0.id == "solid.box" }?.label
        let n1 = design.engine.undoNames(undo: design.snapshot.undo, redo: design.snapshot.redo)
        out.append((n1.undo != nil && n1.undo == boxLabel, "P0-1 design Undo names the step: Undo \(n1.undo ?? "(none)")"))
        design.undo()
        let n2 = design.engine.undoNames(undo: design.snapshot.undo, redo: design.snapshot.redo)
        out.append((n2.redo == boxLabel && n2.undo == nil, "P0-1 after undo, Redo names it: Redo \(n2.redo ?? "(none)")"))
        design.redo()
        if let f = pcb.project?.board.footprints.first {
            pcb.sheet = .board
            pcb.move(f.id, to: PCBPoint(x: f.position.x + 2, y: f.position.y))
            let p = pcb.engine.undoNames(undo: pcb.undoCount, redo: pcb.redoCount)
            out.append((p.undo == String(localized: "Move Footprint"), "P0-1 board Undo names the step: Undo \(p.undo ?? "(none)")"))
        }

        // P0-10: a delete toast's Undo is bound to that step.
        design.selectedBodies = ["Box A"]
        design.deleteSelection()
        let step = DesignStep(design)
        let newestAfterDelete = step.isNewest
        design.run("solid.box", ["length": 5, "width": 5, "height": 5, "corner": [30, 0, 0], "body_name": "Box B"])
        let bodies = design.snapshot.bodies.count
        step.undo()
        out.append((newestAfterDelete && !step.isNewest && design.snapshot.bodies.count == bodies && design.messageIsError,
                    "P0-10 a delete toast's Undo refuses once a newer step exists"))
        return out
    }

    private static func spin<T>(_ work: @escaping @MainActor () async -> T) -> T {
        var result: T?
        Task { @MainActor in result = await work() }
        let deadline = Date().addingTimeInterval(60)
        while result == nil, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002)) }
        return result!
    }
}
