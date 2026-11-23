import Foundation
import Observation

// MARK: Shapes from the library (crate viaform-library, snake_case JSON)

struct LibraryKey: Codable, Hashable, Sendable {
    var id: String
    var label: String
    var optional: Bool
    var placeholder: String?
}

struct LibrarySource: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var domain: String
    /// "local", "api" or "manual".
    var access: String
    var summary: String
    var keys: [LibraryKey]?
    var signup: String?
    var terms: String?
    var searchUrl: String?
    var caveats: [String]?
    var planned: Bool
    var enabled: Bool
    var ready: Bool
    var detail: String?
}

struct LibraryPrice: Codable, Hashable, Sendable {
    var quantity: Double
    var price: Double
    var currency: String
}

struct LibraryFile: Codable, Hashable, Sendable {
    var label: String
    var path: String
}

/// What the app can do with an item: the JSON is tagged by "kind".
enum LibraryUse: Codable, Hashable, Sendable {
    case kicadSymbol(path: String, symbol: String, footprint: String?)
    case kicadFootprint(path: String)
    case step(path: String)
    case hardware(family: String, size: String, length: Double?)
    case schematic(part: String, value: String)

    private enum Keys: String, CodingKey { case kind, path, symbol, footprint, family, size, length, part, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "kicad_symbol": self = .kicadSymbol(path: try c.decode(String.self, forKey: .path), symbol: try c.decode(String.self, forKey: .symbol), footprint: try c.decodeIfPresent(String.self, forKey: .footprint))
        case "kicad_footprint": self = .kicadFootprint(path: try c.decode(String.self, forKey: .path))
        case "step": self = .step(path: try c.decode(String.self, forKey: .path))
        case "hardware": self = .hardware(family: try c.decode(String.self, forKey: .family), size: try c.decode(String.self, forKey: .size), length: try c.decodeIfPresent(Double.self, forKey: .length))
        case "schematic": self = .schematic(part: try c.decode(String.self, forKey: .part), value: try c.decode(String.self, forKey: .value))
        case let k: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown use \(k)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .kicadSymbol(path, symbol, footprint):
            try c.encode("kicad_symbol", forKey: .kind); try c.encode(path, forKey: .path); try c.encode(symbol, forKey: .symbol); try c.encodeIfPresent(footprint, forKey: .footprint)
        case let .kicadFootprint(path): try c.encode("kicad_footprint", forKey: .kind); try c.encode(path, forKey: .path)
        case let .step(path): try c.encode("step", forKey: .kind); try c.encode(path, forKey: .path)
        case let .hardware(family, size, length):
            try c.encode("hardware", forKey: .kind); try c.encode(family, forKey: .family); try c.encode(size, forKey: .size); try c.encodeIfPresent(length, forKey: .length)
        case let .schematic(part, value): try c.encode("schematic", forKey: .kind); try c.encode(part, forKey: .part); try c.encode(value, forKey: .value)
        }
    }

    /// The button that runs it.
    var label: String {
        switch self {
        case .kicadSymbol(_, _, let fp): fp == nil ? "Place Symbol" : "Place Symbol + Footprint"
        case .kicadFootprint: "Assign Footprint"
        case .step: "Insert 3D Model"
        case .hardware: "Insert in Design"
        case .schematic: "Place in Schematic"
        }
    }

    var symbol: String {
        switch self {
        case .kicadSymbol, .schematic: "point.3.connected.trianglepath.dotted"
        case .kicadFootprint: "square.grid.3x3.square"
        case .step, .hardware: "cube"
        }
    }

    /// Goes to the 3D design (else to the schematic or board).
    var mechanical: Bool {
        switch self { case .step, .hardware: true; default: false }
    }
}

struct LibraryItem: Codable, Hashable, Identifiable, Sendable {
    var key: String = ""
    var source: String
    var partNumber: String
    var name: String = ""
    var description: String?
    var manufacturer: String?
    var mpn: String?
    var category: String?
    var domain: String = "both"
    var url: String?
    var datasheet: String?
    var stock: Double?
    var prices: [LibraryPrice] = []
    var files: [LibraryFile] = []
    var uses: [LibraryUse] = []
    var notes: String?
    var tags: [String] = []
    var savedAt: UInt64?

    var id: String { key.isEmpty ? "\(source):\(partNumber)" : key }

