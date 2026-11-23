import Foundation

/// The generative path for `--selftest`: a study run as an engine job (progress, then its
/// candidate built in one undo step without a second run), a cancelled job, a stopped job keeping
/// its best design so far, and both sample
/// projects (studies read, assembly inserted with its real components, joints driven).
@MainActor
enum GenerateSelfTest {
    static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []

        // A small bracket through the job API.
        var s = GenerateModel.study(.cantilever)
        s.voxel = 4
        s.iterations = 12
        s.variants = 1
        do {
            let job = try GenerateJob(json: try GenerateEngine.json(s))
            var steps = Set<Int>()
            while job.progress.running {
                steps.insert(job.progress.iteration)
                Thread.sleep(forTimeInterval: 0.01)
            }
            let o = try job.outcome()
            let p = job.progress
            out.append((p.fraction == 1 && p.iterations == 12 && !o.candidates.isEmpty,
                        "generative job reports progress (\(steps.count) iteration counts seen, \(o.candidates.count) candidate)"))
            let d = DesignModel()
            let undo = d.snapshot.undo
            let t = Date()
            let built = try job.build(candidate: nil, into: SessionHandle(pointer: d.engine.session))
            d.refresh()
            out.append((d.snapshot.bodies.contains { $0.name.contains(built.body) } && d.snapshot.undo == undo + 1 && Date().timeIntervalSince(t) < 5,
                        "generated candidate inserted as a mesh body in one undo step, without a second run (\(built.body))"))
        } catch {
            out.append((false, "generative job: \(error.localizedDescription)"))
        }
        do {
            var big = s
            big.voxel = 1
            big.iterations = 400
            let job = try GenerateJob(json: try GenerateEngine.json(big))
            while job.progress.iteration < 1 && job.progress.running { Thread.sleep(forTimeInterval: 0.01) }
            job.cancel()
            let t = Date()
            var message = ""
            do { _ = try job.outcome() } catch { message = error.localizedDescription }
            out.append((message == "cancelled" && Date().timeIntervalSince(t) < 10, "generative job cancels (\(message), \(String(format: "%.1f", Date().timeIntervalSince(t))) s)"))
        } catch {
            out.append((false, "generative cancel: \(error.localizedDescription)"))
        }
        // The grasp test reads the hand into a model of its own: the Generate project stays.
        do {
            let g = GenerateModel(reading: "drone")
            let studies = g.project?.studies.count ?? 0
            let hand = GenerateModel(reading: "hand")
            out.append((g.project?.name == "drone" && g.project?.studies.count == studies && hand.project?.name == "hand" && !hand.joints.isEmpty,
                        "grasp test reads the hand (\(hand.joints.count) joints) without touching the Generate project (\(g.project?.name ?? "none"))"))
        }
        // Stopped mid-run, the job keeps its best design so far: a surfaced candidate flagged
        // not converged with the iteration it stopped at; a second stop changes nothing.
        do {
            var big = s
            big.voxel = 2
            big.iterations = 400
            let job = try GenerateJob(json: try GenerateEngine.json(big))
            while job.progress.iteration < 20 && job.progress.running { Thread.sleep(forTimeInterval: 0.01) }
            job.cancel()
            job.cancel()
            let o = try job.summary()
            let c = o.stoppedCandidate
            let at = c?.stoppedAt ?? 0
            out.append((o.stopped && c != nil && !(c?.converged ?? true) && at >= 20 && at < 400 && (c?.mesh.triangleCount ?? 0) > 0 && !job.progress.running,
                        "generative stop keeps the best so far (stopped at \(at), kept \(c?.keptIteration ?? 0), \(c?.mesh.triangleCount ?? 0) triangles)"))
        } catch {
            out.append((false, "generative stop and keep: \(error.localizedDescription)"))
        }

