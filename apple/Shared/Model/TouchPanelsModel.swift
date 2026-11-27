import CoreGraphics
import Foundation

// The engine side of the touch History and Items panels (gaps T-1, T-13, T-14, B-10, B-14):
// every action is one engine command. The views live in Touch/TouchHistoryPanel.swift and
// Touch/TouchItemsPanel.swift; this file is shared so `--selftest` can run it on the Mac too.

/// One row of the History list: a feature, or the breakpoint bar (the history marker).
enum HistoryEntry: Hashable {
    case feature(Int)
    case breakpoint
}

/// What dropping a dragged History row does.
enum HistoryMove: Equatable {
    case none
    /// Move the breakpoint: keep this many features active.
    case roll(Int)
    /// Move a feature to `position` in the timeline, before (active) or behind the breakpoint.
    case reorder(feature: Int, position: Int, active: Bool)
}

/// Why a panel action did not run, in the engine's words.
struct PanelError: Error, Equatable {
    var message: String
}

/// What a touch panel acts on in the Items list.
struct PanelItem: Hashable, Identifiable {
    enum Kind: String, CaseIterable { case body, sketch, construction }
    var kind: Kind
    /// The body name, or the feature name of a sketch or a construction plane, axis or point.
    var name: String
    /// The feature id of a sketch or construction item.
    var feature: Int?
    var id: String { "\(kind.rawValue):\(feature.map(String.init) ?? name)" }

    /// The browser key (`browser.group`, `browser.move`) and folder it lives in.
    var browserKey: String { kind == .body ? name : String(feature ?? 0) }
    var browserFolder: String {
        switch kind {
        case .body: "bodies"
        case .sketch: "sketches"
        case .construction: "construction"
        }
    }
}

@MainActor
enum PanelOps {
    /// Runs one command. Nil when it worked; else the engine's reason, taken off the status line
    /// so the panel can show it inline.
    @discardableResult
    static func run(_ model: DesignModel, _ id: String, _ params: [String: Any] = [:]) -> String? {
        if model.run(id, params, quiet: true) != nil { return nil }
        let why = model.message ?? String(localized: "The command did not run.")
        model.flash(nil)
        return why
    }

    // MARK: History order and breakpoint (T-13)

    /// The number of active features: everything before the first rolled back one.
    static func marker(_ s: DesignSnapshot) -> Int {
        s.timeline.firstIndex(where: { $0.rolled_back == true }) ?? s.timeline.count
    }

    /// The History rows: the features in order, with the breakpoint bar where the marker is
    /// (only when it holds some features back).
    static func entries(_ s: DesignSnapshot) -> [HistoryEntry] {
        var out = s.timeline.map { HistoryEntry.feature($0.id) }
        let m = marker(s)
        if m < s.timeline.count { out.insert(.breakpoint, at: m) }
        return out
    }

    /// Where a row dropped at `y` lands: the rows (other than the dragged one) whose middle is
    /// above it.
    static func slot(at y: CGFloat, mids: [HistoryEntry: CGFloat], order: [HistoryEntry], dragged: HistoryEntry) -> Int {
        order.filter { $0 != dragged }.filter { (mids[$0] ?? .greatestFiniteMagnitude) < y }.count
    }

    /// The command a drop makes: `slot` is the index among the other rows.
    static func drop(_ entries: [HistoryEntry], dragged: HistoryEntry, slot: Int) -> HistoryMove {
        guard let from = entries.firstIndex(of: dragged) else { return .none }
        var e = entries
        e.remove(at: from)
        let at = min(max(slot, 0), e.count)
        e.insert(dragged, at: at)
        if e == entries { return .none }
        let features = e.filter { $0 != .breakpoint }
        let bar = e.firstIndex(of: .breakpoint)
        switch dragged {
        case .breakpoint:
            return .roll(e.prefix(at).count)
        case .feature(let id):
            // Same feature order: only the bar moved past it.
            if features == entries.filter({ $0 != .breakpoint }), let bar {
                return .roll(e.prefix(bar).count)
            }
            let position = features.firstIndex(of: dragged) ?? 0
            return .reorder(feature: id, position: position, active: bar.map { at < $0 } ?? true)
        }
    }

