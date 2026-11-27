#if os(macOS)
import Foundation

/// Live measure of the selection for the status bar (M-12): on each selection change the window
/// asks `inspect.measure` with the picked items and appends the key value, as Fusion's
/// "1 Face | Area 20.2 cm²" and two faces' angle. One or two items only (the engine's limit).
@MainActor
enum SelectionMeasure {
    /// The selection as `inspect.measure` items: faces and edges by body and point (the engine
    /// finds the item under the point), else whole bodies. Nil for nothing or more than two.
    static func items(_ m: DesignModel) -> [[String: Any]]? {
        var out: [[String: Any]] = []
        for p in m.selection {
            guard p.mesh < m.scene.meshes.count else { continue }
            out.append(["type": p.isFace ? "face" : "edge", "body": m.scene.meshes[p.mesh].body, "point": p.points])
        }
        if out.isEmpty { out = m.selectedBodies.sorted().map { ["type": "body", "name": $0] } }
        return (1...2).contains(out.count) ? out : nil
    }

    /// Runs the measure without touching the document or the undo history. Nil on failure.
    static func query(_ m: DesignModel) -> [String: Any]? {
        guard let items = items(m) else { return nil }
        return (try? m.engine.execute("inspect.measure", ["items": items])) as? [String: Any]
    }

    /// The status text for a measure result: the key value of one item, or the distance and the
    /// angle between two. Nil when the result has nothing worth showing.
    static func text(_ r: [String: Any]) -> String? {
        let items = r["items"] as? [[String: Any]] ?? []
        var parts: [String] = []
        if items.count == 2 {
            if let d = r["distance_mm"] as? Double { parts.append(String(localized: "Distance \(VFFormat.length(d))")) }
            if let a = r["angle_deg"] as? Double { parts.append(String(localized: "Angle \(VFFormat.angle(a))")) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        guard let one = items.first else { return nil }
        switch one["type"] as? String {
        case "face":
            if let a = one["area_mm2"] as? Double { parts.append(String(localized: "Area \(VFFormat.area(a))")) }
            if let d = r["diameter"] as? Double { parts.append(String(localized: "Diameter \(VFFormat.length(d))")) }
        case "edge":
            if let d = r["diameter"] as? Double { parts.append(String(localized: "Diameter \(VFFormat.length(d))")) }
            if let l = one["length_mm"] as? Double { parts.append(String(localized: "Length \(VFFormat.length(l))")) }
            if let a = r["angle_deg"] as? Double { parts.append(String(localized: "Angle \(VFFormat.angle(a))")) }
        case "body":
            if let v = one["volume_mm3"] as? Double { parts.append(String(localized: "Volume \(VFFormat.volume(v))")) }
        default:
            if let l = one["length_mm"] as? Double { parts.append(String(localized: "Length \(VFFormat.length(l))")) }
            if let a = one["area_mm2"] as? Double { parts.append(String(localized: "Area \(VFFormat.area(a))")) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The count prefix, "1 Face", "2 Faces", "1 Edge, 1 Face", "1 Body".
    static func countLabel(_ m: DesignModel) -> String {
        let f = m.selection.filter(\.isFace).count, e = m.selection.filter(\.isEdge).count
        var parts: [String] = []
        if f > 0 { parts.append(f == 1 ? String(localized: "1 Face") : String(localized: "\(f) Faces")) }
        if e > 0 { parts.append(e == 1 ? String(localized: "1 Edge") : String(localized: "\(e) Edges")) }
        if parts.isEmpty, !m.selectedBodies.isEmpty {
            let b = m.selectedBodies.count
            parts.append(b == 1 ? String(localized: "1 Body") : String(localized: "\(b) Bodies"))
        }
        return parts.joined(separator: ", ")
    }

    /// The full status segment: "1 Face | Area 20.2 cm²". Nil when nothing measurable is picked.
    static func status(_ m: DesignModel) -> String? {
        guard let r = query(m), let t = text(r) else { return nil }
        return "\(countLabel(m)) | \(t)"
    }
}
#endif
