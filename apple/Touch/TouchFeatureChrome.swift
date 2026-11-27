#if os(iOS)
import SwiftUI

// The running tool's chrome on the canvas (T-9, T-10): the white value chip on the handle with
// its result menu, and the mode pill under the title ("Extrude", "One Side", a chevron).

/// The value chip at the handle: tap to type the value; the small icon beside it picks the
/// result (New Body, Join, Cut, Intersect) for Extrude and Revolve. Placed by the canvas layer
/// at the handle's tip.
struct TouchValueChip: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    @State private var typing = false
    @State private var focused = false

    var body: some View {
        let _ = units
        let session = FeatureSession.of(model)
        if let v = session.tool.value {
            HStack(spacing: VFSpace.xs) {
                if typing {
                    NumberField(v.label, value: Binding(get: { session.value }, set: { session.value = $0 }),
                                unit: VFUnit(symbol: v.unit), step: v.unit == "deg" ? 15 : 1, width: 70, onCommit: { typing = false })
                        .labelHiddenVisually()
                        .focusBinding($focused)
                        .onAppear { focused = true }
                        .onChange(of: focused) { _, f in if !f { typing = false } }
                } else {
                    Button { typing = true } label: {
                        Text(VFFormat.value(session.value, VFUnit(symbol: v.unit)))
                            .font(VFFont.rowEmphasis).monospacedDigit()
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, VFSpace.m)
                            .frame(minWidth: VFSize.touchTarget, minHeight: VFSize.touchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "\(v.label) \(VFFormat.value(session.value, VFUnit(symbol: v.unit)))"))
                    .accessibilityHint(Text("Type a value"))
                }
                if session.tool == .extrude || session.tool == .revolve {
                    resultMenu(session)
                }
            }
            .padding(.horizontal, VFSpace.xs)
            .background(Capsule().fill(theme.panel))
            .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
            .fixedSize()
            .modifier(FeatureSessionSync(model: model))
        }
    }

    private func resultMenu(_ session: FeatureSession) -> some View {
        let ops = session.editing != nil ? ["new_body", "join", "cut", "intersect"] : ["auto", "new_body", "join", "cut", "intersect"]
        return Menu {
            ForEach(ops, id: \.self) { op in
                Button {
                    session.operation = op
                } label: {
                    Label(FeatureDialogFields.operationTitle(op), systemImage: Self.symbol(op))
                }
            }
        } label: {
            Image(systemName: Self.symbol(session.operation))
                .font(VFFont.glyph(15, weight: .semibold))
                .foregroundStyle(session.operation == "cut" ? theme.danger : theme.accentText)
                .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "Result: \(FeatureDialogFields.operationTitle(session.operation))"))
    }

    static func symbol(_ op: String) -> String {
        switch op {
        case "new_body": "plus.square.on.square"
        case "join": "square.on.square"
        case "cut": "minus.square"
        case "intersect": "square.on.square.intersection.dashed"
        default: "wand.and.stars"
        }
    }
}

