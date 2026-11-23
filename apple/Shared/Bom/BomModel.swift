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
    var kind: String { roll.excluded ? "Excluded" : (roll.made ? "Made" : "Bought") }
    var flagCount: Int { roll.flags.count }
    var checked: String { roll.checkedOn ?? "" }
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
        if flags.contains(where: { ["unsourced", "out_of_stock", "lifecycle", "no_price", "not_in_file"].contains($0) }) { return 2 }
        if flags.contains(where: { !quiet.contains($0) }) { return 1 }
        return flags.isEmpty ? 0 : -1
    }
}

// MARK: Model

/// The BOM workspace: one bill of materials for the open project, filled from the design, the
/// board and the component files, priced for N builds, refreshed through the library's sources.
@MainActor
@Observable
final class BomModel {
    enum Grouping: String, CaseIterable, Identifiable {
        case kind = "Made or Bought", none = "None", category = "Category", subassembly = "Subassembly", supplier = "Supplier", origin = "Source"
        var id: String { rawValue }
    }

    private let engine = BomEngine()
    var doc = BomDoc(name: nil, builds: 1, currency: "USD", lines: [], imports: [], refreshedOn: nil)
    var rollup = BomRollup(builds: 1, currency: "USD", today: "", lines: [], totals: BomTotals(), carts: [])
    var rows: [BomRow] = []
    var grouping = Grouping.kind
    var selection: BomRow.ID?
    var sortOrder: [KeyPathComparator<BomRow>] = []
    var filter = ""
    var onlyFlagged = false
    var message: String?
    var messageIsError = false
    var refreshing = false

    init() { apply { try engine.call("state") } }

    func say(_ text: String?, error: Bool = false) {
        message = text
        messageIsError = error
    }

    /// Runs a call that answers the state, and shows it.
    @discardableResult
    private func apply(_ f: () throws -> Data) -> Bool {
        do {
            let r = try BomEngine.decoder.decode(BomReply.self, from: f())
            doc = r.state.bom
            rollup = r.state.rollup
            let rolls = Dictionary(uniqueKeysWithValues: rollup.lines.map { ($0.id, $0) })
            rows = doc.lines.compactMap { l in rolls[l.id].map { BomRow(line: l, roll: $0) } }
            return true
        } catch {
            say(error.localizedDescription, error: true)
            return false
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
    }

    func key(_ r: BomRow) -> String {
        switch grouping {
        case .none: ""
        case .kind: r.roll.excluded ? "Left out" : (r.roll.made ? "Made" : "Bought")
        case .category: r.category.isEmpty ? "uncategorised" : r.category
        case .subassembly: r.subassembly
        case .supplier: r.roll.made ? "Made in house" : (r.supplier.isEmpty ? "Unsourced" : r.supplier)
        case .origin: r.line.origin
        }
    }

    var groups: [Group] {
        let rows = visibleRows
        guard grouping != .none else { return [Group(name: "All", rows: rows)] }
        var order: [String] = []
        var by: [String: [BomRow]] = [:]
        for r in rows {
            let k = key(r)
            if by[k] == nil { order.append(k) }
            by[k, default: []].append(r)
        }
        if grouping == .kind {
            order.sort { (["Made", "Bought", "Left out"].firstIndex(of: $0) ?? 3) < (["Made", "Bought", "Left out"].firstIndex(of: $1) ?? 3) }
        } else if sortOrder.isEmpty { order.sort { $0.localizedStandardCompare($1) == .orderedAscending } }
        return order.map { Group(name: $0, rows: by[$0] ?? []) }
    }

    var selected: BomRow? { rows.first { $0.id == selection } }

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

    // MARK: Edits

    func setBuilds(_ n: Int) { apply { try engine.call("set", ["builds": max(1, n)]) } }

    func edit(_ id: String, _ changes: [String: Any]) { apply { try engine.call("edit", ["id": id, "changes": changes]) } }

    func setQty(_ row: BomRow, _ n: Int) { if n >= 0, n != row.line.perBuild { edit(row.id, ["qty": n]) } }

    func setNotes(_ row: BomRow, _ text: String) { if text != (row.line.userNotes ?? "") { edit(row.id, ["notes": text]) } }

    func setSupplier(_ row: BomRow, _ s: String?) { edit(row.id, ["supplier": s ?? NSNull()]) }

    func setExcluded(_ row: BomRow, _ on: Bool) { edit(row.id, ["excluded": on]) }

    func addLine() {
        if apply({ try engine.call("add", ["line": ["description": "New part", "category": "other"]]) }) {
            selection = rows.last(where: { $0.line.origin == "manual" })?.id
        }
    }

    func remove(_ row: BomRow) { apply { try engine.call("remove", ["id": row.id]) } }

    func removeOrigin(_ origin: String) { apply { try engine.call("remove_origin", ["origin": origin]) } }

    // MARK: Sources

    /// The component files of the repository (docs/components), else the BOM's test fixtures.
    static var componentsFolder: URL? {
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
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            if apply({ try engine.call("import_dir", ["dir": url.path]) }) { say("Imported the component files of \(url.lastPathComponent)") }
        } else if apply({ try engine.call("import_file", ["path": url.path]) }) {
            say("Imported \(url.lastPathComponent)")
        }
    }

