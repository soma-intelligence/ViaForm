#if os(macOS)
import SwiftUI

/// The compact layout of the Mac project window (VIAFORM-SPEC 6.1, UI-UX-AUDIT P2-7): on a 13 inch
/// screen, or a window tiled to half of one, the ribbon folds its last groups into MORE, the
/// inspector floats over the viewport instead of taking a column, and the browser sidebar
/// collapses. Every width the window reacts to lives here.
enum CompactLayout {
    /// The smallest window: half of a 13 inch screen, tiled.
    static let minWindow = CGSize(width: 760, height: 560)
    /// Under this window width the inspector is an overlay over the viewport.
    static let inspectorOverlayBelow: CGFloat = 1100
    /// Under this window width the browser sidebar collapses (the reader may still open it).
    static let sidebarCollapseBelow: CGFloat = 900
    /// Commands a verb group shows in the ribbon before the rest go to MORE.
    static let verbsPerGroup = 6

    static func inspectorOverlays(windowWidth w: CGFloat) -> Bool { w < inspectorOverlayBelow }
    static func sidebarCollapses(windowWidth w: CGFloat) -> Bool { w < sidebarCollapseBelow }

    /// The width of the floating inspector: its column width, never wider than the space left.
    static func overlayWidth(ideal: CGFloat, detailWidth: CGFloat) -> CGFloat {
        max(VFSize.inspectorMin, min(ideal, detailWidth - 2 * VFSpace.xxl))
    }
}

/// Folds the ribbon's lowest priority groups (the last ones) into MORE. A pure function so the
/// self test can prove that every command stays reachable, either in the strip or in MORE.
enum RibbonFold {
    struct Group<C>: Identifiable {
        let name: String
        let commands: [C]
        var id: String { name }
    }

    struct Result<C> {
        /// The groups the ribbon shows, each capped at `perGroup` commands.
        var strip: [Group<C>]
        /// The commands that did not fit: each shown group's overflow, then the folded groups.
        var more: [Group<C>]
    }

    static func fold<C>(_ groups: [Group<C>], visible: Int, perGroup: Int = .max) -> Result<C> {
        let k = max(0, min(visible, groups.count))
        let cap = max(1, perGroup)
        var strip: [Group<C>] = []
        var more: [Group<C>] = []
        for g in groups.prefix(k) {
            strip.append(Group(name: g.name, commands: Array(g.commands.prefix(cap))))
            if g.commands.count > cap { more.append(Group(name: g.name, commands: Array(g.commands.dropFirst(cap)))) }
        }
        more += groups.dropFirst(k)
        return Result(strip: strip, more: more)
    }

    struct Step: Hashable { let visible: Int; let labels: Bool }

    /// A ribbon's layouts from widest to narrowest, for `ViewThatFits`: every group labelled,
    /// then as icons, then one group less each time (labelled first), down to MORE alone.
    static func steps(_ n: Int) -> [Step] {
        guard n > 0 else { return [Step(visible: 0, labels: true)] }
        return (1...n).reversed().flatMap { [Step(visible: $0, labels: true), Step(visible: $0, labels: false)] }
            + [Step(visible: 0, labels: true)]
    }

    /// Every command of `groups` is in the strip or in MORE, exactly once, in its group's order.
    static func keepsEvery<C: Equatable>(_ groups: [Group<C>], _ r: Result<C>) -> Bool {
        groups.allSatisfy { g in
            let shown = r.strip.filter { $0.name == g.name }.flatMap(\.commands)
            let folded = r.more.filter { $0.name == g.name }.flatMap(\.commands)
            return shown + folded == g.commands
        } && r.strip.count + r.more.count >= groups.filter { !$0.commands.isEmpty }.count
            && (r.strip + r.more).flatMap(\.commands).count == groups.flatMap(\.commands).count
    }
}

/// When the window narrows past `sidebarCollapseBelow` the sidebar collapses; when it widens
/// again it comes back, but only if the window collapsed it. A choice the reader makes at the
/// current width (opening it in a narrow window, hiding it in a wide one) is never undone while
/// the width stays on that side of the threshold.
struct SidebarAutoCollapse: Equatable {
    private var narrow: Bool?
    private(set) var autoCollapsed = false

    /// The sidebar visibility to apply after a width change, or nil to leave it as it is.
    mutating func width(_ w: CGFloat, shown: Bool) -> Bool? {
        let n = CompactLayout.sidebarCollapses(windowWidth: w)
        guard n != narrow else { return nil }
        narrow = n
        if n {
            guard shown else { return nil }
            autoCollapsed = true
            return false
        }
        guard autoCollapsed else { return nil }
        autoCollapsed = false
        return shown ? nil : true
    }

    /// The reader showed or hid the sidebar: theirs from now on.
    mutating func userChose() { autoCollapsed = false }
}

/// The ribbon commands that did not fit, with the same labels and enabled state; a disabled
/// command says why on a second line.
struct VerbMoreMenu: View {
    @Environment(\.viaFormTheme) private var theme
    let groups: [RibbonFold.Group<FlowModel.Command>]
    let actions: StageActions

