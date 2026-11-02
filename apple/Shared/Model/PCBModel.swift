import Foundation
import Observation

/// The electronics workspace: one PCBCraft project seen as a schematic or as a board.
/// The flow is the KiCad one: place parts and wire pins in the schematic, update the board,
/// place footprints, route the airwires, check the rules, export a `.kicad_pcb`.
@Observable
final class PCBModel {
    enum Sheet: String, CaseIterable { case schematic = "Schematic", board = "Board" }

    enum Tool: Equatable {
        case select
        case place(String)
        case wire
        case route
    }

    private(set) var engine: PCBEngine
    var project: PCBProject?
    var checks: PCBChecks?
    var revision = 0
    /// The PCB revision the 3D design's board was built from; nil when it was never sent.
    var linkedRevision: Int?
    var undoCount = 0
    var redoCount = 0
    var sheet: Sheet = .schematic
    var tool: Tool = .select { didSet { pending = nil } }
    var layer = "F.Cu"
    var trackWidth = 0.4
    var selection: Int?
    /// The first pin of a wire, or the first pad of a route, waiting for the second click.
    var pending: (object: Int, pin: String)?
    var message: String?
    var messageIsError = false

    static let partKinds = ["resistor", "capacitor", "led", "connector"]

    init(sample: Bool = false) {
        engine = PCBEngine(sample: sample)
        refresh()
    }

    func refresh() {
        if let i = engine.inspect() {
            project = i.project
            revision = i.revision
            undoCount = i.history.undo
            redoCount = i.history.redo
        }
        checks = engine.checks()
    }

    @discardableResult
    func run(_ id: String, _ params: [String: Any] = [:]) -> Any? {
        do {
            let r = try engine.execute(id, params)
            message = nil
            refresh()
            return r
        } catch {
            message = error.localizedDescription
            messageIsError = true
            return nil
        }
    }

    func undo() { run("undo") }
    func redo() { run("redo") }

    // MARK: Lookups

    var nets: [Int: String] { Dictionary(uniqueKeysWithValues: (project?.nets ?? []).map { ($0.id, $0.name) }) }

    func component(_ id: Int) -> PCBComponent? { project?.components.first { $0.id == id } }
    func footprint(_ id: Int) -> PCBFootprint? { project?.board.footprints.first { $0.id == id } }

