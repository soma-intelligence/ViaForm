#if os(macOS)
import CoreGraphics

/// The timeline's tiles once folders are taken in: a feature tile per feature, and a folder
/// tile before each top-level folder's features. A collapsed folder is its one tile; an open
/// one is its tile followed by its features. Every tile is one pitch wide.
struct TimelineLayout {
    enum Slot: Hashable {
        case feature(index: Int)
        case folder(TimelineFolder, range: ClosedRange<Int>, collapsed: Bool)

        var key: AnyHashable {
            switch self {
            case let .feature(i): AnyHashable(i)
            case let .folder(f, _, _): AnyHashable("folder-\(f.id)")
            }
        }
    }

    private(set) var slots: [Slot] = []
    /// Index of a feature's tile (a collapsed folder's tile for the features inside it).
    private(set) var slotOf: [Int: Int] = [:]

    init(features: [DesignSnapshot.Feature], folders: [TimelineFolder], collapsed: Set<Int>) {
        let index = Dictionary(uniqueKeysWithValues: features.enumerated().map { ($1.id, $0) })
        // Only top-level folders draw a tile; nested ones count as part of their parent.
        var start: [Int: (TimelineFolder, ClosedRange<Int>)] = [:]
        for f in folders where f.parent == nil || !folders.contains(where: { $0.id == f.parent }) {
            let at = f.features.compactMap { index[$0] }
            guard let lo = at.min(), let hi = at.max() else { continue }
            start[lo] = (f, lo...hi)
        }
        var i = 0
        while i < features.count {
            if let (f, range) = start[i] {
                let shut = collapsed.contains(f.id)
                slots.append(.folder(f, range: range, collapsed: shut))
                if shut {
                    for j in range { slotOf[j] = slots.count - 1 }
                    i = range.upperBound + 1
                    continue
                }
            }
            slots.append(.feature(index: i))
            slotOf[i] = slots.count - 1
            i += 1
        }
    }

    /// Where the history marker sits, `marker` features built, in tile pitches.
    func markerX(_ marker: Int, pitch: CGFloat) -> CGFloat {
        guard marker > 0, let k = slotOf[marker - 1] else { return 0 }
        if case let .folder(_, range, true) = slots[k], marker - 1 < range.upperBound {
            return (CGFloat(k) + 0.5) * pitch
        }
        return CGFloat(k + 1) * pitch
    }

    /// The marker position nearest a dropped playhead.
    func marker(at x: CGFloat, pitch: CGFloat) -> Int {
        var stops: [(CGFloat, Int)] = [(0, 0)]
        for (k, s) in slots.enumerated() {
            switch s {
            case let .feature(i): stops.append((CGFloat(k + 1) * pitch, i + 1))
            case let .folder(_, range, collapsed):
                stops.append(collapsed ? (CGFloat(k + 1) * pitch, range.upperBound + 1) : (CGFloat(k + 1) * pitch, range.lowerBound))
            }
        }
        return stops.min { abs($0.0 - x) < abs($1.0 - x) }?.1 ?? 0
    }

    /// The tile to scroll to so the marker stays in view.
    func scrollKey(marker: Int, count: Int) -> AnyHashable {
        if marker >= count { return "end" }
        guard let k = slotOf[max(0, marker - 1)] else { return "end" }
        return slots[k].key
    }
}
#endif