    var body: some View {
        Menu {
            ForEach(groups) { g in
                Section(StageLabels.panel(g.name)) {
                    ForEach(g.commands) { c in
                        let reason = actions.unavailableReason(c.id)
                        Button { actions.run(c.id) } label: {
                            Label(StageLabels.command(c.label), systemImage: StageLabels.symbol(forVerb: c.icon))
                            if let reason { Text(reason) }
                        }
                        .disabled(!actions.canRun(c.id))
                    }
                }
            }
        } label: {
            HStack(spacing: VFSpace.xs) {
                Label("More", systemImage: "ellipsis.circle")
                Image(systemName: "chevron.down").font(VFFont.glyph(7, weight: .bold)).foregroundStyle(theme.inkSecondary)
            }
            .font(VFFont.small)
            .frame(height: 26)
        }
        .menuStyle(.vfPlain)
        .padding(.horizontal, VFSpace.xs)
        .frame(height: 30)
        .vfSurface(.well)
        .help(String(localized: "More commands: \(groups.map { StageLabels.panel($0.name) }.joined(separator: ", "))"))
        .accessibilityLabel("More Commands")
    }
}

/// Self test of the compact layout (P2-7): the fold keeps every command, the thresholds are in
/// order and the sidebar respects the reader's choice.
enum CompactLayoutSelfTest {
    static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let groups: [RibbonFold.Group<String>] = [
            .init(name: "A", commands: (1...8).map { "a\($0)" }),
            .init(name: "B", commands: ["b1", "b2"]),
            .init(name: "C", commands: []),
            .init(name: "D", commands: (1...3).map { "d\($0)" }),
        ]
        var all = true
        for k in 0...(groups.count + 1) {
            for cap in [1, 2, 6, Int.max] {
                let r = RibbonFold.fold(groups, visible: k, perGroup: cap)
                all = all && RibbonFold.keepsEvery(groups, r) && r.strip.allSatisfy { $0.commands.count <= cap }
            }
        }
        out.append((all, "P2-7 the ribbon fold keeps every command, in the strip or in More"))
        let r = RibbonFold.fold(groups, visible: 2, perGroup: 6)
        out.append((r.strip.map(\.name) == ["A", "B"] && r.more.map(\.name) == ["A", "C", "D"],
                    "P2-7 the last groups fold first, a long group's overflow goes to More"))
        out.append((CompactLayout.sidebarCollapseBelow < CompactLayout.inspectorOverlayBelow
                    && CompactLayout.minWindow.width < CompactLayout.sidebarCollapseBelow,
                    "P2-7 compact thresholds: minimum 760 < sidebar 900 < inspector 1100"))
        // The Assemble ribbon folds with the same steps: every tab keeps every command at every
        // width, the narrowest step is MORE alone, and each command keeps its words.
        var asmKept = true, asmWords = true, asmNarrowest = true
        for tab in AssembleModel.Tab.allCases {
            let g = AssembleRibbon.groups(tab)
            let steps = RibbonFold.steps(g.count)
            for step in steps {
                asmKept = asmKept && RibbonFold.keepsEvery(g, RibbonFold.fold(g, visible: step.visible))
            }
            let last = RibbonFold.fold(g, visible: steps.last?.visible ?? 0)
            asmNarrowest = asmNarrowest && last.strip.isEmpty && last.more.flatMap(\.commands) == g.flatMap(\.commands)
            asmWords = asmWords && g.flatMap(\.commands).allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty && !$0.help.isEmpty }
                && Set(g.map(\.name)).count == g.count
        }
        out.append((asmKept && asmNarrowest && asmWords,
                    "P2-7 the Assemble ribbon folds into More like the stage ribbon and keeps every command of every tab"))
        let reasons = AssembleRibbon.unavailableReason("dragTip", product: .hand) != nil
            && AssembleRibbon.unavailableReason("grasp", product: .arm) != nil
            && AssembleRibbon.unavailableReason("dragTip", product: .arm) == nil
            && AssembleRibbon.unavailableReason("grasp", product: .hand) == nil
        out.append((reasons, "P2-7 a folded Assemble command keeps its disabled reason (Drag Tip for arms, Grasp for hands)"))
        var s = SidebarAutoCollapse()
        let launchNarrow = s.width(760, shown: true)
        s.userChose()  // the reader opens it again at 760
        let resizeNarrow = s.width(820, shown: true)
        let widen = s.width(1200, shown: true)
        var t = SidebarAutoCollapse()
        _ = t.width(1200, shown: true)
        let narrowed = t.width(800, shown: true)
        let back = t.width(1000, shown: false)
        out.append((launchNarrow == false && resizeNarrow == nil && widen == nil && narrowed == false && back == true,
                    "P2-7 the sidebar collapses under 900 pt, comes back on widening, and keeps the reader's choice"))
        return out
    }
}
#endif