        // Live progress: the history grows while the study solves, a coarse shape comes back
        // mid-run, pausing holds the iteration count, the ETA shows, and the results open
        // (figures and surfaces) in under a second once the engine is done.
        do {
            var live = s
            live.voxel = 2
            live.iterations = 24
            let job = try GenerateJob(json: try GenerateEngine.json(live))
            var midHistory = 0, midPreview = 0, version = 0
            var eta: Double?
            var held = true
            while job.progress.running {
                let p = job.progress
                if p.iteration >= 4 && midPreview == 0 {
                    midHistory = job.history(from: 0).count
                    if let pv = job.preview(since: 0) { midPreview = pv.mesh.triangleCount; version = pv.version }
                    job.setPaused(true)
                    Thread.sleep(forTimeInterval: 0.3)
                    let a = job.progress.iteration
                    Thread.sleep(forTimeInterval: 0.6)
                    let b = job.progress
                    held = b.paused && b.iteration <= a + 1 && b.running
                    eta = b.eta
                    job.setPaused(false)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            let t = Date()
            let o = try job.summary()
            let previews = o.candidates.map { PreviewMesh.make($0, study: live) }
            let open = Date().timeIntervalSince(t)
            let h = job.history(from: 0)
            let figures = h.allSatisfy { $0.compliance > 0 && $0.volume > 0 && $0.maxStress.isFinite }
            out.append((midHistory >= 4 && midHistory < live.iterations && midPreview > 0 && version > 0,
                        "generative live: \(midHistory) iterations and a \(midPreview)-triangle shape while solving"))
            out.append((held && eta != nil, "generative live: pause holds the run, ETA \(eta.map { String(format: "%.1f s", $0) } ?? "none")"))
            out.append((h.count == live.iterations && figures, "generative live: \(h.count) iterations of compliance, volume and peak stress"))
            out.append((open < 1 && previews.allSatisfy { !$0.isEmpty } && o.candidates.allSatisfy { $0.cost != nil },
                        "generative results open in \(String(format: "%.3f", open)) s (summary and surfaces)"))
        } catch {
            out.append((false, "generative live: \(error.localizedDescription)"))
        }

        // Outcomes (VIAFORM-SPEC 7.10.3): mesh checks from the engine on every candidate, the
        // gallery's sorts, the Pareto front, the compare figures, and export in each format.
        do {
            var multi = s
            multi.voxel = 3
            multi.iterations = 12
            multi.variants = 3
            let job = try GenerateJob(json: try GenerateEngine.json(multi))
            let o = try job.summary()
            let request = GenerateModel.checkRequest(multi, route: nil)
            let t = Date()
            let reports = try o.candidates.map { try GenerateEngine.checkMesh($0.mesh, request: request) }
            let checkSeconds = Date().timeIntervalSince(t)
            let ids = ["watertight", "manifold", "bodies", "min_wall", "overhangs", "voids", "triangles"]
            let complete = reports.allSatisfy { $0.items.map(\.id) == ids }
            let closed = reports.allSatisfy { $0.item("watertight")?.status == .pass && $0.item("manifold")?.status == .pass }
            let walls = reports.compactMap(\.minWall)
            out.append((o.candidates.count == 3 && complete && closed && walls.count == 3 && walls.allSatisfy { $0 > 0 },
                        "mesh checks: \(reports.count) candidates watertight and manifold, thinnest walls \(walls.map { String(format: "%.2f", $0) }.joined(separator: "/")) mm in \(String(format: "%.2f", checkSeconds)) s"))
            var printed = multi
            printed.manufacturing.process = .additive
            let fdm = try GenerateEngine.checkMesh(o.candidates[0].mesh, request: GenerateModel.checkRequest(printed, route: nil))
            let sls = try GenerateEngine.checkMesh(o.candidates[0].mesh, request: GenerateModel.checkRequest(multi, route: .sls))
            out.append((fdm.item("overhangs")?.status != .skipped && fdm.item("min_wall")?.limit == 0.8
                        && reports[0].item("overhangs")?.status == .skipped && sls.item("min_wall")?.limit == 0.7,
                        "mesh checks follow the process: additive overhangs \(fdm.item("overhangs")?.status.word ?? "none"), walls held to 0.8 mm (FDM) and 0.7 mm (SLS)"))
            let empty = try GenerateEngine.checkMesh(StudyMesh(), request: "{}")
            out.append((empty.item("watertight")?.status == .fail && !empty.passed, "mesh checks fail an empty surface instead of passing it"))

            // Sorts: each a permutation, in order by its figure.
            let cs = o.candidates
            func sorted(_ by: OutcomeSort, _ key: (StudyCandidate) -> Double, ascending: Bool) -> Bool {
                let order = by.ordered(cs)
                guard Set(order) == Set(cs.indices), order.count == cs.count else { return false }
                let keys = order.map { key(cs[$0]) }
                return zip(keys, keys.dropFirst()).allSatisfy { ascending ? $0 <= $1 : $0 >= $1 }
            }
            let sorts = [
                sorted(.mass, { $0.massG }, ascending: true),
                sorted(.safety, { $0.analysis.safetyFactor.isFinite ? $0.analysis.safetyFactor : .greatestFiniteMagnitude }, ascending: false),
                sorted(.stress, { $0.analysis.worstStress }, ascending: true),
                sorted(.displacement, { $0.analysis.worstDisplacement }, ascending: true),
                sorted(.cost, { $0.cost ?? .greatestFiniteMagnitude }, ascending: true),
                sorted(.iteration, { Double($0.keptIteration ?? $0.history.count) }, ascending: true),
            ]
            out.append((sorts.allSatisfy { $0 }, "outcome sorts: mass, safety factor, stress, displacement, cost and iterations each order all \(cs.count) candidates"))

            // Pareto front: not empty, holds the lightest, and no member is beaten on both axes.
            let front = GenerateModel.paretoFront(cs)
            let lightest = cs.indices.min { cs[$0].massG < cs[$1].massG }
            func sf(_ c: StudyCandidate) -> Double { c.analysis.safetyFactor.isFinite ? c.analysis.safetyFactor : .greatestFiniteMagnitude }
            let undominated = front.allSatisfy { i in !cs.indices.contains { j in j != i && cs[j].massG < cs[i].massG && sf(cs[j]) > sf(cs[i]) } }
            out.append((!front.isEmpty && lightest.map(front.contains) == true && undominated,
                        "Pareto front: \(front.count) of \(cs.count) candidates, lightest on it"))

            // Compare: the difference reads in its unit with a verdict in words.
            let heavier = CompareSheet.Row(id: "mass", label: "Mass", a: 100, b: 112, format: { VFFormat.mass($0) }, better: -1, unit: "g")
            let safer = CompareSheet.Row(id: "sf", label: "Safety factor", a: 2, b: 3, format: formatFactor, better: 1, unit: "")
            let same = CompareSheet.Row(id: "f1", label: "First mode", a: 50, b: 50, format: { VFFormat.value($0, .frequency) }, better: 1, unit: "Hz")
            let missing = CompareSheet.Row(id: "cost", label: "Cost", a: nil, b: 3, format: { VFFormat.money($0) }, better: -1, unit: "USD")
            let h = CompareSheet.diffText(heavier), sa = CompareSheet.diffText(safer)
            out.append((h.text.hasPrefix("+12 g (+12 %)") && h.verdict == -1 && sa.verdict == 1 && sa.text.contains("B better")
                        && CompareSheet.diffText(same).verdict == 0 && CompareSheet.diffText(missing).text == "–",
                        "compare: \(h.text); \(sa.text)"))

            // Export: every format written where asked; a missing folder says why.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vf-export-selftest-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var written: [String] = []
            for f in MeshExportFormat.allCases {
                let url = dir.appendingPathComponent("candidate.\(f.rawValue)")
                let bytes = try GenerateEngine.exportMesh(cs[0].mesh, to: url, format: f, name: "Self test")
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
                if bytes > 0 && size == bytes { written.append("\(f.title) \(bytes / 1024) KB") }
            }
            var failure = ""
            do { _ = try GenerateEngine.exportMesh(cs[0].mesh, to: dir.appendingPathComponent("no/such/candidate.stl"), format: .stl, name: "x") } catch { failure = error.localizedDescription }
            try? FileManager.default.removeItem(at: dir)
            out.append((written.count == 3 && failure.contains("does not exist"),
                        "export: \(written.joined(separator: ", ")); bad folder reports \"\(failure)\""))
        } catch {
            out.append((false, "generative outcomes: \(error.localizedDescription)"))
        }

        // Inspector sections: a fresh study is complete where it can be, missing its supports
        // when it has none, and a bad value is an error.
        do {
            var bare = s
            bare.supports = []
            var broken = s
            broken.voxel = 0
            broken.safetyFactor = 0.5
            let ok = StudySection.allCases.allSatisfy { s.status($0) == .complete }
            let missing: Bool = if case .missing = bare.status(.supports) { true } else { false }
            let errors: Bool = if case .error = broken.status(.designSpace), case .error = broken.status(.limits) { true } else { false }
            let folds = InspectorFolds.toggled(InspectorFolds.toggled("", "goal", open: false), "limits", open: false)
            let reopened = InspectorFolds.toggled(folds, "goal", open: true)
            out.append((ok && missing && errors && InspectorFolds.folded(folds) == ["goal", "limits"] && InspectorFolds.folded(reopened) == ["limits"],
                        "inspector sections: complete, missing and error statuses; folds remembered (\(folds))"))
        }

        // Variants: volume fraction, material and process run at once, compared, one built.
        do {
            var base = s
            base.iterations = 10
            let json = try GenerateEngine.json(base)
            let plan: [(String, Double, String)] = [("fdm", 0.2, "PLA"), ("sls", 0.25, "PA12"), ("cnc3", 0.2, "Aluminum 6061")]
            let t = Date()
            let jobs = try plan.map { p -> GenerateJob in
                let m = StudyMaterial.presets.first { $0.name == p.2 }!
                let enc = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m))
                return try GenerateJob(json: try GenerateJob.variant(base: json, variant: ["volume_fraction": p.1, "material": enc, "process": p.0]))
            }
            let outcomes = try jobs.map { try $0.summary() }
            let wall = Date().timeIntervalSince(t)
            let best = outcomes.compactMap { $0.candidates[safe: $0.best] }
            let costs = best.compactMap(\.cost)
            let f1 = best.compactMap(\.analysis.firstFrequency)
            out.append((best.count == 3 && costs.count == 3 && f1.count == 3 && Set(costs.map { Int($0) }).count > 1,
                        "generative variants: 3 run at once in \(String(format: "%.1f", wall)) s, costs \(costs.map { String(format: "%.0f", $0) }.joined(separator: "/")) USD, f1 \(f1.map { String(format: "%.0f", $0) }.joined(separator: "/")) Hz"))
            let d = DesignModel()
            let undo = d.snapshot.undo
            let built = try jobs[2].build(candidate: nil, into: SessionHandle(pointer: d.engine.session))
            d.refresh()
            out.append((d.snapshot.undo == undo + 1 && d.snapshot.bodies.contains { $0.name.contains(built.body) },
                        "generative variant picked and built into the design (\(built.body))"))
        } catch {
            out.append((false, "generative variants: \(error.localizedDescription)"))
        }