    init(source: String, partNumber: String = "") {
        self.source = source
        self.partNumber = partNumber
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        source = try c.decode(String.self, forKey: .source)
        partNumber = try c.decode(String.self, forKey: .partNumber)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer)
        mpn = try c.decodeIfPresent(String.self, forKey: .mpn)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? "both"
        url = try c.decodeIfPresent(String.self, forKey: .url)
        datasheet = try c.decodeIfPresent(String.self, forKey: .datasheet)
        stock = try c.decodeIfPresent(Double.self, forKey: .stock)
        prices = try c.decodeIfPresent([LibraryPrice].self, forKey: .prices) ?? []
        files = try c.decodeIfPresent([LibraryFile].self, forKey: .files) ?? []
        uses = try c.decodeIfPresent([LibraryUse].self, forKey: .uses) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        savedAt = try c.decodeIfPresent(UInt64.self, forKey: .savedAt)
    }

    /// "0.42 USD (1+), 0.31 USD (100+)", the first breaks.
    var priceText: String? {
        guard !prices.isEmpty else { return nil }
        return prices.prefix(3).map { p in
            let n = p.price.formatted(.number.precision(.fractionLength(0...4)))
            return "\(n) \(p.currency) (\(Int(p.quantity))+)"
        }.joined(separator: ", ")
    }
}

struct LibraryHits: Codable, Hashable, Sendable {
    var source: String
    var items: [LibraryItem]
    var total: Int
    var error: String?
}

struct LibraryState: Codable, Sendable {
    var sources: [LibrarySource]
    var items: [LibraryItem]
    var kicadRoots: [String]
}

// MARK: Model

/// The Libraries panel: search every source at once, keep parts, set up the sources and their
/// keys, and send a part to the design or the schematic.
@MainActor
@Observable
final class LibraryModel {
    enum Tab: String, CaseIterable { case search = "Search", saved = "Saved", sources = "Sources" }

    private let engine: LibraryEngine?
    var tab = Tab.search
    var sources: [LibrarySource] = []
    var items: [LibraryItem] = []
    var kicadRoots: [String] = []
    var query = ""
    var hits: [LibraryHits] = []
    var searching = false
    var message: String?
    var messageIsError = false
    /// A part being entered by hand or from a pasted link, shown in the editor sheet.
    var draft: LibraryItem?

    init() {
        engine = LibraryEngine()
        if engine == nil { say("The library folder could not be opened: \(LibraryEngine.folder.path)", error: true) }
    }

    func say(_ text: String?, error: Bool = false) {
        message = text
        messageIsError = error
    }

    func source(_ id: String) -> LibrarySource? { sources.first { $0.id == id } }

    private struct Params: Encodable, Sendable {
        var keyed: [String]?
        var query: String?
        var only: [String]?
        var keys: [String: [String: String]]?
        var item: LibraryItem?
        var key: String?
        var path: String?
        var id: String?
        var on: Bool?
        var roots: [String]?
        var url: String?
        var reference: String?
    }

    private func call<T: Decodable & Sendable>(_ method: String, _ p: Params, as: T.Type = T.self) async throws -> T {
        guard let engine else { throw EngineError(message: "The library is not open") }
        return try await engine.call(method, p, as: T.self)
    }

