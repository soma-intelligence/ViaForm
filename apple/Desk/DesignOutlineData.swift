#if os(macOS)
import Foundation
import Observation

/// A timeline folder (Fusion's feature group): its id, name and the features it holds, in
/// timeline order, including the features of the folders nested in it.
struct TimelineFolder: Identifiable, Hashable {
    var id: Int
    var name: String
    var parent: Int?
    var features: [Int]
}

/// What the Mac browser and timeline read from the design engine besides the snapshot: the
/// timeline folders, the named views, the hidden origin and construction items, which feature
/// made each body, each component's first placement and the defined state of every sketch. Read
/// once per design revision (every change to the design or to what is hidden moves it), never on
/// a camera move, and shared by the browser, the timeline and Find in Browser through
/// `DesignOutlineCache`.
struct DesignOutlineData: Equatable {
    struct NamedView: Identifiable, Hashable {
        var name: String
        var camera: [String: Double]
        var target: [Double]
        var id: String { name }
    }

    var folders: [TimelineFolder] = []
    var views: [NamedView] = []
    var hiddenOrigin: Set<String> = []
    var bodyFeature: [String: Int] = [:]
    /// Component id to the id of its first placement (for `browser.visibility` paths).
    var placement: [Int: Int] = [:]
    /// Sketch id to its defined state, from `sketch.inspect` (M-11). The open sketch's live state
    /// comes from the model instead (`SketchDefinedStates.state(_:sketch:in:)`).
    var sketchStates: [Int: SketchDefinedState] = [:]

    /// Construction feature types, as `document.inspect` names them.
    static let constructionTypes: Set<String> = ["ConstructionPlane", "ConstructionAxis", "ConstructionPoint"]

    /// Reads everything from the engine. Views never call this: they read
    /// `DesignOutlineCache.shared.data(model)` in `.task(id: model.snapshot.revision)`.
    @MainActor static func load(_ model: DesignModel, knownFolder: Int = 0) -> DesignOutlineData {
        var d = DesignOutlineData()
        d.folders = loadFolders(model, knownFolder: knownFolder)
        d.sketchStates = SketchDefinedStates.load(model)
        if let r = (try? model.engine.execute("view.list")) as? [String: Any], let list = r["views"] as? [[String: Any]] {
            d.views = list.compactMap { v in
                guard let name = v["name"] as? String else { return nil }
                var cam: [String: Double] = [:]
                for k in ["yaw", "pitch", "distance", "fov", "roll"] { if let x = v[k] as? Double { cam[k] = x } }
                return NamedView(name: name, camera: cam, target: Self.point(v["target"]))
            }
        }
        if let r = (try? model.engine.execute("document.inspect")) as? [String: Any] {
            d.hiddenOrigin = Set(r["hidden_origin"] as? [String] ?? [])
            for b in r["bodies"] as? [[String: Any]] ?? [] {
                if let n = b["name"] as? String, let f = b["feature"] as? Int { d.bodyFeature[n] = f }
            }
        }
        if let r = (try? model.engine.execute("component.list")) as? [String: Any] {
            for c in r["components"] as? [[String: Any]] ?? [] {
                guard let id = c["id"] as? Int, id != 0,
                      let occ = (c["occurrences"] as? [[String: Any]])?.first, let o = occ["id"] as? Int else { continue }
                d.placement[id] = o
            }
        }
        return d
    }

    /// `target` comes as `[x, y, z]` or as `{x, y, z}`, depending on the engine's serialiser.
    private static func point(_ v: Any?) -> [Double] {
        if let a = v as? [Double], a.count == 3 { return a }
        if let o = v as? [String: Double], let x = o["x"], let y = o["y"], let z = o["z"] { return [x, y, z] }
        return [0, 0, 0]
    }

    /// Consecutive misses past the highest known id after which the folder probe stops.
    static let missRun = 256

