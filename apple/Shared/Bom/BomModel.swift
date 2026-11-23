import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

// MARK: Shapes from the BOM (crate viaform-bom, snake_case JSON; empty lists are left out)

struct BomBreak: Codable, Hashable, Sendable {
    var qty: Int
    var unitPrice: Double
}

struct BomOffer: Codable, Hashable, Sendable {
    var supplier: String
    var sku: String?
    var url: String?
    var unitPriceUsd: Double?
    var breaks: [BomBreak]?
    var moq: Int?
    var pack: Int?
    var stock: Double?
    var stockNote: String?
    var checkedOn: String?
    var via: String?
}

struct BomMade: Codable, Hashable, Sendable {
    var material: String?
    var process: String?
    var unitCostUsd: Double?
}

/// A spec value as text, whatever JSON type the file used.
struct BomSpec: Codable, Hashable, Sendable {
    var text: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { text = s }
        else if let d = try? c.decode(Double.self) { text = d.formatted(.number.precision(.fractionLength(0...4))) }
        else if let b = try? c.decode(Bool.self) { text = b ? "yes" : "no" }
        else if let a = try? c.decode([BomSpec].self) { text = a.map(\.text).joined(separator: ", ") }
        else if let d = try? c.decode([String: BomSpec].self) { text = d.keys.sorted().map { "\($0): \(d[$0]?.text ?? "")" }.joined(separator: ", ") }
        else { text = "" }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

struct BomLine: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var origin: String
    var reference: String?
    var qty: Int
    var qtyOverride: Int?
    var category: String?
    var mpn: String?
    var manufacturer: String?
    var description: String?
    var keySpecs: [String: BomSpec]?
    var dimsMm: [Double]?
    var massG: Double?
    var made: BomMade?
    var subassembly: String?
    var datasheetUrl: String?
    var cadSource: String?
    var offers: [BomOffer]?
    var supplier: String?
    var alternates: [String]?
    var usedBy: [String]?
    var notes: String?
    var userNotes: String?
    var checkedOn: String?
    var components: [Int]?
    var definitions: [String]?
    var placed: Int?
    /// STL and 3MF files of a made line read from a generated assembly.
    var meshes: [String]?
    /// The assembly places it but the component file has no line for it.
    var unlisted: Bool?
    var excluded: Bool?

    var perBuild: Int { qtyOverride ?? qty }
}

struct BomImport: Codable, Hashable, Sendable {
    var origin: String
    var kind: String
    var path: String?
    var version: Int?
    var checkedOn: String?
    var lines: Int
    var importedOn: String
}

struct BomDoc: Codable, Sendable {
    var name: String?
    var builds: Int
    var currency: String?
    var lines: [BomLine]
    var imports: [BomImport]
    var refreshedOn: String?
}

struct BomLineRoll: Codable, Hashable, Sendable {
    var id: String
    var perBuild: Int
    var need: Int
    var made: Bool
    var supplier: String?
    var sku: String?
    var url: String?
    var orderQty: Int
    var unitPrice: Double?
    var extended: Double?
    var perBuildCost: Double?
    var breakQty: Int?
    var massG: Double?
    var flags: [String]
    var notes: [String]
    var stockNote: String?
    var lifecycle: String?
    var checkedOn: String?
    var ageDays: Int?
    var excluded: Bool
}

struct BomCartItem: Codable, Hashable, Sendable {
    var line: String
    var reference: String
    var sku: String
    var mpn: String
    var qty: Int
    var unitPrice: Double
    var extended: Double
    var url: String?
}

struct BomCart: Codable, Hashable, Identifiable, Sendable {
    var supplier: String
    var items: [BomCartItem]
    var total: Double
    var id: String { supplier }
}

struct BomTotals: Codable, Hashable, Sendable {
    var boughtCost: Double = 0
    var madeCost: Double = 0
    var totalCost: Double = 0
    var costPerBuild: Double = 0
    var massG: Double = 0
    var massMadeG: Double = 0
    var massBoughtG: Double = 0
    var lines: Int = 0
    var partsPerBuild: Int = 0
    var boughtLines: Int = 0
    var madeLines: Int = 0
    var flagged: Int = 0
    var unsourced: Int = 0
    var missingPrice: Int = 0
    var missingMass: Int = 0
    var stale: Int = 0
    var excluded: Int = 0
    var costComplete: Bool = true
    var massComplete: Bool = true
}

struct BomRollup: Codable, Sendable {
    var builds: Int
    var currency: String
    var today: String
    var lines: [BomLineRoll]
    var totals: BomTotals
    var carts: [BomCart]
}

struct BomState: Codable, Sendable {
    var bom: BomDoc
    var rollup: BomRollup
}

private struct BomReply: Decodable { var state: BomState }
private struct BomExport: Decodable { var text: String; var filename: String }

/// One table row: the line and its figures for the build count, with sortable keys.
struct BomRow: Identifiable, Hashable {
    var line: BomLine
    var roll: BomLineRoll
    var id: String { line.id }

