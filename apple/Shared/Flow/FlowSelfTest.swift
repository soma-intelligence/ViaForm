import Foundation

/// Checks of the pipeline model against the real core and the canned project, run by
/// `--flow-selftest` (the app has no unit test target): prints one line per check and exits
/// with the number of failures.
@MainActor
enum FlowSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") flow: \(name)\(ok ? "" : " \(detail())")")
    }

    static func run() -> Never {
        let f = FlowModel.sample()
        check("sample product", f.product == "Racer 3in", f.product)
        check("eight stages", f.stages.count == 8)
        check("frame revision name", f.node("generate.frame")?.revisionName == "Frame v12", "\(String(describing: f.node("generate.frame")?.revisionName))")
        check("board revision name", f.node("electronics.board")?.revisionName == "Board rev C")
        check("stale reason", f.node("assemble.assembly")?.reason == "Frame v12 replaced v11", f.node("assemble.assembly")?.reason ?? "")
        check("rerun action", f.node("assemble.assembly")?.action?.label == "Re-run on Frame v12")
        check("study job caption", f.queue.headline?.hasPrefix("Generating 74 of 120") == true, f.queue.headline ?? "none")
        check("tree rows", f.tree("design").first?.detail == "Model v12")
        check("linked selection", f.selection.linked.first?.stage == "assemble", "\(f.selection.linked)")
        check("search", f.search("use as frame").first?.id == "generate.use_as_frame")
        check("single key", f.search("e", stage: "design").first?.key == "E")
        check("catalog per stage", Workspace.allCases.allSatisfy { !f.commands(stage: $0.stage).isEmpty })

        // Jobs: pause reaches the controls, cancel too, and the job leaves the queue.
        var paused = false, cancelled = false
        let job = f.startJob("render.shots", verb: "Rendering", label: "6 shots", total: 6,
                             controls: .init(pause: { paused = true; return true }, resume: { true }, cancel: { cancelled = true }))
        check("job started", job != nil && f.queue.on(artifact: "render.shots")?.pausable == true)
        if let job {
            f.progress(job: job, done: 3)
            f.pause(job: job)
            check("job paused", paused && f.job(on: "render.shots")?.paused == true)
            f.cancel(job: job)
            check("job cancelled", cancelled && f.job(on: "render.shots") == nil)
        }

        // Undo: the same design content lands on the same revision.
        let d = FlowModel(service: RustFlow(), autosave: nil)
        d.produce("design.model", fingerprint: "a", source: "edit")
        d.produce("generate.frame")
        d.produce("design.model", fingerprint: "b", source: "edit")
        check("edit stales frame", d.node("generate.frame")?.status == .stale)
        check("undo restores", d.produce("design.model", fingerprint: "a", source: "edit") == "restored")
        check("frame current again", d.node("generate.frame")?.status == .current)

        // Eyes and locks, and the document round trip.
        d.reportTree("design", items: [.init(id: "body:A", name: "A", kind: "body")])
        d.setVisible("body:A", false)
        check("eye off", d.tree("design").first { $0.id == "body:A" }?.visible == false)
        if let doc = d.exportDocument() {
            // Autosaves are kept per document: the same document gets its pipeline back, a new
            // one starts fresh, and a second document never reads the first one's.
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("viaform-flow-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let probe = FlowModel(service: RustFlow(), autosave: root)
            if let url = probe.autosaveURL(for: "/tmp/a.sc") { try? doc.write(to: url) }
            check("fresh at launch", probe.node("design.model")?.revision == 0 && probe.product.isEmpty, probe.product)
            probe.openDocument("/tmp/a.sc")
            check("autosave restores", probe.node("design.model")?.revision == 1 && probe.tree("design").first { $0.id == "body:A" }?.visible == false)
            probe.openDocument("/tmp/b.sc")
            check("other document fresh", probe.node("design.model")?.revision == 0)
            probe.newDocument(product: "Humanoid Hand", graph: "hand")
            check("new document", probe.product == "Humanoid Hand" && probe.node("generate.frame") == nil && probe.documentKey == nil)
            try? FileManager.default.removeItem(at: root)
        } else {
            check("export", false)
        }

        // The canned project decodes like the real one.
        let m = FlowModel.preview()
        check("mock decodes", m.stages.count == 8 && m.jobs.count == 1 && m.outputs().count == 8)
        let screen = StageScreen.make(.assemble, flow: f)
        check("stage screen", screen.primary.first?.label == "Re-run on Frame v12" && !screen.ribbon.isEmpty, "\(screen.primary)")

        print("flow self-test: \(failures == 0 ? "all passed" : "\(failures) failed")")
        exit(Int32(failures))
    }
}