        // The sample projects.
        for name in GenerateProject.samples {
            guard let p = try? GenerateProject.open(name) else {
                print("SKIP no generative project at docs/generative/\(name)")
                continue
            }
            out.append((!p.studies.isEmpty && p.studies.allSatisfy { $0.study.elementCount > 0 && !$0.study.cases.isEmpty },
                        "\(name): \(p.studies.count) studies read from docs/generative/\(name)/studies"))
            guard let asm = p.assembly else {
                print("SKIP no docs/generative/\(name)/assembly.json")
                continue
            }
            let d = DesignModel()
            do {
                _ = try GenerateEngine.assemble(path: asm.path, into: SessionHandle(pointer: d.engine.session))
                d.refresh()
                let summary = AssemblyJoint.summary(asm)
                let joints = AssemblyJoint.read(asm).filter(\.movable)
                let listed = ((try? d.engine.execute("joint.list")) as? [String: Any])?["joints"] as? [[String: Any]] ?? []
                // The real parts, counted in the inserted design: rows of the bill of materials
                // whose part properties carry the component_ref the file gave them.
                let bom = ((try? d.engine.execute("assembly.bom", ["levels": "flat"])) as? [String: Any])?["rows"] as? [[String: Any]] ?? []
                let tagged = bom.filter { (($0["properties"] as? [String: Any])?["component_ref"]) != nil }
                    .reduce(0) { $0 + (($1["count"] as? Int) ?? Int(($1["count"] as? Double) ?? 0)) }
                out.append((d.assembly.count >= summary.parts && summary.components > 0 && tagged == summary.components,
                            "\(name) assembly inserted: \(d.assembly.count) components, \(tagged) of \(summary.components) real parts carry their component_ref, \(listed.count) joints"))
                if let j = joints.first(where: { $0.limits.upperBound - $0.limits.lowerBound > 10 }) {
                    let target = j.fistValue == 0 ? j.limits.upperBound : j.fistValue
                    // The scene is built here, not read from d.scene: a large design (the hand's 153
                    // components) builds its drawn scene on the worker, so d.scene right after
                    // refresh() is still the one from before the drive.
                    let firsts = { d.engine.scene(camera: d.camera).meshes.map { m in m.positions.first.map { [Double($0.x), Double($0.y), Double($0.z)] } ?? [] } }
                    let before = firsts()
                    _ = try d.engine.execute("joint.drive", ["joint": j.name, "values": [String(format: "%.3f deg", target)]])
                    d.refresh()
                    let after = firsts()
                    out.append((before != after, "\(name): joint \(j.name) drives to \(Int(target)) deg and the part moves"))
                }
            } catch {
                out.append((false, "\(name) assembly: \(error.localizedDescription)"))
            }
            // The bill of materials reads the same assembly: made lines from the generated
            // parts, bought lines matched by component_ref, the two refs lists empty.
            let bom = BomModel()
            if let issues = bom.importAssembly(asm) {
                let t = bom.rollup.totals
                out.append((t.madeLines > 0 && t.boughtLines > 0 && issues.isEmpty,
                            "\(name) BOM from assembly.json: \(t.madeLines) made + \(t.boughtLines) bought lines, \(String(format: "%.1f", t.massG)) g, \(String(format: "%.2f", t.totalCost)) USD" + (issues.isEmpty ? "" : ", " + issues.joined(separator: "; "))))
            } else {
                out.append((false, "\(name) BOM: import_assembly failed"))
            }
            // The Generate project lists only the studies of the assembly's generated parts.
            let parts = GenerateProject.generatedParts(asm)
            out.append((p.studies.allSatisfy { parts.contains($0.name) } && (p.firstStudy.map { parts.contains($0.name) } ?? false),
                        "\(name): \(p.studies.count) studies all belong to the assembly, first \(p.firstStudy?.name ?? "none")"))
        }
        return out
    }
}
