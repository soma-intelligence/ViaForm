import simd
import SwiftUI

// Collapsible inspector sections with a status (VIAFORM-SPEC 7.10.1): each study section folds
// away, remembers whether it was open across launches, and says in a shape and a word whether
// it is complete, missing something the run needs, or holds an error.

/// Where a study section stands.
enum SectionStatus: Equatable {
    case complete
    /// The run needs something here (the reason, in words).
    case missing(String)
    /// A value here cannot run (the reason, in words).
    case error(String)

    var word: String {
        switch self {
        case .complete: String(localized: "Complete")
        case .missing: String(localized: "Missing")
        case .error: String(localized: "Error")
        }
    }

    var symbol: String {
        switch self {
        case .complete: "checkmark.circle.fill"
        case .missing: "exclamationmark.circle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var reason: String? {
        switch self {
        case .complete: nil
        case .missing(let r), .error(let r): r
        }
    }
}

/// The study's sections, top to bottom.
enum StudySection: String, CaseIterable {
    case designSpace, goal, solver, material, limits, symmetry, manufacturing, dynamics
    case supports, loads, keepOut, keepIn
}

extension Study {
    /// The status of one section of the setup.
    func status(_ section: StudySection) -> SectionStatus {
        switch section {
        case .designSpace:
            if voxel <= 0 || !voxel.isFinite { return .error(String(localized: "The voxel size must be above 0 mm.")) }
            if (0..<3).contains(where: { abs(max[$0] - min[$0]) <= 0 }) { return .missing(String(localized: "Give the box a size on every axis.")) }
            if elementCount > 8_000_000 { return .error(String(localized: "Over 8 million voxels: use a larger voxel.")) }
            return .complete
        case .goal:
            if volumeFraction <= 0 || volumeFraction >= 1 { return .error(String(localized: "The volume fraction must be between 0 and 100 %.")) }
            return .complete
        case .solver:
            if let m = massTargetG, m <= 0 { return .error(String(localized: "The target mass must be above 0 g.")) }
            return .complete
        case .material:
            if material.e <= 0 || material.density <= 0 || material.allowable <= 0 {
                return .error(String(localized: "Stiffness, density and allowable stress must all be above 0."))
            }
            if material.nu < 0 || material.nu >= 0.5 { return .error(String(localized: "Poisson's ratio must be from 0 to under 0.5.")) }
            return .complete
        case .limits:
            if safetyFactor < 1 { return .error(String(localized: "The safety factor must be at least 1.")) }
            if let s = maxStress, s <= 0 { return .error(String(localized: "The stress limit must be above 0 MPa.")) }
            if let d = maxDisplacement, d <= 0 { return .error(String(localized: "The displacement limit must be above 0 mm.")) }
            return .complete
        case .symmetry:
            return .complete
        case .manufacturing:
            if manufacturing.process != .free, simd_length(manufacturing.direction) <= 0 {
                return .missing(String(localized: "Pick a direction for the process."))
            }
            return .complete
        case .dynamics:
            if dynamics.impacts.contains(where: { !cases.indices.contains($0.caseIndex) }) {
                return .error(String(localized: "An impact names a load case that no longer exists."))
            }
            return .complete
        case .supports:
            return supports.isEmpty ? .missing(String(localized: "Add a support: the study needs at least one.")) : .complete
        case .loads:
            let loaded = cases.contains { !$0.loads.isEmpty || $0.acceleration != nil }
            return loaded ? .complete : .missing(String(localized: "Add a load or an acceleration to a case."))
        case .keepOut, .keepIn:
            return .complete
        }
    }
}

/// The open or folded sections, kept across launches (one key, the folded ids joined).
enum InspectorFolds {
    static let key = "generate.inspector.folded"

    static func folded(_ raw: String) -> Set<String> { Set(raw.split(separator: ",").map(String.init)) }

    static func toggled(_ raw: String, _ id: String, open: Bool) -> String {
        var s = folded(raw)
        if open { s.remove(id) } else { s.insert(id) }
        return s.sorted().joined(separator: ",")
    }
}

/// A Form section whose body folds under a disclosure triangle. The header row carries the
/// title and the status (shape and word, with the reason in the tooltip and for VoiceOver);
/// open or folded is remembered.
struct InspectorSection<Content: View, Footer: View>: View {
    @Environment(\.viaFormTheme) private var theme
    @AppStorage(InspectorFolds.key) private var foldedRaw = ""
    let id: StudySection
    let title: String
    let status: SectionStatus
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(_ id: StudySection, _ title: String, status: SectionStatus,
         @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.id = id
        self.title = title
        self.status = status
        self.content = content
        self.footer = footer
    }

    private var open: Binding<Bool> {
        Binding(get: { !InspectorFolds.folded(foldedRaw).contains(id.rawValue) },
                set: { foldedRaw = InspectorFolds.toggled(foldedRaw, id.rawValue, open: $0) })
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: open) {
                content()
            } label: {
                HStack(spacing: VFSpace.m) {
                    Text(title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                    Spacer(minLength: VFSpace.s)
                    SectionStatusLabel(status: status)
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(status.reason.map { "\(status.word). \($0)" } ?? status.word))
            }
        } footer: {
            if open.wrappedValue { footer() }
        }
    }
}

extension InspectorSection where Footer == EmptyView {
    init(_ id: StudySection, _ title: String, status: SectionStatus, @ViewBuilder content: @escaping () -> Content) {
        self.init(id, title, status: status, content: content, footer: { EmptyView() })
    }
}

/// A section's status as a shape and a word, never the colour alone.
struct SectionStatusLabel: View {
    @Environment(\.viaFormTheme) private var theme
    let status: SectionStatus

    var body: some View {
        let tint: Color = switch status {
        case .complete: theme.success
        case .missing: theme.warning
        case .error: theme.danger
        }
        Label(status.word, systemImage: status.symbol)
            .labelStyle(.titleAndIcon)
            .font(VFFont.micro)
            .lineLimit(1)
            .foregroundStyle(tint)
            .fixedSize()
            .help(status.reason ?? String(localized: "Nothing missing here"))
    }
}