    /// The schematic pin nearest to `p`, within `radius` millimetres.
    func pin(near p: PCBPoint, radius: Double) -> (PCBComponent, PCBPin)? {
        var best: (PCBComponent, PCBPin, Double)?
        for c in project?.components ?? [] {
            for pin in c.pins {
                let d = c.pinPosition(pin).distance(to: p)
                if d < radius, d < (best?.2 ?? .infinity) { best = (c, pin, d) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// The board pad nearest to `p`, within its own radius plus `slack`.
    func pad(near p: PCBPoint, slack: Double) -> (PCBFootprint, PCBPad)? {
        var best: (PCBFootprint, PCBPad, Double)?
        for f in project?.board.footprints ?? [] {
            for pad in f.pads {
                let d = f.padPosition(pad).distance(to: p)
                if d < pad.diameter / 2 + slack, d < (best?.2 ?? .infinity) { best = (f, pad, d) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// The object under `p` on the current sheet: a component body or a footprint.
    func object(at p: PCBPoint) -> Int? {
        switch sheet {
        case .schematic:
            return project?.components.min { $0.position.distance(to: p) < $1.position.distance(to: p) }
                .flatMap { $0.position.distance(to: p) < 6 ? $0.id : nil }
        case .board:
            return project?.board.footprints.min { $0.position.distance(to: p) < $1.position.distance(to: p) }
                .flatMap { $0.position.distance(to: p) < 5 ? $0.id : nil }
        }
    }

    // MARK: Clicks

    /// One click on the sheet, in millimetres.
    func click(at p: PCBPoint, scale: Double) {
        let slack = 8 / max(scale, 0.01)
        switch tool {
        case .select:
            selection = object(at: p)
        case let .place(kind):
            let snapped = PCBPoint(x: (p.x / 2.54).rounded() * 2.54, y: (p.y / 2.54).rounded() * 2.54)
            if let r = run("component.add", ["kind": kind, "position": ["x": snapped.x, "y": snapped.y]]) as? [String: Any],
               let id = (r["result"] as? [String: Any])?["id"] as? Int { selection = id }
        case .wire:
            guard let (c, pin) = pin(near: p, radius: max(slack, 1.5)) else { return }
            if let first = pending {
                if first.object != c.id || first.pin != pin.number {
                    run("wire.connect", ["from": ["component": first.object, "pin": first.pin], "to": ["component": c.id, "pin": pin.number]])
                }
                pending = nil
            } else {
                pending = (c.id, pin.number)
            }
        case .route:
            guard let (f, pad) = pad(near: p, slack: slack) else { return }
            if let first = pending {
                if first.object != f.id || first.pin != pad.number {
                    run("track.route", ["from": ["footprint": first.object, "pad": first.pin], "to": ["footprint": f.id, "pad": pad.number],
                                        "width": trackWidth, "layer": layer])
                }
                pending = nil
            } else {
                pending = (f.id, pad.number)
            }
        }
    }

    /// Ends a drag of the selected part: components on the schematic, footprints on the board.
    func move(_ id: Int, to p: PCBPoint) {
        let at = ["x": (p.x * 100).rounded() / 100, "y": (p.y * 100).rounded() / 100]
        run(sheet == .schematic ? "component.move" : "footprint.move", ["id": id, "position": at])
    }

    func rotateSelection() {
        guard let id = selection else { return }
        if sheet == .schematic, let c = component(id) {
            run("component.rotate", ["id": id, "degrees": (c.rotation + 90).truncatingRemainder(dividingBy: 360)])
        } else if let f = footprint(id) {
            run("footprint.rotate", ["id": id, "degrees": (f.rotation + 90).truncatingRemainder(dividingBy: 360)])
        }
    }

    func deleteSelection() {
        guard let id = selection else { return }
        run("object.delete", ["id": id])
        selection = nil
    }

    /// Schematic to board: footprints for new parts, nets onto pads.
    func updateBoard() {
        run("board.sync")
        sheet = .board
    }

    /// Routes every airwire with the engine's orthogonal router, one at a time.
    func routeAll() {
        guard let wires = checks?.airwires, !wires.isEmpty else { message = "Nothing left to route"; messageIsError = false; return }
        var routed = 0
        for a in wires {
            guard let (f1, p1) = pad(near: a.from, slack: 0.05), let (f2, p2) = pad(near: a.to, slack: 0.05) else { continue }
            if (try? engine.execute("track.route", ["from": ["footprint": f1.id, "pad": p1.number], "to": ["footprint": f2.id, "pad": p2.number],
                                                    "width": trackWidth, "layer": layer])) != nil { routed += 1 }
        }
        refresh()
        message = "Routed \(routed) of \(wires.count) connections"
        messageIsError = routed < wires.count
    }

    func newProject() {
        engine = PCBEngine()
        selection = nil
        tool = .select
        sheet = .schematic
        refresh()
    }

    func loadSample() {
        engine = PCBEngine(sample: true)
        selection = nil
        refresh()
    }

    func open(_ url: URL) { run("file.open", ["path": url.path]); sheet = .schematic }
    func save(to url: URL) { if run("file.save", ["path": url.path]) != nil { message = "Saved \(url.lastPathComponent)"; messageIsError = false } }
    func exportKiCad(to url: URL) {
        if run("file.export_kicad", ["path": url.path]) != nil { message = "Exported \(url.lastPathComponent)"; messageIsError = false }
    }

    /// The 3D board exists but was built from an older revision.
    var boardOutOfDate: Bool { linkedRevision.map { $0 != revision } ?? false }

    var findings: [PCBChecks.Finding] { (checks?.erc ?? []) + (checks?.drc ?? []) }
}