    /// The timeline folders. The engine has no command that lists them (an upstream need:
    /// `document.inspect` could return `timeline_groups`), so the ids that are not features are
    /// asked about with `timeline.inspect {group}`. Folder ids come from the same counter as
    /// feature ids: every gap below the highest known id (a feature, `knownFolder`, or a folder
    /// found on the way) is probed, then the probe goes on until `missRun` ids in a row are not
    /// folders. No hard cap, so a folder with a high id is never dropped silently.
    static func loadFolders(_ model: DesignModel, knownFolder: Int = 0) -> [TimelineFolder] {
        let features = model.snapshot.timeline.map(\.id)
        let known = Set(features)
        var top = max(features.max() ?? 0, knownFolder)
        var raw: [(TimelineFolder, [Int])] = []
        var id = 0
        while true {
            id += 1
            if id > top + missRun { break }
            if known.contains(id) { continue }
            guard let r = (try? model.engine.execute("timeline.inspect", ["group": id])) as? [String: Any],
                  let name = r["name"] as? String else { continue }
            let own = (r["features"] as? [Int]) ?? []
            raw.append((TimelineFolder(id: id, name: name, parent: r["parent"] as? Int, features: own), own))
            top = max(top, id)
        }
        // A folder holds its nested folders' features too.
        func all(_ id: Int, depth: Int = 0) -> [Int] {
            guard depth < 32, let f = raw.first(where: { $0.0.id == id }) else { return [] }
            return f.1 + raw.filter { $0.0.parent == id }.flatMap { all($0.0.id, depth: depth + 1) }
        }
        let order = Dictionary(uniqueKeysWithValues: features.enumerated().map { ($1, $0) })
        return raw.map { f, _ in
            var g = f
            g.features = all(f.id).sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
            return g
        }
    }
}

/// One `DesignOutlineData` per design model and revision, shared by the browser, the timeline
/// and Find in Browser, so the engine is asked once per revision whoever asks first. Entries
/// hold their model weakly and are purged when it goes away; the highest folder id seen per
/// model is kept across revisions so the folder probe starts from it.
@MainActor
final class DesignOutlineCache {
    static let shared = DesignOutlineCache()

    private final class Entry {
        weak var model: DesignModel?
        var revision: Int
        var data: DesignOutlineData
        var knownFolder: Int
        init(model: DesignModel, revision: Int, data: DesignOutlineData, knownFolder: Int) {
            self.model = model; self.revision = revision; self.data = data; self.knownFolder = knownFolder
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// How many times the engine was read, for the self test.
    private(set) var loads = 0

    /// The outline of the model's current revision, read from the engine only when the revision
    /// moved since the last read.
    func data(_ model: DesignModel) -> DesignOutlineData {
        purge()
        let key = ObjectIdentifier(model)
        let revision = model.snapshot.revision
        if let e = entries[key], e.model === model, e.revision == revision { return e.data }
        let known = entries[key].flatMap { $0.model === model ? $0.knownFolder : nil } ?? 0
        let d = DesignOutlineData.load(model, knownFolder: known)
        loads += 1
        entries[key] = Entry(model: model, revision: revision, data: d,
                             knownFolder: max(known, d.folders.map(\.id).max() ?? 0))
        return d
    }

    /// A folder id the caller just made (the `timeline.group` reply): the next probe reaches it
    /// even when it lies far past the last feature.
    func note(folder id: Int, of model: DesignModel) {
        guard let e = entries[ObjectIdentifier(model)], e.model === model else {
            entries[ObjectIdentifier(model)] = Entry(model: model, revision: -1, data: DesignOutlineData(), knownFolder: id)
            return
        }
        e.knownFolder = max(e.knownFolder, id)
    }

    /// Drops the entries whose model is gone.
    private func purge() {
        entries = entries.filter { $0.value.model != nil }
    }

    var count: Int { purge(); return entries.count }
}

/// The timeline's Find in Browser: it asks the open design's browser to show one feature's row
/// (a sketch, a construction item, or the bodies the feature made), expanding its folder.
@MainActor @Observable
final class BrowserReveal {
    static let shared = BrowserReveal()