    func load() async {
        // The API sources whose required keys are in the Keychain.
        let keyed = sources.filter { $0.access == "api" && LibraryKeychain.ready($0) }.map(\.id)
        do {
            let s = try await call("state", Params(keyed: keyed), as: LibraryState.self)
            sources = s.sources.map { src in
                guard src.access == "api" else { return src }
                var src = src
                src.ready = LibraryKeychain.ready(src)
                src.detail = src.ready ? "Keys in the Keychain" : "No keys yet"
                return src
            }
            items = s.items
            kicadRoots = s.kicadRoots
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { hits = []; return }
        if sources.isEmpty { await load() }
        var keys: [String: [String: String]] = [:]
        for s in sources where s.access == "api" && s.enabled && LibraryKeychain.ready(s) {
            keys[s.id] = LibraryKeychain.keys(s)
        }
        searching = true
        defer { searching = false }
        do {
            hits = try await call("search", Params(query: q, keys: keys), as: [LibraryHits].self)
            say(nil)
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    func isSaved(_ item: LibraryItem) -> Bool { items.contains { $0.key == item.key && !item.key.isEmpty } }

    @discardableResult
    func save(_ item: LibraryItem) async -> LibraryItem? {
        do {
            let saved = try await call("save", Params(item: item), as: LibraryItem.self)
            await load()
            say("Saved \(saved.name.isEmpty ? saved.partNumber : saved.name)")
            return saved
        } catch {
            say(error.localizedDescription, error: true)
            return nil
        }
    }

    func remove(_ item: LibraryItem) async {
        do {
            _ = try await call("remove", Params(key: item.key), as: LibraryNothing?.self)
            await load()
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Copies a CAD file (STEP, KiCad footprint or symbol) into the library and attaches it.
    func attach(_ file: URL, to item: LibraryItem) async {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        do {
            _ = try await call("attach", Params(key: item.key, path: file.path), as: LibraryItem.self)
            await load()
            say("Attached \(file.lastPathComponent)")
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    func setEnabled(_ id: String, _ on: Bool) async {
        do {
            _ = try await call("enable", Params(id: id, on: on), as: LibraryNothing?.self)
            await load()
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Writes the typed keys to the Keychain. A blank field keeps its saved value.
    func setKeys(_ source: LibrarySource, _ values: [String: String]) async {
        do {
            for k in source.keys ?? [] {
                let v = values[k.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !v.isEmpty { try LibraryKeychain.set(source.id, k.id, v) }
            }
            _ = try await call("forget_tokens", Params(), as: LibraryNothing?.self)
            say(LibraryKeychain.ready(source) ? "\(source.name) keys saved in the Keychain" : "\(source.name): some required keys are still missing", error: !LibraryKeychain.ready(source))
        } catch {
            say(error.localizedDescription, error: true)
        }
        await load()
    }

    func forgetKeys(_ source: LibrarySource) async {
        for k in source.keys ?? [] { LibraryKeychain.remove(source.id, k.id) }
        _ = try? await call("forget_tokens", Params(), as: LibraryNothing?.self)
        say("\(source.name) keys removed from the Keychain")
        await load()
    }

    func setKicadRoots(_ roots: [String]) async {
        do {
            _ = try await call("set_kicad_roots", Params(roots: roots), as: LibraryNothing?.self)
            await load()
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Reads a pasted product link (nothing is fetched) and opens the editor on it.
    func paste(link: String) async {
        do {
            if let it = try await call("from_link", Params(url: link), as: LibraryItem?.self) {
                draft = it
            } else {
                say("Paste a link that starts with http:// or https://", error: true)
            }
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// The shop's own search page for the query, opened in the browser (never fetched here).
    func searchPage(_ id: String) async -> URL? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let s = try? await call("search_page", Params(query: q, id: id), as: String?.self) else { return nil }
        return Self.web(s)
    }

    /// Only http(s) links leave the app.
    static func web(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
        return u
    }

    // MARK: Into the design or the schematic

    /// Puts `item` into the 3D design or the electronics project, as `use` says.
    func use(_ u: LibraryUse, of item: LibraryItem, design: DesignModel, pcb: PCBModel) async {
        switch u {
        case let .hardware(family, size, length):
            var p: [String: Any] = ["family": family, "size": size]
            if let length { p["length"] = length }
            if design.run("parts.insert", p) != nil { design.zoomToFit(); say("Inserted \(item.name)") }
            else { say(design.message ?? "The part was not inserted", error: true) }
        case let .step(path):
            if design.run("file.insert_step", ["path": path]) != nil { design.zoomToFit(); say("Inserted \(item.name)") }
            else { say(design.message ?? "The model was not inserted", error: true) }
        case let .kicadSymbol(path, symbol, footprint):
            let r = pcb.run("component.place_library", ["path": path, "symbol": symbol, "position": nextPosition(pcb)])
            guard r != nil else { return say(pcb.message ?? "The symbol was not placed", error: true) }
            let id = ((r as? [String: Any])?["result"] as? [String: Any])?["id"] as? Int
            if let id, let footprint, pcb.run("footprint.assign", ["id": id, "path": footprint]) == nil {
                return say("Placed, but the footprint was refused: \(pcb.message ?? "")", error: true)
            }
            say("Placed \(symbol) in the schematic")
        case let .schematic(part, value):
            if pcb.run("component.add", ["kind": part, "position": nextPosition(pcb), "value": value]) != nil { say("Placed \(value)") }
            else { say(pcb.message ?? "The part was not placed", error: true) }
        case let .kicadFootprint(path):
            // On the board the selection is a footprint: its component takes the new footprint.
            let component = pcb.selection.flatMap { sel in pcb.sheet == .board ? pcb.footprint(sel)?.component : sel }
            guard let component else { return say("Select a part first, then assign the footprint to it", error: true) }
            if pcb.run("footprint.assign", ["id": component, "path": path]) != nil { say("Footprint assigned") }
            else { say(pcb.message ?? "The footprint was refused", error: true) }
        }
    }

    /// Schematic parts go to the right of what is placed already.
    private func nextPosition(_ pcb: PCBModel) -> [String: Double] {
        let xs = (pcb.project?.components ?? []).map(\.position.x)
        return ["x": xs.max().map { $0 + 20 } ?? 0, "y": 0]
    }
}
