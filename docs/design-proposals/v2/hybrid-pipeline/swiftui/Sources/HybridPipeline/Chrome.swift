import SwiftUI

// MARK: - Pipeline bar (toolbar .principal)

typealias PipelineStates = [Workspace: StageStatus]

struct PipelineBar: View {
    let active: Workspace
    let states: PipelineStates
    var onSelect: (Workspace) -> Void = { _ in }
    var onUpdate: (Workspace) -> Void = { _ in }

    enum Labels { case all, activeOnly, none }

    var body: some View {
        // Full chips, then icon-only chips with the active one labelled
        // (the iPad pattern), then a single menu below about 1440 pt.
        ViewThatFits(in: .horizontal) {
            strip(.all)
            strip(.activeOnly)
            strip(.none)
            PipelineMenuButton(active: active, states: states, onSelect: onSelect)
        }
    }

    private func strip(_ labels: Labels) -> some View {
        HStack(spacing: 3) {
            ForEach(Workspace.allCases) { ws in
                if ws != .design {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(VF.tertiary)
                }
                StageChip(stage: ws,
                          status: states[ws] ?? .idle,
                          isActive: ws == active,
                          showsLabel: labels == .all || (labels == .activeOnly && ws == active),
                          onSelect: { onSelect(ws) },
                          onUpdate: { onUpdate(ws) })
            }
        }
        .fixedSize()
    }
}

struct StageChip: View {
    let stage: Workspace
    let status: StageStatus
    let isActive: Bool
    let showsLabel: Bool
    var onSelect: () -> Void = {}
    var onUpdate: () -> Void = {}
    @State private var offerUpdate = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Image(systemName: stage.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 14)
                if showsLabel {
                    Text(stage.title).font(.system(size: 12, weight: isActive ? .semibold : .regular))
                }
                dot
            }
            .foregroundStyle(isActive ? Color.white : VF.text.opacity(0.88))
            .padding(.horizontal, showsLabel ? 9 : 7)
            .frame(height: 28)
            .background(Capsule().fill(isActive ? VF.accent : VF.panel))
            .overlay(Capsule().strokeBorder(isActive ? Color.white.opacity(0.18) : VF.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(stage.shortcut, modifiers: .command)
        .help("\(stage.title) (Cmd+\(stage.rawValue + 1)) : \(status.word)")
    }

    @ViewBuilder private var dot: some View {
        let d = StatusDot(status: isActive && status == .upToDate ? .upToDate : status, size: 6)
            .overlay(isActive ? Circle().stroke(Color.white.opacity(0.7), lineWidth: 1).frame(width: 8, height: 8) : nil)
        if status == .stale {
            Button { offerUpdate = true } label: { d.padding(3) }
                .buttonStyle(.plain)
                .popover(isPresented: $offerUpdate) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(stage.title) is stale").font(.vfRowSemibold)
                        Text("An upstream stage changed.").font(.vfSmall).foregroundStyle(.secondary)
                        Button("Update") { onUpdate(); offerUpdate = false }.keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                }
        } else {
            d
        }
    }
}

/// Last fallback of the pipeline bar: one capsule that opens a Menu in the
/// live app. Drawn as a plain capsule so ImageRenderer can show it too.
struct PipelineMenuButton: View {
    let active: Workspace
    let states: PipelineStates
    var onSelect: (Workspace) -> Void
    var body: some View {
        let stale = states.values.filter { $0 == .stale || $0 == .failed }.count
        HStack(spacing: 6) {
            Image(systemName: active.symbol).font(.system(size: 12))
            Text(active.title).font(.system(size: 12, weight: .semibold))
            if stale > 0 {
                Text("\(stale)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 5).frame(height: 15)
                    .background(Capsule().fill(VF.amber)).foregroundStyle(.black)
            }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 28)
        .background(Capsule().fill(VF.accent))
    }
}

// MARK: - Unified toolbar (drawn for headless renders)

struct TitleBar: View {
    let title: String
    let active: Workspace
    let states: PipelineStates
    var jobs: Int = 3

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: 0xFF5F57)).frame(width: 12, height: 12)
                Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 12, height: 12)
                Circle().fill(Color(hex: 0x28C840)).frame(width: 12, height: 12)
            }
            .padding(.leading, 14)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                .padding(.leading, 20).padding(.trailing, 16)
            Spacer(minLength: 0)
            PipelineBar(active: active, states: states)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                JobsButton(count: jobs)
                ToolbarPill(symbol: "square.and.arrow.up", title: "Share")
                ToolbarPill(symbol: "sidebar.right", title: "Inspector")
            }
            .fixedSize()
            .padding(.trailing, 10)
        }
        .frame(height: 44)
        .background(VF.chrome)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

