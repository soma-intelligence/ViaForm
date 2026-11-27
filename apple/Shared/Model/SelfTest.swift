import Foundation
import simd

/// `--selftest`: drives the model as a user would (clicks at screen points, tool values, done)
/// and prints what the engine reports, then quits. Run: `ViaForm --selftest`.
enum SelfTest {
    static func run() -> Never {
        let m = DesignModel()
        m.viewSize = CGSize(width: 1200, height: 800)
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "PASS" : "FAIL", what, ok ? "" : "(\(m.message ?? "no message"))")
            if !ok { failures += 1 }
        }
        func screen(_ w: SIMD3<Double>) -> CGPoint { m.camera.project(w, size: m.viewSize) }

        // Sketch a rectangle on XY by clicks, then extrude it.
        m.startSketch("XY")
        check(m.sketchOpen, "sketch opens on XY")
        m.tool = .rectangle
        m.click(at: screen([0, 0, 0]), additive: false)
        m.click(at: screen([30, 20, 0]), additive: false)
        m.finishSketch()
        check(m.snapshot.sketches.first?.profiles == 1, "rectangle by two clicks makes one profile")
        m.tool = .extrude
        m.toolValue = 12
        check(m.hasPreview && m.snapshot.bodies.count == 1, "extrude previews a body")
        m.commitTool()
        let v0 = m.snapshot.bodies.first?.volume_mm3 ?? 0
        check(abs(v0 - 30 * 20 * 12) < 1, "extruded volume is 7200 mm³ (got \(v0))")

        // Press pull the top face by picking it on screen.
        m.zoomToFit()
        m.tool = .pressPull
        m.click(at: screen([15, 10, 12]), additive: true)
        check(m.selection.first?.isFace == true, "click picks the top face")
        m.toolValue = 8
        m.commitTool()
        let v1 = m.snapshot.bodies.first?.volume_mm3 ?? 0
        check(abs(v1 - 30 * 20 * 20) < 1, "press pull +8 gives 12000 mm³ (got \(v1))")

        // Fillet a top edge picked on screen.
        m.tool = .fillet
        m.click(at: screen([15, 0, 20]), additive: true)
        check(m.selection.first?.isEdge == true, "click near an edge picks it")
        m.toolValue = 3
        m.commitTool()
        let v2 = m.snapshot.bodies.first?.volume_mm3 ?? 0
        check(v2 < v1 && v2 > v1 - 100, "fillet removes a little material (got \(v2))")

        // Undo goes back one step; a primitive lands where clicked on the ground.
        m.undo()
        check(abs((m.snapshot.bodies.first?.volume_mm3 ?? 0) - v1) < 1, "undo restores the press pull result")
        m.tool = .cylinder
        m.toolValue = 10
        m.click(at: screen([-40, 0, 0]), additive: false)
        check(m.snapshot.bodies.count == 2, "cylinder placed on the ground")
        let scene = m.scene
        check(scene.meshes.count == 2 && scene.meshes.allSatisfy { !$0.edges.isEmpty }, "scene has two meshes with edges")

        // Electronics: the KiCad flow on PCBCraft, by clicks in millimetres.
        let pcb = PCBModel()
        func pcbCheck(_ ok: Bool, _ what: String) {
            print(ok ? "PASS" : "FAIL", what, ok ? "" : "(\(pcb.message ?? "no message"))")
            if !ok { failures += 1 }
        }
        pcb.tool = .place("resistor")
        pcb.click(at: PCBPoint(x: 10.16, y: 10.16), scale: 10)
        pcb.tool = .place("led")
        pcb.click(at: PCBPoint(x: 30.48, y: 10.16), scale: 10)
        pcbCheck(pcb.project?.components.count == 2, "two parts placed by clicks")
        let parts = pcb.project?.components ?? []
        pcb.tool = .wire
        if parts.count == 2 {
            pcb.click(at: parts[0].pinPosition(parts[0].pins[1]), scale: 10)
            pcb.click(at: parts[1].pinPosition(parts[1].pins[0]), scale: 10)
            pcb.click(at: parts[0].pinPosition(parts[0].pins[0]), scale: 10)
            pcb.click(at: parts[1].pinPosition(parts[1].pins[1]), scale: 10)
        }
        pcbCheck(pcb.project?.wires.count == 2 && pcb.project?.nets.count == 2, "two wires by pin clicks make two nets")
        pcb.updateBoard()
        pcbCheck(pcb.project?.board.footprints.count == 2, "update board makes two footprints")
        pcbCheck((pcb.checks?.airwires.count ?? 0) == 2, "two airwires before routing")
        pcb.routeAll()
        pcbCheck(pcb.checks?.airwires.isEmpty == true && (pcb.project?.board.tracks.count ?? 0) >= 2, "route all leaves no airwire")
        let kicad = FileManager.default.temporaryDirectory.appendingPathComponent("viaform-selftest.kicad_pcb")
        try? FileManager.default.removeItem(at: kicad)
        pcb.exportKiCad(to: kicad)
        let text = (try? String(contentsOf: kicad, encoding: .utf8)) ?? ""
        pcbCheck(text.hasPrefix("(kicad_pcb"), "KiCad board exported (\(text.count) chars)")
        pcb.undo()
        pcbCheck(pcb.redoCount == 1, "PCB undo works")


        // ECAD to MCAD: the sample board goes into a 3D design, onto an enclosure, then follows a change.
        let d = DesignModel()
        let board = PCBModel(sample: true)
        d.run("solid.box", ["length": 80, "width": 60, "height": 10, "corner": [-10, -50, 0], "body_name": "Enclosure"])
        let pushErr = PCBLink.push(board, into: d)
        pcbCheck(pushErr == nil && d.snapshot.bodies.contains { $0.name == "PCB Board" } && d.snapshot.bodies.contains { $0.name == "PCB R1" },
                 "board, copper and parts built in 3D \(pushErr ?? "")")
        pcbCheck(PCBLink.linkedRevision(d, board) == board.revision && !board.boardOutOfDate, "3D board tagged with the PCB revision")
        let mountErr = PCBLink.mount(board, in: d, body: "Enclosure", at: [30, -20, 10], normal: [0, 0, 1])
        let joints = (try? d.engine.execute("joint.list") as? [String: Any])?["joints"] as? [[String: Any]] ?? []
        pcbCheck(mountErr == nil && !joints.isEmpty, "board mounted on the enclosure with a rigid group \(mountErr ?? "")")
        let comps = (try? d.engine.execute("component.list") as? [String: Any])?["components"] as? [[String: Any]] ?? []
        let tf = (comps.first { $0["name"] as? String == "PCB LED indicator" }?["occurrences"] as? [[String: Any]])?.first?["transform"] as? [[Double]]
        let seat = tf.flatMap { $0.count == 4 ? Array($0[3].prefix(3)) : nil } ?? []
        pcbCheck(seat.count == 3 && abs(seat[0]) < 1e-6 && abs(seat[1]) < 1e-6 && abs(seat[2] - 10) < 1e-6, "board seated on the enclosure top (at \(seat))")
        board.sheet = .board
        board.move(11, to: PCBPoint(x: 30, y: 30))
        pcbCheck(board.boardOutOfDate, "moving a footprint marks the 3D board out of date")
        let updErr = PCBLink.push(board, into: d)
        let joints2 = (try? d.engine.execute("joint.list") as? [String: Any])?["joints"] as? [[String: Any]] ?? []
        pcbCheck(updErr == nil && !board.boardOutOfDate && joints2.count == joints.count, "update keeps the assembly joint \(updErr ?? "")")

        // The same mount driven by a click, as the UI does it: a face of the enclosure's side.
        d.viewSize = CGSize(width: 1200, height: 800)
        d.setView(.front)
        d.zoomToFit()
        var shown = false
        board.startMount(d) { shown = true }
        d.click(at: d.camera.project([-5, -50, 3], size: d.viewSize), additive: false)
        pcbCheck(shown && d.facePick == nil && d.message?.contains("mounted") == true, "mount by clicking a face (\(d.message ?? ""))")

        // Generative design: a study as an engine job, and the sample projects' assemblies.
        for (ok, what) in MainActor.assumeIsolated({ GenerateSelfTest.checks() }) { check(ok, what) }
        for (ok, what) in MainActor.assumeIsolated({ MapsSelfTest.checks() }) { check(ok, what) } // P1-33 canvas maps

        // UI-UX-AUDIT P0-11: project save and open, BOM part import and the joint list off the main actor.
        for (ok, what) in MainActor.assumeIsolated({ BomSelfTest.checks() }) { check(ok, what) }
        // P0-1, P0-2, P0-10 follow-ups: undo names, the edited mark, exact-step toasts.
        for (ok, what) in MainActor.assumeIsolated({ ProjectSelfTest.checks() }) { check(ok, what) }
        // P1-5 typed command forms, P1-12 body rename (CommonViews.swift).
        for (ok, what) in MainActor.assumeIsolated({ CommandFormSelfTest.checks() }) { check(ok, what) }
        for (ok, what) in UnitSettingsSelfTest.checks() { check(ok, what) } // P2-23 display units
        for (ok, what) in MainActor.assumeIsolated({ UnitStringsSelfTest.checks() }) { check(ok, what) } // P2-23 unit strings
        for (ok, what) in MainActor.assumeIsolated({ ViewportAccessibilitySelfTest.checks() }) { check(ok, what) }
        for (ok, what) in MainActor.assumeIsolated({ CameraFlightSelfTest.checks() }) { check(ok, what) }
        for (ok, what) in MainActor.assumeIsolated({ AboutCreditsSelfTest.checks() }) { check(ok, what) } // P3-14 credits
        // CAD UI gaps (docs/research/cad-ui/gaps.md), 2026-11-24.
        for (ok, what) in MainActor.assumeIsolated({ SketchSelfTest.checks() }) { check(ok, what) } // B-1 to B-5, B-9
        for (ok, what) in MainActor.assumeIsolated({ SketchCoreSelfTest.checks() }) { check(ok, what) } // B-6, B-8, B-11, B-12, M-6, M-8, M-9, M-16, T-7, T-8, T-11
        for (ok, what) in MainActor.assumeIsolated({ ParametersSelfTest.checks() }) { check(ok, what) } // B-10, B-14, M-21
        for (ok, what) in MainActor.assumeIsolated({ FeatureDialogSelfTest.checks() }) { check(ok, what) } // B-7, M-2, M-4
        for (ok, what) in MainActor.assumeIsolated({ RenderToolsSelfTest.checks() }) { check(ok, what) } // B-13, B-15
        for (ok, what) in MainActor.assumeIsolated({ TouchPanelsSelfTest.checks() }) { check(ok, what) } // T-1, T-13, T-14
        #if os(macOS)
        for (ok, what) in MainActor.assumeIsolated({ MacChromeSelfTest.checks() }) { check(ok, what) } // M-7, M-12, M-15, M-18, M-19
        for (ok, what) in MainActor.assumeIsolated({ MacBrowserSelfTest.checks() }) { check(ok, what) } // M-13, M-14
        for (ok, what) in MainActor.assumeIsolated({ MacSketchUISelfTest.checks() }) { check(ok, what) } // M-1, M-3, M-9, M-10, M-11
        for (ok, what) in MainActor.assumeIsolated({ MacDocsSelfTest.checks() }) { check(ok, what) } // M-20, sketch ribbon tools
        #endif
        #if os(iOS)
        for (ok, what) in MainActor.assumeIsolated({ TouchChromeSelfTest.checks() }) { check(ok, what) } // T-4, T-5, T-12, T-15
        for (ok, what) in MainActor.assumeIsolated({ TouchSketchUISelfTest.checks() }) { check(ok, what) } // T-2, T-12, T-14, T-17
        for (ok, what) in MainActor.assumeIsolated({ TouchSketchToolsSelfTest.checks() }) { check(ok, what) } // B-11 on touch
        #endif
        #if os(macOS)
        let alertOK = MainActor.assumeIsolated { () -> Bool in
            let a = FileActions.failureAlert(url: URL(fileURLWithPath: "/tmp/x.viaform"), reason: "Disk full")
            return a.buttons.map { $0.title } == [String(localized: "Try Again"), String(localized: "Save As…"), String(localized: "Cancel")]
                && a.informativeText.hasPrefix("Disk full")
        }
        check(alertOK, "P0-4 a failed save offers Try Again (default), Save As, Cancel and says why")
        for (ok, what) in CompactLayoutSelfTest.checks() { check(ok, what) }
        #endif

        // Simulation: the Rust flight model (sim/), through the bridge.
        for (ok, what) in MainActor.assumeIsolated({ simulationChecks() }) { check(ok, what) }

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    private static func simulationChecks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let sim = SimModel()
        out.append((sim.error == nil && sim.world?.obstacles.isEmpty == false, "simulation core loads a course \(sim.error ?? "")"))
        out.append(((sim.catalog?.weathers.count ?? 0) >= 5 && sim.parts?.parts.isEmpty == false, "simulation lists weathers and parts"))
        sim.runToEnd()
        out.append((sim.status?.finished == true && sim.status?.collided == false && sim.status?.crashed == false,
                    "trained drone flies the obstacle course: \(sim.outcome ?? "not finished")"))
        out.append((sim.trail.count > 100, "flight leaves a trail (\(sim.trail.count) points)"))
        sim.options.weather = 2
        sim.options.brain = "pid"
        sim.reset()
        out.append((sim.frame?.t == 0 && sim.trail.count == 1, "reset puts the drone back on the start"))
        var stress = SimOptions()
        stress.mission = "stress"
        stress.brain = "indi"
        stress.weather = 1
        let bench = SimEngine().episode(stress)
        out.append((bench?.crashed == false && (bench?.attitudeRms ?? 1) < 0.12,
                    "stabilized drone rides out the stress test on the realistic plant (attitude rms \(bench.map { String(format: "%.3f", $0.attitudeRms) } ?? "none"))"))
        // The race: the countdown holds the drone, then the sticks fly it.
        let race = SimModel()
        race.options.mission = "manual"
        race.reset()
        race.advance(3.2)
        race.sticks = SimSticks(z: 0.8)
        race.advance(1.5)
        out.append((race.race?.state == "flying" && (race.frame?.p[2] ?? 0) > 1, "manual race: countdown, then the throttle stick climbs (\(race.race?.state ?? "no race"))"))
        // Training: a short run reports its curve and a brain that flies.
        let training = SimTraining()
        training.iterations = 2
        training.population = 4
        training.episodes = 2
        training.runToEnd()
        out.append((training.history.count == 2 && training.brainJSON != nil, "training runs on the core and returns a brain (\(training.history.count) iterations)"))
        if let brain = training.brainJSON {
            let flown = SimModel()
            flown.options.mission = "hover"
            flown.flyTrained(brain)
            flown.reset()
            flown.runToEnd(limit: 20)
            out.append((flown.status?.crashed == false, "the trained brain holds a hover"))
        }
        // The generated frame, when the generative design has written one.
        let gen = SimModel()
        if let g = gen.generatedFrame {
            if case .failure(let e) = g.airframe {
                out.append((false, "generated frame reads: \(e.message)"))
            } else {
                gen.useGeneratedFrame = true
                gen.reset()
                gen.runToEnd(limit: 60)
                out.append((gen.airframe != nil && gen.status?.finished == true && gen.status?.collided == false && gen.status?.crashed == false,
                            "drone on the generated frame flies the obstacle course: \(gen.outcome ?? "not finished") (\(gen.airframe.map { String(format: "%.0f g, %.1f mm arm", $0.massKg * 1000, $0.armMm) } ?? "nominal"))"))
            }
        } else {
            print("SKIP no generated frame at docs/generative/drone-frame.json: the nominal drone flies")
        }
        // The drone from its sourced components, when the parts agent has written them.
        let real = SimModel()
        if let r = real.realParts {
            switch r.vehicle {
            case .failure(let e):
                out.append((false, "sourced components read: \(e.message)"))
            case .success(let v):
                real.useRealParts = true
                real.reset()
                real.runToEnd(limit: 60)
                out.append((real.status?.finished == true && real.status?.collided == false && real.status?.crashed == false && real.frame.map { $0.planIndex >= real.waypointCount - 1 } == true,
                            "real-parts drone flies the obstacle course: \(real.outcome ?? "not finished") (\(String(format: "%.0f g, T/W %.1f", v.massKg * 1000, v.thrustToWeight)), \(v.assembly ? "assembly" : "standard positions"))"))
                // What flew is the generated drone: its frame file and the assembly's placements,
                // not standard positions on the nominal frame. The assembly is read fresh here.
                if let asmText = r.assembly {
                    let parts = ((try? JSONSerialization.jsonObject(with: Data(asmText.utf8))) as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                    let components = parts.filter { ($0["kind"] as? String) == "component" }
                    let motorRef = v.components.first { $0.category.lowercased().contains("motor") }?.ref
                    let flown = real.vehicle
                    let usesFrame = flown?.frame != nil && real.generatedFrame != nil
                    let placedAll = flown.map { $0.assembly && $0.placements == components.count && $0.placed >= components.count * 9 / 10 } ?? false
                    let motorsPlaced = motorRef.map { flown?.placedRefs.contains($0) == true } ?? false
                    out.append((usesFrame && placedAll && motorsPlaced,
                                "real-parts drone is the generated one: frame \(flown?.frame.map { String(format: "%@ %.1f g, %.1f mm arm", $0.name, $0.frameG, $0.armMm) } ?? "none"), \(flown?.placed ?? 0) of \(components.count) components placed by assembly.json (\(flown?.placements ?? 0) read), motors \(motorsPlaced ? "placed" : "at standard tips")"))
                } else {
                    out.append((false, "real-parts drone: no docs/generative/drone/assembly.json to place the components"))
                }
            }
        } else {
            print("SKIP no sourced components at docs/components/drone.json: the built-in parts list flies")
        }
        return out
    }
}