    /// The generated assembly of `name` (docs/generative/<name>/assembly.json), when there is one.
    static func assemblyFile(_ name: String) -> URL? {
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
        var done: [String] = []
        var issues: [String] = []
        for n in names {
            if let asm = Self.assemblyFile(n) {
                if let r = importAssembly(asm) {
                    done.append(n)
                    issues += r
                }
            } else if let dir = Self.componentsFolder {
                let u = dir.appendingPathComponent("\(n).json")
                if FileManager.default.fileExists(atPath: u.path), apply({ try engine.call("import_file", ["path": u.path]) }) { done.append(n) }
            }
        }
        assemblyIssues = issues
        if done.isEmpty { return say("Nothing to import for \(names.joined(separator: ", "))", error: true) }
        let t = rollup.totals
        say("Imported \(done.joined(separator: " and ")): \(t.madeLines) made, \(t.boughtLines) bought" + (issues.isEmpty ? "" : ". " + issues.joined(separator: "; ")), error: !issues.isEmpty)
    }

    /// Imports one generated assembly with its component file; answers what does not line up.
    @discardableResult
    func importAssembly(_ url: URL) -> [String]? {
        var result: [String: Any] = [:]
        let ok = apply {
            let d = try engine.call("import_assembly", ["path": url.path])
            result = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["result"] as? [String: Any] ?? [:]
            return d
        }
        guard ok else { return nil }
        let name = result["assembly"] as? String ?? url.deletingLastPathComponent().lastPathComponent
        var issues: [String] = []
        if let m = result["missing_from_file"] as? [String], !m.isEmpty { issues.append("\(name): \(m.joined(separator: ", ")) not in the component file") }
        if let m = result["not_placed"] as? [String], !m.isEmpty { issues.append("\(name): \(m.joined(separator: ", ")) not placed") }
        if result["components"] is NSNull || result["components"] == nil { issues.append("\(name): no component file") }
        return issues
    }

    func syncDesign(_ design: DesignModel) {
        if apply({ try engine.call("sync_design", design: design.engine.session) }) { say("Design parts brought in") }
    }

