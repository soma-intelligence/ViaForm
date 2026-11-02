import Foundation

/// What `document.inspect` reports: the browser, the timeline and the parameters read it.
struct DesignSnapshot: Decodable {
    struct Body: Decodable, Identifiable, Hashable {
        var name: String
        var volume_mm3: Double?
        var faces: Int?
        var edges: Int?
        var material: String?
        var visible: Bool?
        var id: String { name }
    }

    struct Sketch: Decodable, Identifiable, Hashable {
        var id: Int
        var name: String
        var curves: Int?
        var profiles: Int?
        var status: String?
        var visible: Bool?
    }

    struct Feature: Decodable, Identifiable, Hashable {
        var id: Int
        var name: String
        var type: String
        var error: String?
        var warning: String?
        var suppressed: Bool?
        var rolled_back: Bool?
    }

    struct Parameter: Decodable, Identifiable, Hashable {
        var name: String
        var expression: String
        var unit: String?
        var value: Double?
        var error: String?
        var id: String { name }
    }

    var name = "Untitled"
    var path: String?
    var dirty = false
    var units = "mm"
    var undo = 0
    var redo = 0
    var marker = 0
    var revision = 0
    var active_sketch: Int?
    var bodies: [Body] = []
    var sketches: [Sketch] = []
    var timeline: [Feature] = []
    var params: [Parameter] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case name, path, dirty, units, undo, redo, marker, revision, active_sketch, bodies, sketches, timeline, params
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        path = try? c.decode(String.self, forKey: .path)
        dirty = (try? c.decode(Bool.self, forKey: .dirty)) ?? false
        units = (try? c.decode(String.self, forKey: .units)) ?? "mm"
        undo = (try? c.decode(Int.self, forKey: .undo)) ?? 0
        redo = (try? c.decode(Int.self, forKey: .redo)) ?? 0
        marker = (try? c.decode(Int.self, forKey: .marker)) ?? 0
        revision = (try? c.decode(Int.self, forKey: .revision)) ?? 0
        active_sketch = try? c.decode(Int.self, forKey: .active_sketch)
        bodies = (try? c.decode([Body].self, forKey: .bodies)) ?? []
        sketches = (try? c.decode([Sketch].self, forKey: .sketches)) ?? []
        timeline = (try? c.decode([Feature].self, forKey: .timeline)) ?? []
        params = (try? c.decode([Parameter].self, forKey: .params)) ?? []
    }
}