    struct Request: Equatable {
        var model: ObjectIdentifier
        var folder: String
        var item: BrowserItem?
        var bodies: Set<String>
        var serial: Int
    }

    private(set) var request: Request?

    /// False when the feature has no row in the browser (then the design says so).
    @discardableResult
    func reveal(_ f: DesignSnapshot.Feature, in model: DesignModel) -> Bool {
        let serial = (request?.serial ?? 0) + 1
        let id = ObjectIdentifier(model)
        if f.type == "Sketch" {
            request = Request(model: id, folder: "Sketches", item: .sketch(f.id), bodies: [], serial: serial)
            return true
        }
        if DesignOutlineData.constructionTypes.contains(f.type) {
            request = Request(model: id, folder: "Construction", item: .construction(f.name), bodies: [], serial: serial)
            return true
        }
        let made = DesignOutlineCache.shared.data(model).bodyFeature.filter { $0.value == f.id }.map(\.key)
        guard !made.isEmpty else {
            model.flash(String(localized: "\(f.name) has no row in the browser: it made no body of its own."))
            return false
        }
        request = Request(model: id, folder: "Bodies", item: nil, bodies: Set(made), serial: serial)
        return true
    }
}

/// The camera a reply carries (`view.apply`, `view.normal_to`, `view.navigate`), as the
/// viewport's camera.
enum CameraReply {
    static func camera(_ reply: Any?) -> OrbitCamera? {
        guard let r = reply as? [String: Any], let c = r["camera"],
              let data = try? JSONSerialization.data(withJSONObject: c) else { return nil }
        return try? JSONDecoder().decode(OrbitCamera.self, from: data)
    }

    /// Runs a camera command and moves the viewport there. False when the engine refused it.
    @discardableResult
    static func run(_ model: DesignModel, _ id: String, _ params: [String: Any]) -> Bool {
        guard let cam = camera(model.run(id, params, quiet: true)) else { return false }
        // The up axis comes from the design; the engine reply does not always repeat it.
        var c = cam
        c.up = model.camera.up
        model.camera = c
        model.cameraChanged(final: true)
        return true
    }
}

/// Checks for the Mac browser and timeline (M-13, M-14), through real engine commands.
enum MacBrowserSelfTest {
    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let m = DesignModel()
        m.run("solid.box", ["length": 20, "width": 20, "height": 10])
        m.run("sketch.create", ["plane": "XY", "name": "Holes"])
        m.run("sketch.circle.center", ["center": [5, 5], "diameter": 4])
        m.run("sketch.finish")
        m.run("solid.box", ["length": 5, "width": 5, "height": 5, "corner": [40, 0, 0], "operation": "new"])
        let tl = m.snapshot.timeline
        out.append((tl.count >= 3, "M-13 three features to work with (\(tl.count))"))
        guard tl.count >= 3 else { return out }

        // Rename a feature (slow click or the menu): timeline.rename.
        m.run("timeline.rename", ["feature": tl[0].id, "name": "Base"])
        out.append((m.snapshot.timeline.first?.name == "Base", "M-13 a feature renames from the timeline"))

        // Group two features; the folder shows up in the outline data.
        m.run("timeline.group", ["name": "Pair", "features": [tl[0].id, tl[1].id]])
        let folders = DesignOutlineData.loadFolders(m)
        let pair = folders.first { $0.name == "Pair" }
        out.append((pair?.features == [tl[0].id, tl[1].id], "M-13 Create Group makes a folder of two features (\(folders.map(\.name)))"))
        let slots = TimelineLayout(features: m.snapshot.timeline, folders: folders, collapsed: Set(pair.map { [$0.id] } ?? []))
        out.append((slots.slots.count == m.snapshot.timeline.count - 1, "M-13 a collapsed group shows one tile for its features (\(slots.slots.count) tiles)"))