    func syncPCB(_ pcb: PCBModel) {
        if apply({ try engine.call("sync_pcb", pcb: pcb.engine.session) }) { say("PCB components brought in") }
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

    private struct PlanItem: Decodable { var line: String; var query: String }

    /// Searches each part number of the BOM in the distributor sources whose keys are in the
    /// Keychain, and folds the exact matches in (price breaks, stock, checked today).
    func refreshPrices() async {
        guard let library = LibraryEngine() else { return say("The library could not be opened", error: true) }
        refreshing = true
        defer { refreshing = false }
        do {
            let state = try await library.call("state", LibParams(), as: LibraryState.self)
            let apis = state.sources.filter { $0.access == "api" && $0.enabled && LibraryKeychain.ready($0) }
            guard !apis.isEmpty else {
                return say("No distributor keys in the Keychain: add DigiKey, Mouser or Octopart keys in Libraries > Sources", error: true)
            }
            var keys: [String: [String: String]] = [:]
            for s in apis { keys[s.id] = LibraryKeychain.keys(s) }
            let plan = try BomEngine.decoder.decode([PlanItem].self, from: planData())
            var offers = 0
            for (i, item) in plan.enumerated() {
                say("Checking \(item.query) (\(i + 1) of \(plan.count))")
                let hits = try await library.call("search", LibParams(query: item.query, only: apis.map(\.id), keys: keys), as: [LibraryHits].self)
                let data = try LibraryEngine.encoder.encode(hits)
                let raw = try JSONSerialization.jsonObject(with: data)
                let reply = try engine.call("apply_hits", ["mpn": item.query, "hits": raw])
                if let obj = try JSONSerialization.jsonObject(with: reply) as? [String: Any], let r = obj["result"] as? [String: Any] {
                    offers += r["offers"] as? Int ?? 0
                }
            }
            apply { try engine.call("state") }
            say("Checked \(plan.count) part numbers with \(apis.map(\.name).joined(separator: ", ")): \(offers) offers")
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    private func planData() throws -> Data {
        let d = try engine.call("refresh_plan")
        let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        return try JSONSerialization.data(withJSONObject: obj?["result"] ?? [])
    }

    // MARK: Export and project files

    func export(_ format: String, supplier: String? = nil) -> (text: String, filename: String)? {
        var p: [String: Any] = ["format": format]
        if let supplier { p["supplier"] = supplier }
        do {
            let e = try BomEngine.decoder.decode(BomExport.self, from: engine.call("export", p))
            return (e.text, e.filename)
        } catch {
            say(error.localizedDescription, error: true)
            return nil
        }
    }

    /// Writes the project. The BOM panel's own Save then posts `.viaformProjectSaved`, so the
    /// pipeline writes its `flow.json` into the file too (`ProjectFiles.save` does that itself).
    @discardableResult
    func saveProject(_ url: URL, design: DesignModel, pcb: PCBModel) -> Bool {
        guard apply({ try engine.call("save_project", ["path": url.path], design: design.engine.session, pcb: pcb.engine.session) }) else { return false }
        say("Saved \(url.lastPathComponent) with its bill of materials")
        return true
    }

    /// Opens the project. The BOM panel's own Open then posts `.viaformProjectOpened`, so the
    /// pipeline reads its `flow.json` back.
    @discardableResult
    func openProject(_ url: URL, design: DesignModel, pcb: PCBModel) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard apply({ try engine.call("open_project", ["path": url.path], design: design.engine.session, pcb: pcb.engine.session) }) else { return false }
        design.refresh()
        design.zoomToFit()
        pcb.refresh()
        say(doc.lines.isEmpty ? "Opened \(url.lastPathComponent) (no bill of materials in it)" : "Opened \(url.lastPathComponent)")
        return true
    }

    /// The BOM panel's own Save and Open: the file, then the notification the pipeline follows.
    func saveFromPanel(_ url: URL, design: DesignModel, pcb: PCBModel) {
        if saveProject(url, design: design, pcb: pcb) { NotificationCenter.default.post(name: .viaformProjectSaved, object: url) }
    }

    func openFromPanel(_ url: URL, design: DesignModel, pcb: PCBModel) {
        guard openProject(url, design: design, pcb: pcb) else { return }
        // The pipeline reads the file while the notification is delivered (synchronously, on main).
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        NotificationCenter.default.post(name: .viaformProjectOpened, object: url)
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
        if let a = args.first(where: { $0.hasPrefix("--bom-select=") }) { selection = String(a.dropFirst(13)) }
    }

    static var launchRequested: Bool { ProcessInfo.processInfo.arguments.contains { $0 == "--bom" || $0.hasPrefix("--bom=") } }
}

// MARK: Formatting

enum BomFormat {
    static func money(_ v: Double?, _ currency: String = "USD") -> String {
        guard let v, v >= 0 else { return "" }
        return v.formatted(.currency(code: currency).precision(.fractionLength(v < 1 && v > 0 ? 3 : 2)))
    }

    static func mass(_ g: Double?) -> String {
        guard let g, g >= 0 else { return "" }
        return g >= 1000 ? "\((g / 1000).formatted(.number.precision(.fractionLength(2)))) kg" : "\(g.formatted(.number.precision(.fractionLength(0...1)))) g"
    }
}