    @discardableResult
    static func apply(_ move: HistoryMove, _ model: DesignModel) -> String? {
        switch move {
        case .none: return nil
        case .roll(let n):
            return n >= model.snapshot.timeline.count ? run(model, "timeline.roll_to", ["position": "end"])
                                                      : run(model, "timeline.roll_to", ["position": n])
        case let .reorder(feature, position, active):
            return run(model, "timeline.reorder", ["feature": feature, "position": position, "active": active])
        }
    }

    /// Insert Breakpoint on a row: the marker goes right after it.
    @discardableResult
    static func insertBreakpoint(after index: Int, _ model: DesignModel) -> String? {
        run(model, "timeline.roll_to", ["position": index + 1])
    }

    @discardableResult
    static func deleteBreakpoint(_ model: DesignModel) -> String? {
        run(model, "timeline.roll_to", ["position": "end"])
    }

    @discardableResult
    static func renameFeature(_ id: Int, to name: String, _ model: DesignModel) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return String(localized: "A step needs a name.") }
        if model.snapshot.timeline.first(where: { $0.id == id })?.name == n { return nil }
        return run(model, "timeline.rename", ["feature": id, "name": n])
    }

    /// "Related to Selection": the features that made the selected bodies, the ones built on
    /// them and the ones they are built on (`timeline.dependents`).
    static func related(_ model: DesignModel, bodies: [String]) -> Set<Int> {
        guard !bodies.isEmpty,
              let r = (try? model.engine.execute("document.inspect", ["measure": false])) as? [String: Any],
              let list = r["bodies"] as? [[String: Any]] else { return [] }
        let wanted = Set(bodies)
        let makers = Set(list.compactMap { b -> Int? in
            guard let n = b["name"] as? String, wanted.contains(n) else { return nil }
            return (b["feature"] as? NSNumber)?.intValue
        })
        guard !makers.isEmpty else { return [] }
        let timeline = model.snapshot.timeline
        let ids = Dictionary(timeline.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        func dependents(_ id: Int) -> Set<Int> {
            guard let d = (try? model.engine.execute("timeline.dependents", ["feature": id])) as? [String: Any] else { return [] }
            let names = (d["deleted_with_it"] as? [String] ?? []) + (d["would_fail"] as? [String] ?? [])
            return Set(names.compactMap { ids[$0] })
        }
        var out = makers
        for m in makers { out.formUnion(dependents(m)) }
        let last = timeline.lastIndex(where: { makers.contains($0.id) }) ?? -1
        for (i, f) in timeline.enumerated() where i < last && !out.contains(f.id) {
            if !dependents(f.id).isDisjoint(with: makers) { out.insert(f.id) }
        }
        return out
    }

    // MARK: Edit Feature in the row (T-1)

    /// The feature's type and editable values (`timeline.inspect`), or why not.
    static func inspect(_ id: Int, _ model: DesignModel) -> Result<(type: String, fields: [FeatureField]), Error> {
        do {
            let r = try model.engine.execute("timeline.inspect", ["feature": id]) as? [String: Any] ?? [:]
            let def = r["definition"] as? [String: Any] ?? [:]
            return .success((r["type_name"] as? String ?? "", FeatureField.flatten(def)))
        } catch {
            return .failure(error)
        }
    }

    /// A typed value: a number stays a number, anything else (an expression, a parameter name,
    /// a value with its unit) goes as text for the engine to read.
    static func set(_ field: inout FeatureField, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.value {
        case .number:
            if let n = Double(t) { field.value = .number(n) } else { field.value = .text(t) }
        case .text:
            field.value = .text(t)
        case .flag:
            break
        }
    }

    static func text(_ field: FeatureField) -> String {
        switch field.value {
        case .text(let s): s
        case .number(let n): VFFormat.editable(n)
        case .flag(let b): b ? "true" : "false"
        }
    }

    /// Sends only what changed to `timeline.edit` (one undo step).
    @discardableResult
    static func edit(_ id: Int, from before: [FeatureField], to after: [FeatureField], _ model: DesignModel) -> String? {
        let set = FeatureField.changes(from: before, to: after)
        if set.isEmpty { return nil }
        return run(model, "timeline.edit", ["feature": id, "set": set])
    }

    static func isSketch(_ f: DesignSnapshot.Feature) -> Bool { f.type == "Sketch" }
    static func isConstruction(_ f: DesignSnapshot.Feature) -> Bool { f.type.hasPrefix("Construction") }

    /// Edit Sketch from a History or Items row (agent B's entry point: it rolls to the sketch
    /// and Finish Sketch puts the marker back). A sketch's id is its feature id.
    static func editSketch(_ id: Int, _ model: DesignModel) {
        FeatureEditor.editSketch(model, sketch: id)
    }

    // MARK: Variables at the top of History (B-10)

    @discardableResult
    static func addParameter(_ name: String, _ expression: String, _ model: DesignModel) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || e.isEmpty { return String(localized: "A variable needs a name and a value.") }
        return run(model, "parameters.add", ["name": n, "expression": e])
    }

    /// Rename and new expression in one go: each is its own command and undo step.
    @discardableResult
    static func updateParameter(_ old: String, name: String, expression: String, _ model: DesignModel) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return String(localized: "A variable needs a name.") }
        var current = old
        if n != old {
            if let why = run(model, "parameters.rename", ["name": old, "new_name": n]) { return why }
            current = n
        }
        if !e.isEmpty, model.snapshot.params.first(where: { $0.name == current })?.expression != e {
            return run(model, "parameters.change", ["name": current, "expression": e])
        }
        return nil
    }

    @discardableResult
    static func deleteParameter(_ name: String, _ model: DesignModel) -> String? {
        run(model, "parameters.delete", ["name": name])
    }

    /// "var1", "var2": the first free name.
    static func freeParameterName(_ model: DesignModel) -> String {
        let taken = Set(model.snapshot.params.map(\.name))
        var i = 1
        while taken.contains("var\(i)") { i += 1 }
        return "var\(i)"
    }

    // MARK: Items (T-14, B-14)

    static func items(_ s: DesignSnapshot) -> [PanelItem] {
        s.snapshotBodies + s.snapshotSketches + constructionItems(s)
    }

    static func constructionItems(_ s: DesignSnapshot) -> [PanelItem] {
        s.timeline.filter(isConstruction).map { PanelItem(kind: .construction, name: $0.name, feature: $0.id) }
    }

    /// Delete: bodies with `solid.remove` (one step), sketches and construction items with
    /// `timeline.delete`.
    @discardableResult
    static func delete(_ items: [PanelItem], _ model: DesignModel) -> String? {
        let bodies = items.filter { $0.kind == .body }.map(\.name)
        if !bodies.isEmpty, let why = run(model, "solid.remove", ["bodies": bodies]) { return why }
        for i in items where i.kind != .body {
            if let f = i.feature, let why = run(model, "timeline.delete", ["feature": f]) { return why }
        }
        model.selectedBodies.subtract(bodies)
        return nil
    }

    @discardableResult
    static func rename(_ item: PanelItem, to name: String, _ model: DesignModel) -> String? {
        switch item.kind {
        case .body: return model.renameBody(item.name, to: name)
        case .sketch, .construction:
            guard let f = item.feature else { return nil }
            return renameFeature(f, to: name, model)
        }
    }

    static func setVisible(_ items: [PanelItem], _ visible: Bool, _ model: DesignModel) {
        let keys = items.map { $0.kind == .body ? $0.name : $0.name }
        guard !keys.isEmpty else { return }
        run(model, "browser.visibility", ["visible": visible, "items": keys])
    }

    /// Sketch on a construction plane (B-14).
    static func sketch(on plane: PanelItem, _ model: DesignModel) {
        model.startSketch(plane.name)
    }

    /// Puts items in a new folder (`browser.group`); one folder per browser folder they come
    /// from. Answers the folders made, or why not.
    static func group(_ items: [PanelItem], name: String?, _ model: DesignModel) -> Result<[ItemFolder], PanelError> {
        var made: [ItemFolder] = []
        for kind in PanelItem.Kind.allCases {
            let mine = items.filter { $0.kind == kind }
            guard !mine.isEmpty else { continue }
            var p: [String: Any] = ["folder": mine[0].browserFolder, "items": mine.map(\.browserKey)]
            if let name, !name.isEmpty { p["name"] = name }
            guard let r = model.run("browser.group", p, quiet: true) as? [String: Any],
                  let id = (r["group"] as? NSNumber)?.intValue else {
                let why = model.message ?? String(localized: "The folder was not made.")
                model.flash(nil)
                return .failure(PanelError(message: why))
            }
            made.append(ItemFolder(id: id, name: r["name"] as? String ?? name ?? "", kind: kind, items: mine))
        }
        return .success(made)
    }

    /// An empty folder of one kind.
    static func newFolder(_ kind: PanelItem.Kind, _ model: DesignModel) -> Result<ItemFolder, PanelError> {
        let folder = PanelItem(kind: kind, name: "", feature: nil).browserFolder
        guard let r = model.run("browser.group", ["folder": folder], quiet: true) as? [String: Any],
              let id = (r["group"] as? NSNumber)?.intValue else {
            let why = model.message ?? String(localized: "The folder was not made.")
            model.flash(nil)
            return .failure(PanelError(message: why))
        }
        return .success(ItemFolder(id: id, name: r["name"] as? String ?? "", kind: kind, items: []))
    }
}