        // Dependents of the sketch: nothing breaks without it in this design.
        let deps = (try? m.engine.execute("timeline.dependents", ["feature": tl[1].id])) as? [String: Any]
        out.append((deps?["would_fail"] is [Any], "M-13 Show Dependents answers (\(deps.map { Array($0.keys).sorted() } ?? []))"))

        // A named view saves the camera and gives it back.
        var cam = m.camera
        cam.yaw = 0.5; cam.pitch = 0.25; cam.distance = 321
        m.run("view.save", ["name": "Check", "camera": cam.dictionary], quiet: true)
        let views = DesignOutlineData.load(m).views
        out.append((views.contains { $0.name == "Check" }, "M-14 Named View saves (\(views.map(\.name)))"))
        m.camera = OrbitCamera()
        let applied = CameraReply.run(m, "view.apply", ["view": "Check"])
        out.append((applied && abs(m.camera.distance - 321) < 1e-6 && abs(m.camera.yaw - 0.5) < 1e-6,
                    "M-14 Named View applies (distance \(m.camera.distance))"))

        // Hide a sketch with its eye; the folder eye then shows it again.
        let sketch = m.snapshot.sketches.first?.id ?? -1
        m.run("browser.visibility", ["visible": false, "items": [sketch]], quiet: true)
        out.append((m.snapshot.sketches.first?.visible == false, "M-14 a sketch hides from its eye"))
        m.run("browser.visibility", ["visible": true, "folder": "sketches"], quiet: true)
        out.append((m.snapshot.sketches.first?.visible == true, "M-14 the Sketches folder eye shows it again"))

        // The origin plane eye.
        m.run("browser.visibility", ["visible": false, "items": ["XY"]], quiet: true)
        out.append((DesignOutlineData.load(m).hiddenOrigin.contains("XY"), "M-14 an origin plane hides from its eye"))

        // The outline is read once per revision, whoever asks (browser, timeline, reveal).
        let cache = DesignOutlineCache.shared
        let before = cache.loads
        let first = cache.data(m)
        _ = cache.data(m)
        _ = cache.data(m).folders
        if let f = m.snapshot.timeline.first { BrowserReveal.shared.reveal(f, in: m) }
        out.append((cache.loads == before + 1 && first.folders.contains { $0.name == "Pair" },
                    "Outline loads once per revision for every reader (\(cache.loads - before) loads)"))
        m.run("timeline.rename", ["feature": tl[0].id, "name": "Base 2"])
        _ = cache.data(m)
        _ = cache.data(m)
        out.append((cache.loads == before + 2, "Outline loads again once after a change (\(cache.loads - before) loads)"))

        // A folder whose id lies far past the last feature (ids eaten by folders made and
        // removed since) is still found, with no folder noted and no read in between.
        let gap = 150
        for _ in 0..<gap {
            if let r = m.run("timeline.group", ["features": [tl[2].id]], quiet: true) as? [String: Any], let g = r["group"] as? Int {
                m.run("timeline.ungroup", ["group": g], quiet: true)
            }
        }
        let far = (m.run("timeline.group", ["name": "Far", "features": [tl[2].id]], quiet: true) as? [String: Any])?["group"] as? Int ?? -1
        let maxFeature = m.snapshot.timeline.map(\.id).max() ?? 0
        let farFound = DesignOutlineData.loadFolders(m).contains { $0.id == far && $0.name == "Far" }
        out.append((far > maxFeature + 64 && farFound,
                    "A folder with a high id is found (id \(far), last feature \(maxFeature))"))
        let cached = cache.data(m).folders.contains { $0.id == far }
        out.append((cached, "The shared outline holds the high-id folder"))

        // Entries go away with their model.
        let kept = cache.count
        var held = 0
        do {
            let other = DesignModel()
            _ = cache.data(other)
            held = cache.count
        }
        out.append((held == kept + 1 && cache.count == kept,
                    "Outline cache purges entries of closed models (\(kept), \(held) with another, then \(cache.count))"))
        return out
    }
}
#endif
