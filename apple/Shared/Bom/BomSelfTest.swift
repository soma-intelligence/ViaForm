import Foundation

/// `--selftest` checks for UI-UX-AUDIT P0-11: the project save and open, bringing parts into the
/// BOM and the joint list run off the main actor. Each action is timed as the app times it
/// (`ActionTiming`: the click handler, and the longest main-actor stall while the work runs, a
/// 4 ms heartbeat on the main queue) and checked against the 100 ms budget of FRONTEND-SPEC 7.2.
@MainActor
enum BomSelfTest {
    static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        ActionTiming.reset()

        // A project with some weight: 40 bodies, the sample board, a priced bill of materials.
        let design = DesignModel()
        for i in 0..<40 {
            design.run("solid.box", ["length": 10, "width": 10, "height": 4 + Double(i % 5), "corner": [Double(i % 8) * 14, Double(i / 8) * 14, 0], "body_name": "Part \(i)"])
        }
        let pcb = PCBModel(sample: true)
        let bom = BomModel()
        let flow = FlowModel(service: RustFlow(), autosave: nil)
        let c = ProjectFiles.Context(design: design, pcb: pcb, bom: bom, flow: flow)
        ProjectFiles.register(c)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viaform-p011-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Part import into the BOM: generated assemblies, then the design and the board.
        let names = ["hand", "drone"].filter { BomModel.assemblyFile($0) != nil || BomModel.componentsFolder != nil }
        if !names.isEmpty {
            bom.importAssemblies(names)
            spin { await bom.settle() }
            out.append((!bom.rows.isEmpty, "P0-11 BOM import of \(names.joined(separator: ", ")) off the main actor: \(bom.rows.count) lines"))
        }
        bom.syncDesign(design)
        spin { await bom.settle() }
        let designLines = bom.rows.filter { $0.line.origin == "design" }.count
        bom.syncPCB(pcb)
        spin { await bom.settle() }
        let boardLines = bom.rows.filter { $0.line.origin == "pcb" }.count
        let imported = Set(bom.doc.imports.map(\.origin))
        out.append((imported.contains("design") && imported.contains("pcb") && boardLines > 0 && bom.message == nil,
                    "P0-11 design and board parts brought in on the BOM queue: \(designLines) design, \(boardLines) board lines \(bom.message ?? "")"))

        // Save: the file is written, nothing is edited after, the pipeline lives in the file.
        let url = dir.appendingPathComponent("p011.viaform")
        let lines = bom.rows.count
        let saved = spin { await ProjectFiles.save(url, in: c) }
        out.append((saved && FileManager.default.fileExists(atPath: url.path) && !ProjectFiles.isEdited(c) && flow.isProjectFile,
                    "P0-11 project saved off the main actor, not edited after \(bom.message ?? "")"))

        // An edit made after the save marks the window edited; Open brings the file back.
        design.run("solid.box", ["length": 5, "width": 5, "height": 5, "corner": [200, 0, 0], "body_name": "Extra"])
        let editedAfterChange = ProjectFiles.isEdited(c)
        let opened = spin { await ProjectFiles.open(url, in: c) }
        out.append((opened && editedAfterChange && !ProjectFiles.isEdited(c) && design.snapshot.bodies.count == 40 && bom.rows.count == lines,
                    "P0-11 project opened off the main actor: \(design.snapshot.bodies.count) bodies, \(bom.rows.count) BOM lines \(bom.message ?? "")"))

        let projectTimings = ActionTiming.last

        // A failed open says why and offers Try Again; the open project stays.
        let missing = dir.appendingPathComponent("missing.viaform")
        let failed = spin { await ProjectFiles.open(missing, in: c) }
        let activity = ProjectFiles.activity(for: design)
        out.append((!failed && activity?.failure != nil && activity?.retry != nil && activity?.busy == nil && design.snapshot.bodies.count == 40,
                    "P0-11 failed open shows the reason with Try Again: \(activity?.failure ?? "no message")"))
        activity?.dismiss()

        // The joint list: read off the main actor, once per design revision.
        DesignJoints.forget(design)
        let readsBefore = DesignJoints.reads
        spin {
            await ActionTiming.measure("flow.joint_list") {
                _ = await DesignJoints.read(design)
                _ = await DesignJoints.read(design)
            }
        }
        let once = DesignJoints.reads - readsBefore == 1
        design.run("solid.box", ["length": 5, "width": 5, "height": 5, "corner": [220, 0, 0], "body_name": "Extra 2"])
        _ = spin { await DesignJoints.read(design) }
        out.append((once && DesignJoints.reads - readsBefore == 2, "P0-11 joint.list read once per design revision, off the main actor"))

        // The budget: every action's click handler and its longest main-actor stall under 100 ms.
        for name in ["bom.import_assemblies", "bom.sync_design", "bom.sync_pcb", "project.save", "project.open", "flow.joint_list"] {
            guard let r = (name.hasPrefix("project.") ? projectTimings : ActionTiming.last)[name] else {
                if name != "bom.import_assemblies" || !names.isEmpty { out.append((false, "P0-11 timing \(name): not measured")) }
                continue
            }
            let ok = r.clickMs < ActionTiming.budgetMs && r.stallMs < ActionTiming.budgetMs
            out.append((ok, String(format: "P0-11 timing %@: click %.1f ms, longest main-actor stall %.1f ms (work done in %.1f ms)", name, r.clickMs, r.stallMs, r.totalMs)))
        }
        return out
    }

    /// Runs `work` on the main actor and turns the run loop until it is done, so the main queue
    /// (the heartbeat, the engines' hand-backs) keeps running as it does in the app.
    @discardableResult
    private static func spin<T>(_ work: @escaping @MainActor () async -> T) -> T {
        var result: T?
        Task { @MainActor in result = await work() }
        let deadline = Date().addingTimeInterval(120)
        while result == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
        }
        return result!
    }
}