    var ref: String { line.reference ?? "" }
    var category: String { line.category ?? "" }
    var subassembly: String { (line.subassembly ?? "").isEmpty ? line.origin : line.subassembly! }
    var title: String { line.description ?? "" }
    var mpn: String { line.mpn ?? "" }
    var supplier: String { roll.supplier ?? "" }
    var qty: Int { roll.perBuild }
    var need: Int { roll.need }
    var unit: Double { roll.unitPrice ?? -1 }
    var extended: Double { roll.extended ?? -1 }
    var mass: Double { roll.massG ?? -1 }
    var kind: String { roll.excluded ? String(localized: "Excluded") : (roll.made ? String(localized: "Made") : String(localized: "Bought")) }
    var flagCount: Int { roll.flags.count }
    var checked: String { roll.checkedOn ?? "" }

    /// The row as one tab-separated line (Copy Row, Command-C).
    var tsv: String {
        [ref, title, line.manufacturer ?? "", mpn, "\(qty)", supplier,
         roll.unitPrice.map { VFFormat.money($0) } ?? "", roll.extended.map { VFFormat.money($0) } ?? ""].joined(separator: "\t")
    }
}

/// Labels and symbols of the rollup's flags.
enum BomFlag {
    static func label(_ f: String) -> String {
        switch f {
        case "unsourced": "Unsourced"
        case "no_mpn": "No MPN"
        case "no_price": "No price"
        case "no_cost": "No cost"
        case "no_mass": "No mass"
        case "no_material": "No material"
        case "out_of_stock": "Out of stock"
        case "low_stock": "Low stock"
        case "lifecycle": "Lifecycle"
        case "stale": "Stale"
        case "placed_mismatch": "Placed count"
        case "moq_excess": "MOQ"
        case "not_in_file": "Not in component file"
        case "not_placed": "Not placed"
        default: f
        }
    }

    /// Flags shown grey: an order rounded up, an old check, a made part with no cost estimate yet.
    static let quiet: Set<String> = ["moq_excess", "stale", "no_cost"]

    /// Severe flags turn the row red; the others amber; the quiet ones only grey.
    static func severity(_ flags: [String]) -> Int {
        if flags.contains(where: { severe.contains($0) }) { return 2 }
        if flags.contains(where: { !quiet.contains($0) }) { return 1 }
        return flags.isEmpty ? 0 : -1
    }

    static let severe: Set<String> = ["unsourced", "out_of_stock", "lifecycle", "no_price", "not_in_file"]

    /// The status column's word for a severity: never the colour alone.
    static func word(_ severity: Int) -> String {
        switch severity {
        case 2: String(localized: "Problem")
        case 1: String(localized: "Check")
        case -1: String(localized: "Note")
        default: String(localized: "OK")
        }
    }

    /// The status column's symbol for a severity: a shape per state.
    static func symbol(_ severity: Int) -> String {
        switch severity {
        case 2: "xmark.octagon.fill"
        case 1: "exclamationmark.triangle.fill"
        case -1: "info.circle"
        default: "checkmark.circle"
        }
    }
}

// MARK: Model

/// A short confirmation for the panel to show as a toast ("Removed 2 lines" with Undo, "Exported
/// bom.csv" with Reveal). The model sets it; the panel shows it once.
struct BomNotice: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var undo = false
    var reveal: URL? = nil
}

/// One part number the price check could not read, and why.
struct BomRefreshFailure: Identifiable, Hashable, Sendable {
    var line: String
    var query: String
    var reason: String
    var offline: Bool
    var id: String { line }
}

/// What the last price check did: "38 checked, 2 failed (offline)".
struct BomRefreshSummary: Equatable {
    var checked: Int
    var failed: [BomRefreshFailure]
    var offers: Int
    var cancelled: Bool
    var sources: [String]

    var text: String {
        let offline = !failed.isEmpty && failed.allSatisfy(\.offline)
        var s = String(localized: "\(checked) checked")
        if !failed.isEmpty {
            s += offline ? String(localized: ", \(failed.count) failed (offline)") : String(localized: ", \(failed.count) failed")
        } else if offers > 0 {
            s += String(localized: ", \(offers) offers")
        }
        if cancelled { s += String(localized: ", stopped") }
        return s
    }
}