extension DesignSnapshot {
    fileprivate var snapshotBodies: [PanelItem] { bodies.map { PanelItem(kind: .body, name: $0.name, feature: nil) } }
    fileprivate var snapshotSketches: [PanelItem] { sketches.map { PanelItem(kind: .sketch, name: $0.name, feature: $0.id) } }
}

/// A browser folder made from the Items panel. The engine keeps folders with the design but has
/// no command that lists them yet, so the panel remembers the ones it made (upstream need: a
/// browser tree readout in `document.inspect`).
struct ItemFolder: Identifiable, Hashable {
    var id: Int
    var name: String
    var kind: PanelItem.Kind
    var items: [PanelItem]
}

/// The folders of each open design, by model.
@MainActor
final class ItemFolderStore {
    static let shared = ItemFolderStore()
    private var byModel: [ObjectIdentifier: [ItemFolder]] = [:]

    func folders(_ model: DesignModel) -> [ItemFolder] {
        let present = Set(PanelOps.items(model.snapshot).map(\.id))
        return (byModel[ObjectIdentifier(model)] ?? []).map { f in
            var f = f
            f.items = f.items.filter { present.contains($0.id) }
            return f
        }
    }

    func add(_ f: ItemFolder, _ model: DesignModel) {
        var list = byModel[ObjectIdentifier(model)] ?? []
        // An item sits in one folder: the new one takes it from the others.
        let moved = Set(f.items.map(\.id))
        for i in list.indices { list[i].items.removeAll { moved.contains($0.id) } }
        list.append(f)
        byModel[ObjectIdentifier(model)] = list
    }