struct JobsButton: View {
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 12))
            Text("Jobs").font(.system(size: 12))
            Text("\(count)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                .frame(minWidth: 16, minHeight: 16)
                .background(Circle().fill(VF.accent))
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(VF.panel))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(VF.hairline))
    }
}

struct ToolbarPill: View {
    let symbol: String
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12))
            Text(title).font(.system(size: 12))
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(VF.panel))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(VF.hairline))
    }
}

// MARK: - Ribbon

enum ToolGlyph {
    case png(String)
    case symbol(String, Color? = nil)
}

struct RibbonTool: Identifiable {
    let id = UUID()
    let glyph: ToolGlyph
    var caption: String? = nil
    var isOn = false
}

struct RibbonGroupModel: Identifiable {
    let id = UUID()
    let title: String
    let tools: [RibbonTool]
}

enum PrimaryKind { case green, blue, neutral }

struct PrimaryAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let kind: PrimaryKind
    var stacked = false
}

struct ToolIcon: View {
    let glyph: ToolGlyph
    var size: CGFloat = 28
    var body: some View {
        switch glyph {
        case .png(let name):
            Art.tool(name).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .shadow(color: .white.opacity(0.10), radius: 0.5)
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: size * 0.66, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(
                    LinearGradient(colors: [Color(white: 0.96), Color(white: 0.62)], startPoint: .top, endPoint: .bottom)))
                .frame(width: size, height: size)
        }
    }
}

struct RibbonGroup: View {
    let model: RibbonGroupModel
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(model.tools) { tool in
                    VStack(spacing: 3) {
                        ToolIcon(glyph: tool.glyph, size: tool.caption == nil ? 28 : 22)
                        if let c = tool.caption {
                            Text(c).font(.system(size: 10.5)).foregroundStyle(VF.text.opacity(0.85)).lineLimit(1)
                        }
                    }
                    .frame(minWidth: tool.caption == nil ? 38 : 46, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tool.isOn ? VF.accent.opacity(0.22) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tool.isOn ? VF.accent.opacity(0.6) : .clear))
                }
            }
            HStack(spacing: 4) {
                CapsLabel(text: model.title, size: 10)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(VF.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(VF.panel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(VF.hairline, lineWidth: 1))
    }
}

struct PrimaryButton: View {
    let action: PrimaryAction
    var body: some View {
        let fill: Color = switch action.kind {
        case .green: VF.green
        case .blue: VF.accent
        case .neutral: VF.panel
        }
        Group {
            if action.stacked {
                VStack(spacing: 5) {
                    Image(systemName: action.symbol).font(.system(size: 16, weight: .bold))
                    Text(action.title).font(.system(size: 12, weight: .semibold))
                }
                .frame(width: 84, height: 60)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: action.symbol).font(.system(size: 14, weight: .bold))
                    Text(action.title).font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 26)
                .frame(minWidth: 150, minHeight: 42)
            }
        }
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(action.kind == .neutral ? 0.12 : 0.18)))
        .shadow(color: fill.opacity(action.kind == .neutral ? 0 : 0.35), radius: 8, y: 2)
    }
}

/// Segmented control drawn in SwiftUI (Picker(.segmented) is AppKit backed and
/// does not render headless). Used for Schematic / PCB / 3D and Grid / Plot.
struct VFSegmented: View {
    let items: [String]
    let selected: Int
    var height: CGFloat = 26
    var fontSize: CGFloat = 12
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Text(item).font(.system(size: fontSize, weight: i == selected ? .semibold : .regular))
                    .foregroundStyle(i == selected ? .white : VF.secondary)
                    .padding(.horizontal, 12).frame(height: height - 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(i == selected ? VF.accent : .clear))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(VF.well))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VF.hairline))
    }
}

struct Ribbon<Trailing: View>: View {
    let groups: [RibbonGroupModel]
    let primary: [PrimaryAction]
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            ForEach(groups) { RibbonGroup(model: $0) }
            Spacer(minLength: 6)
            trailing
            ForEach(primary) { PrimaryButton(action: $0) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(height: 78)
        .background(VF.chrome)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    let leading: AnyView
    let trailing: [String]
    var trailingDot: (String, StageStatus)? = nil

    var body: some View {
        HStack(spacing: 14) {
            leading
            Spacer()
            if let (t, s) = trailingDot {
                HStack(spacing: 6) { StatusDot(status: s, size: 7); Text(t) }
            }
            ForEach(trailing, id: \.self) { Text($0).monospacedDigit() }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(VF.text.opacity(0.82))
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(VF.chrome)
        .overlay(alignment: .top) { Hairline() }
    }
}