/// The BOM workspace: one bill of materials for the open project, filled from the design, the
/// board and the component files, priced for N builds, refreshed through the library's sources.
///
/// Engine work runs off the main actor in the order it was asked for (`busy` says what runs);
/// every edit and removal can be undone (`undo()`, `redo()`), the engine saving the whole bill
/// before each change.
@MainActor
@Observable
final class BomModel {
    enum Grouping: String, CaseIterable, Identifiable {
        case kind = "Made or Bought", none = "None", category = "Category", subassembly = "Subassembly", supplier = "Supplier", origin = "Source"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .kind: String(localized: "Made or Bought")
            case .none: String(localized: "None")
            case .category: String(localized: "Category")
            case .subassembly: String(localized: "Subassembly")
            case .supplier: String(localized: "Supplier")
            case .origin: String(localized: "Source")
            }
        }
    }

    private let engine = BomEngine()
    var doc = BomDoc(name: nil, builds: 1, currency: "USD", lines: [], imports: [], refreshedOn: nil)
    var rollup = BomRollup(builds: 1, currency: "USD", today: "", lines: [], totals: BomTotals(), carts: [])
    var rows: [BomRow] = []
    var grouping = Grouping.kind
    /// The selected lines (several on the Mac table, for batch actions).
    var selection: Set<BomRow.ID> = []
    var sortOrder: [KeyPathComparator<BomRow>] = []
    var filter = ""
    var onlyFlagged = false
    /// The last error, shown until dismissed (the project file's save reads it as its reason).
    var message: String?
    var messageIsError = false
    /// Runs the failed action again (the error's Try Again); nil when it cannot be retried.
    private(set) var retry: (() -> Void)?
    /// The last confirmation, shown once as a toast.
    var notice: BomNotice?
    /// Moves on every change to the bill (edits, imports, undo, redo, the build count): the
    /// window's "edited" mark compares it (P0-2).
    private(set) var editRevision = 0
    /// What the engine is doing now ("Importing hand"), nil when idle.
    private(set) var busy: String?
    private var pending = 0

    // Price check
    private(set) var refreshing = false
    private(set) var refreshDone = 0
    private(set) var refreshTotal = 0
    private(set) var refreshSummary: BomRefreshSummary?
    /// Lines whose last check failed, by id, with the reason.
    private(set) var refreshFailures: [String: BomRefreshFailure] = [:]
    private var refreshTask: Task<Void, Never>?

    init() { apply { try engine.call("state") } }

    func say(_ text: String?, error: Bool = false) {
        message = text
        messageIsError = error
        retry = nil
    }

    /// An error with Try Again.
    func fail(_ text: String, retry: @escaping () -> Void) {
        say(text, error: true)
        self.retry = retry
    }

    /// A confirmation: a toast in the panel.
    func notify(_ text: String, undo: Bool = false, reveal: URL? = nil) {
        notice = BomNotice(text: text, undo: undo, reveal: reveal)
    }

    // MARK: State

    /// Shows the state a call answered.
    @discardableResult
    private func show(_ data: Data) -> Bool {
        do {
            let r = try BomEngine.decoder.decode(BomReply.self, from: data)
            doc = r.state.bom
            rollup = r.state.rollup
            let rolls = Dictionary(uniqueKeysWithValues: rollup.lines.map { ($0.id, $0) })
            rows = doc.lines.compactMap { l in rolls[l.id].map { BomRow(line: l, roll: $0) } }
            selection = selection.filter { id in rows.contains { $0.id == id } }
            return true
        } catch {
            say(error.localizedDescription, error: true)
            return false
        }
    }

    /// Runs a call that answers the state on this thread (the calls that read the design or the
    /// board sessions), and shows it.
    @discardableResult
    private func apply(_ f: () throws -> Data) -> Bool {
        do { return show(try f()) } catch {
            say(error.localizedDescription, error: true)
            return false
        }
    }

    /// Runs a call off the main actor and shows the state it answers. With `design` or `pcb`,
    /// the call reads those sessions (held for the call on the BOM's queue, never on this actor).
    @discardableResult
    private func applyAsync(_ method: String, _ params: [String: Any] = [:], design: CADEngine? = nil, pcb: PCBEngine? = nil) async -> Bool {
        do {
            let json = BomEngine.json(params)
            let data = design == nil && pcb == nil ? try await engine.run(method, json: json)
                : try await engine.run(method, json: json, design: design, pcb: pcb)
            return show(data)
        } catch {
            say(error.localizedDescription, error: true)
            return false
        }
    }

    /// The model's work queue: each job waits for the one before (an undo snapshot and its edit
    /// stay together), `busy` names the running one.
    private var chain: Task<Void, Never>?

    private func enqueue(_ label: String?, _ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        pending += 1
        chain = Task { @MainActor in
            await previous?.value
            if let label { self.busy = label }
            await work()
            self.pending -= 1
            if self.pending == 0 { self.busy = nil }
        }
    }

    /// Waits for every job asked for so far.
    func settle() async { await chain?.value }

    /// Runs `work` as the next job of the queue and answers its result.
    private func queued(_ label: String?, _ work: @escaping @MainActor () async -> Bool) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            enqueue(label) { c.resume(returning: await work()) }
        }
    }

    // MARK: What the table shows

    var visibleRows: [BomRow] {
        var out = rows
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            out = out.filter { r in [r.ref, r.title, r.mpn, r.supplier, r.category, r.subassembly, r.line.manufacturer ?? ""].joined(separator: " ").lowercased().contains(q) }
        }
        if onlyFlagged { out = out.filter { BomFlag.severity($0.roll.flags) > 0 } }
        if !sortOrder.isEmpty { out.sort(using: sortOrder) }
        return out
    }

    struct Group: Identifiable {
        var name: String
        var rows: [BomRow]
        var id: String { name }
        var extended: Double { rows.compactMap(\.roll.extended).reduce(0, +) }
        var mass: Double { rows.compactMap(\.roll.massG).reduce(0, +) }
        /// Lines counted in the group with no price yet.
        var unpriced: Int { rows.filter { $0.roll.extended == nil && !$0.roll.excluded && $0.roll.perBuild > 0 }.count }
    }

    func key(_ r: BomRow) -> String {
        switch grouping {
        case .none: ""
        case .kind: r.roll.excluded ? String(localized: "Left out") : (r.roll.made ? String(localized: "Made") : String(localized: "Bought"))
        case .category: r.category.isEmpty ? String(localized: "Uncategorised") : r.category
        case .subassembly: r.subassembly
        case .supplier: r.roll.made ? String(localized: "Made in house") : (r.supplier.isEmpty ? String(localized: "Unsourced") : r.supplier)
        case .origin: r.line.origin
        }
    }

    var groups: [Group] {
        let rows = visibleRows
        guard grouping != .none else { return [Group(name: String(localized: "All lines"), rows: rows)] }
        var order: [String] = []
        var by: [String: [BomRow]] = [:]
        for r in rows {
            let k = key(r)
            if by[k] == nil { order.append(k) }
            by[k, default: []].append(r)
        }
        if grouping == .kind {
            let rank = [String(localized: "Made"), String(localized: "Bought"), String(localized: "Left out")]
            order.sort { (rank.firstIndex(of: $0) ?? 3) < (rank.firstIndex(of: $1) ?? 3) }
        } else if sortOrder.isEmpty { order.sort { $0.localizedStandardCompare($1) == .orderedAscending } }
        return order.map { Group(name: $0, rows: by[$0] ?? []) }
    }

    /// The one selected line (the detail shows it); nil when none or several are selected.
    var selected: BomRow? { selection.count == 1 ? rows.first { selection.contains($0.id) } : nil }

    /// Every selected line, in table order.
    var selectedRows: [BomRow] { rows.filter { selection.contains($0.id) } }

    /// Made and bought, as the summary splits them: lines, parts per build, cost and mass.
    struct Split { var lines = 0; var parts = 0; var cost = 0.0; var mass = 0.0; var unpriced = 0 }
    func split(made: Bool) -> Split {
        var s = Split()
        for r in rows where !r.roll.excluded && r.roll.made == made {
            s.lines += 1
            s.parts += r.roll.perBuild
            s.cost += r.roll.extended ?? 0
            s.mass += r.roll.massG ?? 0
            if r.roll.extended == nil, r.roll.perBuild > 0 { s.unpriced += 1 }
        }
        return s
    }
    var currency: String { rollup.currency }

    /// Lines counted in the rollup with no price or cost yet.
    var unpricedLines: Int { split(made: true).unpriced + split(made: false).unpriced }

    // MARK: Undo

    private struct Step { var name: String; var file: URL }
    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    private static let undoLimit = 40

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// "Remove 2 Lines", for the Edit menu's "Undo Remove 2 Lines".
    var undoName: String? { undoStack.last?.name }
    var redoName: String? { redoStack.last?.name }

    private static var undoFolder: URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("viaform-bom-undo", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// The whole bill as the engine has it now, in a file.
    private func snapshot() async -> URL? {
        let u = Self.undoFolder.appendingPathComponent(UUID().uuidString + ".json")
        do {
            _ = try await engine.run("save", json: BomEngine.json(["path": u.path]))
            return u
        } catch { return nil }
    }

    /// Deletes the steps' files off the main actor.
    private func drop(_ steps: [Step]) {
        let files = steps.map(\.file)
        guard !files.isEmpty else { return }
        Task.detached(priority: .utility) { for f in files { try? FileManager.default.removeItem(at: f) } }
    }

    private func clearHistory() {
        drop(undoStack + redoStack)
        undoStack = []
        redoStack = []
    }

    /// One undoable change: the bill is saved, then each call runs in order. Answers whether the
    /// last call worked.
    @discardableResult
    private func change(_ name: String, _ calls: [(String, [String: Any])], design: CADEngine? = nil, pcb: PCBEngine? = nil) async -> Bool {
        let before = await snapshot()
        var ok = true
        for (method, params) in calls where ok { ok = await applyAsync(method, params, design: design, pcb: pcb) }
        if ok { editRevision += 1 }
        if ok, let before {
            undoStack.append(Step(name: name, file: before))
            if undoStack.count > Self.undoLimit { drop([undoStack.removeFirst()]) }
            drop(redoStack)
            redoStack = []
        } else if let before {
            drop([Step(name: name, file: before)])
        }
        return ok
    }

    func undo() {
        enqueue(String(localized: "Undoing")) { [self] in
            guard let step = undoStack.popLast() else { return }
            let now = await snapshot()
            if await applyAsync("load", ["path": step.file.path]) {
                editRevision += 1
                if let now { redoStack.append(Step(name: step.name, file: now)) }
                drop([step])
            } else {
                undoStack.append(step)
            }
        }
    }

    func redo() {
        enqueue(String(localized: "Redoing")) { [self] in
            guard let step = redoStack.popLast() else { return }
            let now = await snapshot()
            if await applyAsync("load", ["path": step.file.path]) {
                editRevision += 1
                if let now { undoStack.append(Step(name: step.name, file: now)) }
                drop([step])
            } else {
                redoStack.append(step)
            }
        }
    }

    // MARK: Edits

    func setBuilds(_ n: Int) {
        let n = max(1, n)
        enqueue(nil) { [self] in if await applyAsync("set", ["builds": n]) { editRevision += 1 } }
    }

    private func edit(_ name: String, _ ids: [String], _ changes: [String: Any]) {
        let calls: [(String, [String: Any])] = ids.map { ("edit", ["id": $0, "changes": changes]) }
        enqueue(nil) { [self] in await change(name, calls) }
    }

    /// The count per build; negative counts are refused (the field says so before it gets here).
    func setQty(_ row: BomRow, _ n: Int) {
        guard n >= 0, n != row.line.perBuild else { return }
        edit(String(localized: "Change Quantity"), [row.id], ["qty": n])
    }

    func setNotes(_ row: BomRow, _ text: String) {
        guard text != (row.line.userNotes ?? "") else { return }
        edit(String(localized: "Edit Notes"), [row.id], ["notes": text])
    }

    func setSupplier(_ row: BomRow, _ s: String?) {
        edit(String(localized: "Choose Supplier"), [row.id], ["supplier": s ?? NSNull()])
    }

    func setExcluded(_ row: BomRow, _ on: Bool) { setExcluded([row], on) }

    func setExcluded(_ rows: [BomRow], _ on: Bool) {
        let ids = rows.filter { $0.roll.excluded != on }.map(\.id)
        guard !ids.isEmpty else { return }
        edit(on ? String(localized: "Leave Out of Rollup") : String(localized: "Include in Rollup"), ids, ["excluded": on])
    }

    func addLine() {
        enqueue(String(localized: "Adding a line")) { [self] in
            if await change(String(localized: "Add Line"), [("add", ["line": ["description": String(localized: "New part"), "category": "other"]])]),
               let id = rows.last(where: { $0.line.origin == "manual" })?.id {
                selection = [id]
            }
        }
    }

    /// Lines a reader can remove: the ones added by hand (imported lines come back with their file).
    func removable(_ rows: [BomRow]) -> [BomRow] { rows.filter { $0.line.origin == "manual" } }

    func remove(_ row: BomRow) { remove([row]) }

    /// Removes the lines and offers Undo in a toast.
    func remove(_ rows: [BomRow]) {
        let ids = removable(rows).map(\.id)
        guard !ids.isEmpty else { return }
        let name = ids.count == 1 ? String(localized: "Remove Line") : String(localized: "Remove \(ids.count) Lines")
        enqueue(String(localized: "Removing")) { [self] in
            if await change(name, ids.map { ("remove", ["id": $0]) }) {
                selection.subtract(ids)
                notify(ids.count == 1 ? String(localized: "Removed 1 line") : String(localized: "Removed \(ids.count) lines"), undo: true)
            }
        }
    }

    /// Removes every line of one import (a component file, the design, the board); Undo brings
    /// them back.
    func removeOrigin(_ origin: String) {
        let n = doc.imports.first { $0.origin == origin }?.lines ?? rows.filter { $0.line.origin == origin }.count
        enqueue(String(localized: "Removing \(origin)")) { [self] in
            if await change(String(localized: "Remove \(origin)"), [("remove_origin", ["origin": origin])]) {
                notify(String(localized: "Removed \(origin) (\(n) lines)"), undo: true)
            }
        }
    }

    // MARK: Sources

    /// The component files of the repository (docs/components), else the BOM's test fixtures.
    nonisolated static var componentsFolder: URL? {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        if let a = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--components=") }) {
            return URL(fileURLWithPath: String(a.dropFirst(13)))
        }
        for dir in ["docs/components", "bom/tests/fixtures"] {
            let u = repo.appendingPathComponent(dir, isDirectory: true)
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    func importFile(_ url: URL) {
        enqueue(String(localized: "Importing \(url.lastPathComponent)")) { [self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let isDir = await Task.detached { () -> Bool in
                var d: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
            }.value
            if isDir {
                if await change(String(localized: "Import"), [("import_dir", ["dir": url.path])]) {
                    notify(String(localized: "Imported the component files of \(url.lastPathComponent)"), undo: true)
                } else { offerRetry { [weak self] in self?.importFile(url) } }
            } else if await change(String(localized: "Import"), [("import_file", ["path": url.path])]) {
                notify(String(localized: "Imported \(url.lastPathComponent)"), undo: true)
            } else { offerRetry { [weak self] in self?.importFile(url) } }
        }
    }

    /// Adds Try Again to the error the failed call left.
    private func offerRetry(_ again: @escaping () -> Void) {
        if messageIsError, message != nil { retry = again }
    }

    /// The generated assembly of `name` (docs/generative/<name>/assembly.json), when there is one.
    nonisolated static func assemblyFile(_ name: String) -> URL? {
        guard let root = GenerateProject.docsRoot else { return nil }
        let u = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("assembly.json")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// What the last assembly import found out of line: refs the assembly places that the
    /// component file lacks, and file lines nothing places.
    private(set) var assemblyIssues: [String] = []

    /// Imports the named assemblies (`hand`, `drone`): the generated assembly when there is one
    /// (made parts with their meshes, real components matched by component_ref and rolled up,
    /// the component file's sourcing), else the component file alone.
    func importAssemblies(_ names: [String]) {
        enqueue(String(localized: "Importing \(names.joined(separator: ", "))")) { [self] in
            await ActionTiming.measure("bom.import_assemblies") { await runImportAssemblies(names) }
        }
    }

    private func runImportAssemblies(_ names: [String]) async {
        var done: [String] = []
        var issues: [String] = []
        // Where each name's file is, looked up off the main actor.
        let found = await Task.detached { () -> [(String, URL?, URL?)] in
            names.map { n in
                let asm = BomModel.assemblyFile(n)
                let comp = BomModel.componentsFolder.map { $0.appendingPathComponent("\(n).json") }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                return (n, asm, comp)
            }
        }.value
        for (n, asm, comp) in found {
            if let asm {
                if let r = await importAssemblyAsync(asm) {
                    done.append(n)
                    issues += r
                }
            } else if let comp, await change(String(localized: "Import"), [("import_file", ["path": comp.path])]) {
                done.append(n)
            }
        }
        assemblyIssues = issues
        if done.isEmpty {
            if !messageIsError { say(String(localized: "Nothing to import for \(names.joined(separator: ", "))"), error: true) }
            return offerRetry { [weak self] in self?.importAssemblies(names) }
        }
        let t = rollup.totals
        let what = String(localized: "Imported \(done.joined(separator: " and ")): \(t.madeLines) made, \(t.boughtLines) bought")
        if issues.isEmpty { notify(what, undo: true) } else { say(what + ". " + issues.joined(separator: "; "), error: true) }
    }

    /// Imports one generated assembly on this thread and answers what does not line up (the
    /// Generate self-test reads the result right away; the panel uses the queued import).
    @discardableResult
    func importAssembly(_ url: URL) -> [String]? {
        var data = Data()
        guard apply({ data = try engine.call("import_assembly", ["path": url.path]); return data }) else { return nil }
        return Self.issues(data, url)
    }

    private static func issues(_ data: Data, _ url: URL) -> [String] {
        let result = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["result"] as? [String: Any] ?? [:]
        let name = result["assembly"] as? String ?? url.deletingLastPathComponent().lastPathComponent
        var issues: [String] = []
        if let m = result["missing_from_file"] as? [String], !m.isEmpty { issues.append(String(localized: "\(name): \(m.joined(separator: ", ")) not in the component file")) }
        if let m = result["not_placed"] as? [String], !m.isEmpty { issues.append(String(localized: "\(name): \(m.joined(separator: ", ")) not placed")) }
        if result["components"] is NSNull || result["components"] == nil { issues.append(String(localized: "\(name): no component file")) }
        return issues
    }

    /// Imports one generated assembly with its component file, off the main actor, undoable;
    /// answers what does not line up.
    private func importAssemblyAsync(_ url: URL) async -> [String]? {
        let before = await snapshot()
        let data: Data
        do { data = try await engine.run("import_assembly", json: BomEngine.json(["path": url.path])) } catch {
            if let before { drop([Step(name: "", file: before)]) }
            say(error.localizedDescription, error: true)
            return nil
        }
        guard show(data) else { return nil }
        editRevision += 1
        if let before {
            undoStack.append(Step(name: String(localized: "Import"), file: before))
            drop(redoStack)
            redoStack = []
        }
        return Self.issues(data, url)
    }

    /// Reads the design's parts: `assembly.bom` runs on the BOM's queue with the design session
    /// held there, never on the main actor. Undoable.
    func syncDesign(_ design: DesignModel) {
        let engine = design.engine
        enqueue(String(localized: "Bringing in design parts")) { [self] in
            await ActionTiming.measure("bom.sync_design") {
                if await change(String(localized: "Bring In Design Parts"), [("sync_design", [:])], design: engine) {
                    notify(String(localized: "Design parts brought in"), undo: true)
                } else { offerRetry { [weak self] in self?.syncDesign(design) } }
            }
        }
    }

    /// Reads the board's components, the PCB session held on the BOM's queue. Undoable.
    func syncPCB(_ pcb: PCBModel) {
        let engine = pcb.engine
        enqueue(String(localized: "Bringing in PCB components")) { [self] in
            await ActionTiming.measure("bom.sync_pcb") {
                if await change(String(localized: "Bring In PCB Components"), [("sync_pcb", [:])], pcb: engine) {
                    notify(String(localized: "PCB components brought in"), undo: true)
                } else { offerRetry { [weak self] in self?.syncPCB(pcb) } }
            }
        }
    }

    /// Selecting a design line lights its bodies in the viewport.
    func highlight(_ design: DesignModel) {
        guard let r = selected else { return }
        let ids = Set(r.line.components ?? [])
        let names = Set(r.line.definitions ?? [])
        let bodies = design.assembly.filter { ids.contains($0.id) || names.contains($0.name) }.flatMap(\.bodies)
        if !bodies.isEmpty { design.selectedBodies = Set(bodies) }
    }

    // MARK: Refresh through the library's sources

    private struct LibParams: Encodable, Sendable {
        var keyed: [String]?
        var query: String?
        var only: [String]?
        var keys: [String: [String: String]]?
    }

    struct PlanItem: Decodable, Hashable, Sendable { var line: String; var query: String }

    /// Checks each part number of the BOM in the distributor sources whose keys are in the
    /// Keychain and folds the exact matches in (price breaks, stock, checked today). Runs in the
    /// background, line by line; a failed line does not stop the others; Stop cancels.
    func refreshPrices() { startRefresh(nil) }

    /// Checks again only the lines the last check could not read.
    func retryFailed() {
        let items = refreshFailures.values.map { PlanItem(line: $0.line, query: $0.query) }
        guard !items.isEmpty else { return }
        startRefresh(items)
    }

    func cancelRefresh() { refreshTask?.cancel() }

    private func startRefresh(_ only: [PlanItem]?) {
        guard refreshTask == nil else { return }
        refreshing = true
        refreshDone = 0
        refreshTotal = 0
        refreshTask = Task { [self] in
            await chain?.value
            await runRefresh(only)
            refreshing = false
            refreshTask = nil
        }
    }

    private func runRefresh(_ only: [PlanItem]?) async {
        guard let library = LibraryEngine() else { return say(String(localized: "The parts library could not be opened. Check that ViaForm can write to its Application Support folder."), error: true) }
        do {
            let state = try await library.call("state", LibParams(), as: LibraryState.self)
            let candidates = state.sources.filter { $0.access == "api" && $0.enabled }
            // Keychain reads off the main actor.
            let keyed = await Task.detached { () -> [(LibrarySource, [String: String])] in
                candidates.filter(LibraryKeychain.ready).map { ($0, LibraryKeychain.keys($0)) }
            }.value
            guard !keyed.isEmpty else {
                return say(String(localized: "No distributor keys in the Keychain. Add DigiKey, Mouser or Octopart keys in Libraries, Sources."), error: true)
            }
            var keys: [String: [String: String]] = [:]
            for (s, k) in keyed { keys[s.id] = k }
            let ids = keyed.map(\.0.id)
            let plan: [PlanItem]
            if let only { plan = only } else {
                let d = try await engine.run("refresh_plan", json: "{}")
                let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
                plan = try BomEngine.decoder.decode([PlanItem].self, from: JSONSerialization.data(withJSONObject: obj?["result"] ?? []))
            }
            refreshTotal = plan.count
            var failed: [BomRefreshFailure] = []
            var offers = 0
            var cancelled = false
            for item in plan {
                if Task.isCancelled { cancelled = true; break }
                if !VFNetwork.shared.online {
                    failed.append(BomRefreshFailure(line: item.line, query: item.query, reason: String(localized: "Offline"), offline: true))
                    refreshDone += 1
                    continue
                }
                do {
                    let hits = try await library.call("search", LibParams(query: item.query, only: ids, keys: keys), as: [LibraryHits].self)
                    let errors = hits.compactMap(\.error)
                    if !hits.isEmpty, errors.count == hits.count {
                        failed.append(BomRefreshFailure(line: item.line, query: item.query, reason: errors[0], offline: !VFNetwork.shared.online))
                    } else {
                        let raw = try JSONSerialization.jsonObject(with: LibraryEngine.encoder.encode(hits))
                        let reply = try await engine.run("apply_hits", json: BomEngine.json(["mpn": item.query, "hits": raw]))
                        if let obj = try JSONSerialization.jsonObject(with: reply) as? [String: Any], let r = obj["result"] as? [String: Any] {
                            offers += r["offers"] as? Int ?? 0
                        }
                    }
                } catch {
                    failed.append(BomRefreshFailure(line: item.line, query: item.query, reason: error.localizedDescription, offline: !VFNetwork.shared.online))
                }
                refreshDone += 1
            }
            await applyAsync("state")
            if only != nil {
                for item in plan { refreshFailures[item.line] = nil }
            } else {
                refreshFailures = [:]
            }
            for f in failed { refreshFailures[f.line] = f }
            refreshSummary = BomRefreshSummary(checked: refreshDone - failed.count, failed: failed, offers: offers,
                                               cancelled: cancelled, sources: keyed.map(\.0.name))
            if failed.isEmpty { say(nil) }
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    // MARK: Export and project files

    /// The export's text and file name, made off the main actor.
    func export(_ format: String, supplier: String? = nil) async -> (text: String, filename: String)? {
        var p: [String: Any] = ["format": format]
        if let supplier { p["supplier"] = supplier }
        busy = String(localized: "Exporting")
        defer { if pending == 0 { busy = nil } }
        do {
            let e = try BomEngine.decoder.decode(BomExport.self, from: await engine.run("export", json: BomEngine.json(p)))
            return (e.text, e.filename)
        } catch {
            say(error.localizedDescription, error: true)
            return nil
        }
    }

    /// Writes the project, off the main actor: the BOM's queue holds the design and board
    /// sessions while the engine writes the file. The BOM panel's own Save then posts
    /// `.viaformProjectSaved`, so the pipeline writes its `flow.json` into the file too
    /// (`ProjectFiles.save` does that itself). Runs after the BOM work asked for before it.
    @discardableResult
    func saveProject(_ url: URL, design: DesignModel, pcb: PCBModel) async -> Bool {
        let (cad, board) = (design.engine, pcb.engine)
        return await queued(String(localized: "Saving \(url.lastPathComponent)")) { [self] in
            say(nil)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard await applyAsync("save_project", ["path": url.path], design: cad, pcb: board) else { return false }
            notify(String(localized: "Saved \(url.lastPathComponent) with its bill of materials"), reveal: url)
            return true
        }
    }

    /// Opens the project, off the main actor (the engine replaces the design, the board and the
    /// bill on the BOM's queue), then refreshes the views. The BOM panel's own Open then posts
    /// `.viaformProjectOpened`, so the pipeline reads its `flow.json` back.
    @discardableResult
    func openProject(_ url: URL, design: DesignModel, pcb: PCBModel) async -> Bool {
        let (cad, board) = (design.engine, pcb.engine)
        return await queued(String(localized: "Opening \(url.lastPathComponent)")) { [self] in
            say(nil)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard await applyAsync("open_project", ["path": url.path], design: cad, pcb: board) else { return false }
            clearHistory()
            refreshFailures = [:]
            refreshSummary = nil
            design.refresh()
            design.zoomToFit()
            pcb.refresh()
            notify(doc.lines.isEmpty ? String(localized: "Opened \(url.lastPathComponent) (no bill of materials in it)") : String(localized: "Opened \(url.lastPathComponent)"))
            return true
        }
    }

    /// The BOM panel's own Save and Open: the file, then the notification the pipeline follows.
    /// The window's own models carry the pipeline along (never a broadcast: another window's
    /// pipeline must not write into this file). A failure offers Try Again.
    func saveFromPanel(_ url: URL, design: DesignModel, pcb: PCBModel) {
        let t0 = ActionTiming.now()
        Task { [self] in
            let ok: Bool
            if let c = ProjectFiles.context(for: design) {
                ok = await ProjectFiles.save(url, in: c)
            } else {
                ok = await saveProject(url, design: design, pcb: pcb)
                if ok { NotificationCenter.default.post(name: .viaformProjectSaved, object: url) }
            }
            if !ok {
                if message == nil { say(String(localized: "\(url.lastPathComponent) could not be saved."), error: true) }
                offerRetry { [weak self] in self?.saveFromPanel(url, design: design, pcb: pcb) }
            }
        }
        ActionTiming.click("bom.save_project", since: t0)
    }

    func openFromPanel(_ url: URL, design: DesignModel, pcb: PCBModel) {
        let t0 = ActionTiming.now()
        Task { [self] in
            let ok: Bool
            if let c = ProjectFiles.context(for: design) {
                ok = await ProjectFiles.open(url, in: c)
            } else {
                ok = await openProject(url, design: design, pcb: pcb)
                if ok {
                    let scoped = url.startAccessingSecurityScopedResource()
                    NotificationCenter.default.post(name: .viaformProjectOpened, object: url)
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
            }
            if !ok {
                if message == nil { say(String(localized: "\(url.lastPathComponent) could not be opened."), error: true) }
                offerRetry { [weak self] in self?.openFromPanel(url, design: design, pcb: pcb) }
            }
        }
        ActionTiming.click("bom.open_project", since: t0)
    }

    /// Only http(s) links leave the app.
    static func web(_ s: String?) -> URL? { LibraryModel.web(s) }

    // MARK: Launch flags for the docs

    /// `--bom=hand`, `--bom=drone`, `--bom=hand,drone` (or `all`): import those component files;
    /// `--bom-builds=N` prices N builds; `--bom-select=hand:M1` selects a line.
    func applyLaunchFlags() {
        let args = ProcessInfo.processInfo.arguments
        if let a = args.first(where: { $0.hasPrefix("--bom=") }) {
            let v = String(a.dropFirst(6))
            importAssemblies(v == "all" ? ["hand", "drone"] : v.split(separator: ",").map(String.init))
        }
        if let a = args.first(where: { $0.hasPrefix("--bom-builds=") }), let n = Int(a.dropFirst(13)) { setBuilds(n) }
        if let a = args.first(where: { $0.hasPrefix("--bom-group=") }), let g = Grouping.allCases.first(where: { $0.rawValue.lowercased() == a.dropFirst(12).lowercased() }) { grouping = g }
        if let a = args.first(where: { $0.hasPrefix("--bom-select=") }) {
            let id = String(a.dropFirst(13))
            enqueue(nil) { [self] in selection = [id] }
        }
    }

    static var launchRequested: Bool { ProcessInfo.processInfo.arguments.contains { $0 == "--bom" || $0.hasPrefix("--bom=") } }
}

// MARK: Formatting

enum BomFormat {
    /// Two decimals in the BOM's currency; "No price" when unknown (never "0", which reads as free).
    static func money(_ v: Double?, _ currency: String = "USD") -> String {
        VFFormat.money(v, currency: currency)
    }

    static func mass(_ g: Double?) -> String {
        guard let g, g >= 0 else { return String(localized: "No mass") }
        return g >= 1000 ? "\((g / 1000).formatted(.number.precision(.fractionLength(2)))) kg" : "\(g.formatted(.number.precision(.fractionLength(0...1)))) g"
    }

    /// "3 days ago" for an engine day; "Never" when there is none.
    static func checked(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return String(localized: "Never") }
        return VFFormat.relativeDate(iso: iso)
    }

    /// The full date, for the tooltip of a relative one.
    static func fullDate(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return String(localized: "Never checked") }
        return VFFormat.isoDate(iso)?.formatted(date: .long, time: .omitted) ?? iso
    }
}