    func rename(_ id: Int, to name: String, _ model: DesignModel) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return String(localized: "A folder needs a name.") }
        if let why = PanelOps.run(model, "browser.rename_group", ["group": id, "name": n]) { return why }
        update(model) { list in if let i = list.firstIndex(where: { $0.id == id }) { list[i].name = n } }
        return nil
    }

    func ungroup(_ id: Int, _ model: DesignModel) -> String? {
        if let why = PanelOps.run(model, "browser.ungroup", ["group": id]) { return why }
        update(model) { $0.removeAll { $0.id == id } }
        return nil
    }

    func move(_ items: [PanelItem], into id: Int, _ model: DesignModel) -> String? {
        guard let target = byModel[ObjectIdentifier(model)]?.first(where: { $0.id == id }) else { return nil }
        let mine = items.filter { $0.kind == target.kind }
        guard !mine.isEmpty else { return nil }
        if let why = PanelOps.run(model, "browser.move", ["folder": mine[0].browserFolder, "items": mine.map(\.browserKey), "group": id]) {
            return why
        }
        let moved = Set(mine.map(\.id))
        update(model) { list in
            for i in list.indices { list[i].items.removeAll { moved.contains($0.id) } }
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].items += mine }
        }
        return nil
    }

    private func update(_ model: DesignModel, _ change: (inout [ItemFolder]) -> Void) {
        var list = byModel[ObjectIdentifier(model)] ?? []
        change(&list)
        byModel[ObjectIdentifier(model)] = list
    }
}