/// The tool and its mode, top centre of the canvas while a tool runs: "Extrude", then the
/// mode ("One Side") with a chevron listing the others. Modes are engine variants (another
/// rectangle command, line or arc, fillet or chamfer, the extrude direction).
struct TouchToolModePill: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    /// Inside a card or the iPhone bar: no capsule of its own.
    var compact = false

    var body: some View {
        let modes = Self.modes(model)
        // "Line" under "Line" says nothing: the mode shows only when it adds a word.
        let current = modes.count > 1 ? modes.first(where: \.on)?.title.nilIfSame(as: FeatureSession.of(model).tool.touchLabel) : nil
        if model.tool != .select {
            // The iPad design screen shows the pill alone (the reference has no hint line); the
            // card and the iPhone bar show the prompt beside their own pill.
            if compact { pill(modes, current) } else { plainPill(modes, current) }
        }
    }

    /// "Line/Arc ⌄", "Extrude - One Side ⌄": the tool and its mode in small words on a white
    /// pill under the title pill; a tap lists the modes.
    private func plainPill(_ modes: [ToolMode], _ current: String?) -> some View {
        let tool = FeatureSession.of(model).tool
        let family = TouchColumnLayout.family(of: tool)
        // A merged row names itself ("Line/Arc"); a shape family adds its mode ("Rectangle - Center").
        let merged = model.sketchOpen && family.count > 1 && [Tool.line, .polygon, .trim].contains(family[0])
        let text = merged ? TouchColumnLayout.familyTitle(family) : (current.map { "\(tool.touchLabel) - \($0)" } ?? tool.touchLabel)
        return Menu {
            ForEach(modes) { m in
                Button { m.pick() } label: {
                    if m.on { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                }
            }
        } label: {
            HStack(spacing: VFSpace.s) {
                Text(text).font(VFFont.small.weight(.semibold)).lineLimit(1)
                if modes.count > 1 {
                    Image(systemName: "chevron.down").font(VFFont.icon(9, weight: .semibold)).foregroundStyle(theme.inkSecondary)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(theme.ink)
            .padding(.horizontal, VFSpace.l)
            .frame(height: TouchRail.modeHeight)
            .background(Capsule().fill(theme.panel).shadow(color: TouchRailColors(theme: theme).shadow, radius: 3, y: 1))
            .frame(minHeight: VFSize.touchTarget)
            .contentShape(Rectangle())
        }
        .disabled(modes.count < 2)
        .accessibilityLabel(text)
        .accessibilityHint(modes.count > 1 ? Text("Changes the mode") : Text(""))
    }

    /// A sketch tool of a column family (Rectangle, Circle, Tools) offers the family's modes;
    /// every other tool its engine variants.
    static func modes(_ model: DesignModel) -> [ToolMode] {
        let family = TouchColumnLayout.family(of: model.tool)
        guard model.sketchOpen, family.count > 1 else { return ToolModes.modes(model) }
        return family.map { t in
            ToolMode(id: t.rawValue, title: TouchColumnLayout.familyModeName(t) ?? t.touchLabel, on: model.tool == t) {
                TouchColumnLayout.rememberFamilyMode(t)
                if model.tool != t { model.tool = t }
            }
        }
    }

    private func pill(_ modes: [ToolMode], _ current: String?) -> some View {
            Menu {
                ForEach(modes) { m in
                    Button { m.pick() } label: {
                        if m.on { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                    }
                }
            } label: {
                HStack(spacing: VFSpace.s) {
                    Image(systemName: FeatureSession.of(model).tool.symbol).accessibilityHidden(true)
                    Text(FeatureSession.of(model).tool.touchLabel).font(VFFont.title)
                    if let current {
                        Text(current).font(VFFont.row).foregroundStyle(theme.inkSecondary)
                        Image(systemName: "chevron.down").font(VFFont.glyph(11, weight: .semibold)).foregroundStyle(theme.inkSecondary)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(theme.ink)
                .padding(.horizontal, compact ? 0 : VFSpace.l)
                .frame(minHeight: VFSize.touchTarget)
                .background {
                    if !compact { Capsule().fill(theme.panel).shadow(color: .black.opacity(0.12), radius: 6, y: 2) }
                }
                .contentShape(Rectangle())
            }
            .disabled(modes.count < 2)
            .accessibilityLabel(current.map { String(localized: "\(model.tool.touchLabel), \($0)") } ?? model.tool.touchLabel)
            .accessibilityHint(modes.count > 1 ? Text("Changes the mode") : Text(""))
    }
}

private extension String {
    func nilIfSame(as other: String) -> String? { self == other ? nil : self }
}

/// What the armed sketch tool waits for, in touch words. Mirror and the patterns move on with
/// Done (the keyboard's Return); the rest is `model.drawingHint`, or the touch line for tools
/// it leaves silent.
enum TouchSketchHint {
    @MainActor static func text(_ m: DesignModel) -> String? {
        guard m.tool.isSketchTool else { return nil }
        switch m.tool {
        case .sketchMirror:
            return m.sketchOpTarget ? String(localized: "Tap the mirror line") : String(localized: "Pick curves to mirror, then tap Done")
        case .sketchRectPattern:
            return m.sketchOpTarget ? String(localized: "Tap where the next copy goes") : String(localized: "Pick curves to pattern, then tap Done")
        case .sketchCircPattern:
            return m.sketchOpTarget ? String(localized: "Tap the pattern centre") : String(localized: "Pick curves to pattern, then tap Done")
        case .line where m.clicks.isEmpty: return String(localized: "Tap points; double-tap ends")
        case .spline: return String(localized: "Tap fit points; double-tap ends")
        case .offset: return String(localized: "Tap a curve")
        case .sketchFillet: return String(localized: "Tap a corner")
        default: return m.drawingHint
        }
    }
}

/// Done on a running sketch tool (the card, the iPhone bar, Command-Return): the drawing's next
/// step through `model.endChain()` (typed sizes placed, a line chain ended, Mirror and the
/// patterns on to their line or place); with nothing pending, the tool ends.
enum TouchSketchDone {
    /// True when `endChain()` has something to do for the armed tool.
    @MainActor static func pending(_ m: DesignModel) -> Bool {
        if m.tool == .dimension { return true }
        if !m.sizeEntry.isEmpty, !m.sizeFields.isEmpty { return true }
        if m.tool.takesSketchEntities { return !m.sketchOpTarget && m.sketchSelection.contains { $0.kind != .constraint } }
        return !m.clicks.isEmpty
    }

    @MainActor static func run(_ m: DesignModel) {
        if pending(m) { m.endChain() } else { m.tool = .select }
    }
}
#endif

#if os(iOS)
/// The move gizmo over the touch canvas while Move runs (B-13), sized for fingers. The tool
/// card's fields edit the same state; Done applies it.
struct TouchMoveGizmoLayer: View {
    let model: DesignModel

    var body: some View {
        GeometryReader { geo in
            let session = FeatureSession.of(model)
            if model.tool == .move, let g = session.move {
                MoveGizmo(camera: model.camera, size: geo.size,
                          state: Binding(get: { session.move ?? g }, set: { session.move = $0 }), touch: true)
            }
        }
        .modifier(FeatureSessionSync(model: model))
    }
}
#endif