/// `--selftest` checks for the touch History and Items panels, through real engine commands.
enum TouchPanelsSelfTest {
    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let m = DesignModel()
        m.run("file.new", quiet: true)
        m.run("sketch.create", ["plane": "XY", "name": "Base sketch"])
        m.run("sketch.line", ["points": [[0, 0], [20, 0], [20, 10], [0, 10]], "closed": true])
        m.run("sketch.finish")
        m.run("solid.extrude", ["distance": 10, "body_name": "Block"])
        func volume(_ name: String) -> Double { m.snapshot.bodies.first(where: { $0.name == name })?.volume_mm3 ?? 0 }
        out.append((abs(volume("Block") - 2000) < 1, "T-1 setup: a 20 x 10 x 10 block (got \(volume("Block")))"))

        // T-1: edit the extrude from its History row.
        let extrude = m.snapshot.timeline.first(where: { $0.type.lowercased().contains("extrude") })?.id ?? -1
        var fields: [FeatureField] = []
        if case .success(let r) = PanelOps.inspect(extrude, m) { fields = r.fields }
        var edited = fields
        let dist = edited.firstIndex(where: { $0.key.hasSuffix("distance") })
        if let dist { PanelOps.set(&edited[dist], text: "20") }
        let editWhy = PanelOps.edit(extrude, from: fields, to: edited, m)
        out.append((dist != nil && editWhy == nil && abs(volume("Block") - 4000) < 1,
                    "T-1 the History row edit sets the distance to 20 (got \(volume("Block")), \(editWhy ?? "ok"))"))

        // B-10: a variable drives the extrude.
        let addWhy = PanelOps.addParameter("depth", "15", m)
        out.append((addWhy == nil && m.snapshot.params.contains { $0.name == "depth" }, "B-10 add variable depth (\(addWhy ?? "ok"))"))
        if case .success(let r) = PanelOps.inspect(extrude, m) { fields = r.fields }
        edited = fields
        if let i = edited.firstIndex(where: { $0.key.hasSuffix("distance") }) { PanelOps.set(&edited[i], text: "depth") }
        let driveWhy = PanelOps.edit(extrude, from: fields, to: edited, m)
        _ = PanelOps.updateParameter("depth", name: "depth", expression: "25", m)
        out.append((driveWhy == nil && abs(volume("Block") - 5000) < 1,
                    "B-10 the variable drives the extrude: depth 25 gives 5000 (got \(volume("Block")), \(driveWhy ?? "ok"))"))
        let renWhy = PanelOps.updateParameter("depth", name: "height", expression: "30", m)
        out.append((renWhy == nil && m.snapshot.params.contains { $0.name == "height" } && abs(volume("Block") - 6000) < 1,
                    "B-10 rename the variable and change it: 6000 (got \(volume("Block")), \(renWhy ?? "ok"))"))

        // T-13 rename.
        let rnWhy = PanelOps.renameFeature(extrude, to: "Base", m)
        out.append((rnWhy == nil && m.snapshot.timeline.contains { $0.id == extrude && $0.name == "Base" }, "T-13 rename a step (\(rnWhy ?? "ok"))"))

        // T-13 reorder: a box made last, dragged to the top.
        m.run("solid.box", ["length": 5, "width": 5, "height": 5, "corner": [50, 0, 0], "operation": "new", "body_name": "Cube"])
        let box = m.snapshot.timeline.last?.id ?? -1
        let move = PanelOps.drop(PanelOps.entries(m.snapshot), dragged: .feature(box), slot: 0)
        let moveWhy = PanelOps.apply(move, m)
        out.append((move == .reorder(feature: box, position: 0, active: true) && moveWhy == nil && m.snapshot.timeline.first?.id == box,
                    "T-13 drag the last step to the top (\(move), \(moveWhy ?? "ok"))"))

        // T-13 breakpoint: insert after the first row, rows below are rolled back, drag it to the end.
        _ = PanelOps.insertBreakpoint(after: 0, m)
        let rolled = m.snapshot.timeline.dropFirst().allSatisfy { $0.rolled_back == true }
        let entries = PanelOps.entries(m.snapshot)
        out.append((rolled && entries.firstIndex(of: .breakpoint) == 1, "T-13 Insert Breakpoint greys the rows below it"))
        let roll = PanelOps.drop(entries, dragged: .breakpoint, slot: entries.count - 1)
        PanelOps.apply(roll, m)
        out.append((roll == .roll(m.snapshot.timeline.count) && !m.snapshot.timeline.contains { $0.rolled_back == true }
                    && abs(volume("Block") - 6000) < 1, "T-13 drag the breakpoint to the end rebuilds everything (\(roll))"))
        let slotted = PanelOps.slot(at: 25, mids: [.feature(1): 10, .feature(2): 30, .breakpoint: 50], order: [.feature(1), .feature(2), .breakpoint], dragged: .breakpoint)
        out.append((slotted == 1, "T-13 a drop between two rows lands between them"))

        // T-13 related to selection: the block's sketch and extrude, not the cube.
        let related = PanelOps.related(m, bodies: ["Block"])
        let sketch = m.snapshot.timeline.first(where: PanelOps.isSketch)?.id ?? -1
        out.append((related.contains(extrude) && related.contains(sketch) && !related.contains(box),
                    "T-13 Related to Selection lists the block's steps only (\(related.sorted()))"))

        // B-14 a construction plane is listed and sketchable.
        m.run("construct.plane.offset", ["base": "XY", "offset": 4, "name": "Shelf"])
        let planes = PanelOps.constructionItems(m.snapshot)
        out.append((planes.map(\.name) == ["Shelf"], "B-14 the plane is listed in Items (\(planes.map(\.name)))"))
        if let p = planes.first { PanelOps.sketch(on: p, m) }
        out.append((m.sketchOpen, "B-14 sketch on the listed plane"))
        m.finishSketch()

        // T-14 Items: folder, rename, delete.
        let cube = PanelItem(kind: .body, name: "Cube", feature: nil)
        var groupOK = false
        if case .success(let f) = PanelOps.group([cube], name: "Parts", m) { groupOK = f.count == 1; for x in f { ItemFolderStore.shared.add(x, m) } }
        out.append((groupOK && ItemFolderStore.shared.folders(m).first?.items == [cube], "T-14 group a body into a folder"))
        let itemRen = PanelOps.rename(cube, to: "Dice", m)
        out.append((itemRen == nil && m.snapshot.bodies.contains { $0.name == "Dice" }, "T-14 rename from the action bar"))
        let delWhy = PanelOps.delete([PanelItem(kind: .body, name: "Dice", feature: nil)], m)
        out.append((delWhy == nil && !m.snapshot.bodies.contains { $0.name == "Dice" }, "T-14 delete from the action bar (\(delWhy ?? "ok"))"))
        return out
    }
}
