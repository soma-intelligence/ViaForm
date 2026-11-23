import SwiftUI

/// iPad layout (apple/Touch): status bar, top bar with hamburger, title, the same segmented
/// control, undo and redo, Items and History toggles. Labelled tool panel on the left,
/// suggestion capsule at the selection (60 pt items), 44 pt touch targets throughout.
struct IPadScreen: View {
    @Bindable var studio: Studio

    var body: some View {
        GeometryReader { geo in
            let cs = ConceptSpace(size: geo.size)
            ZStack(alignment: .topLeading) {
                ViewportBackground()
                ModelImage(name: "hand_ipad", rect: cs.rect(465, 92, 1090, 960))

                // face drag handle + value bubble at the selected thumb face
                FaceHandle().position(cs.p(1032, 476))
                ValueBubble(text: "12.0 mm").position(cs.p(1102, 431))

                AnchorLayout(anchor: cs.p(1046, 660), side: .below, gap: 0, insets: EdgeInsets(top: 100, leading: 200, bottom: 20, trailing: 20)) {
                    ContextCapsule(actions: [
                        .init(id: "extrude", glyph: "cube", title: "Extrude", primary: true),
                        .init(id: "offset", glyph: "square.3.layers.3d", title: "Offset"),
                        .init(id: "sketch", glyph: "pencil", title: "Sketch on face"),
                        .init(id: "fillet", glyph: "vf.fillet", title: "Fillet")
                    ], style: .tall)
                }

                VStack(alignment: .leading, spacing: 10) {
                    PadToolGroup(tools: [("line.diagonal", "Line"), ("vf.arc", "Arc"), ("rectangle", "Rectangle"), ("circle", "Circle")])
                    PadToolGroup(tools: [("cube", "Extrude"), ("vf.fillet", "Fillet"), ("vf.chamfer", "Chamfer"),
                                         ("arrow.up.and.down.and.arrow.left.and.right", "Move"), ("link", "Joint")])
                }
                .padding(.leading, 20).padding(.top, 156)

                HStack { Spacer(); ViewCube(size: 78) }.padding(.top, 112).padding(.trailing, 22)

                if studio.padItems {
                    HStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Items").font(.system(size: 17, weight: .semibold)).foregroundStyle(VF.text)
                                .padding(.leading, 8).padding(.vertical, 8)
                            ForEach(Sample.padItems) { n in
                                TreeRow(node: n, selected: n.id == "thumb", device: .pad, showLock: true)
                            }
                        }
                        .padding(10)
                        .frame(width: 300)
                        .card()
                    }
                    .padding(.top, 216).padding(.trailing, 18)
                }

                VStack(spacing: 0) {
                    StatusBar()
                    PadTopBar(studio: studio).padding(.horizontal, 18).padding(.top, 6)
                }
            }
        }
    }
}

struct StatusBar: View {
    var body: some View {
        HStack {
            Text("9:41").font(.system(size: 15, weight: .semibold))
            Spacer()
            Image(systemName: "wifi").font(.system(size: 14, weight: .semibold))
            Text("100%").font(.system(size: 14, weight: .medium)).monospacedDigit()
            Image(systemName: "battery.100").font(.system(size: 18))
        }
        .foregroundStyle(VF.text)
        .padding(.horizontal, 24).frame(height: 30)
    }
}

struct PadTopBar: View {
    @Bindable var studio: Studio
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal").font(.system(size: 19)).frame(width: 44, height: 44)
            Rectangle().fill(VF.divider).frame(width: 1, height: 28).padding(.horizontal, 12)
            Text("Robotic Hand v3").font(.system(size: 17, weight: .medium)).lineLimit(1).fixedSize()
            Spacer(minLength: 16)
            PillSegments(items: Workspace.allCases.map { ($0, $0.rawValue) }, selection: $studio.workspace, height: 42, font: 14)
            Spacer(minLength: 16)
            Image(systemName: "arrow.uturn.backward").font(.system(size: 17)).frame(width: 44, height: 44)
            Image(systemName: "arrow.uturn.forward").font(.system(size: 17)).foregroundStyle(VF.text.opacity(0.4)).frame(width: 44, height: 44)
            HStack(spacing: 6) {
                toggle("Items", on: studio.padItems) { studio.padItems.toggle() }
                toggle("History", on: studio.padHistory) { studio.padHistory.toggle() }
            }
            .padding(.leading, 12)
        }
        .foregroundStyle(VF.text)
        .padding(.horizontal, 10)
        .frame(height: 56)
        .card(16)
    }
    func toggle(_ t: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 15, weight: .medium))
                .foregroundStyle(on ? VF.accent : VF.text)
                .padding(.horizontal, 16).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(on ? VF.accentSoft : VF.track))
        }
        .buttonStyle(.plain)
    }
}

struct PadToolGroup: View {
    let tools: [(String, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tools, id: \.1) { t in
                HStack(spacing: 14) {
                    Glyph(name: t.0, size: 22, weight: .light)
                        .frame(width: 46, height: 46)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(VF.hairline))
                        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                    Text(t.1).font(.system(size: 15))
                }
                .foregroundStyle(VF.text)
                .frame(width: 150, height: 52, alignment: .leading)
            }
        }
        .padding(10)
        .card()
    }
}

struct FaceHandle: View {
    var body: some View {
        ZStack {
            Circle().fill(VF.accent).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                .shadow(color: VF.accent.opacity(0.5), radius: 6)
        }
        .frame(width: 44, height: 44) // touch target
    }
}

/// Tap to type. In the app this opens a numeric field that accepts arithmetic.
struct ValueBubble: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(VF.accent))
            .shadow(color: VF.accent.opacity(0.35), radius: 6, y: 2)
            .frame(minHeight: 44)
    }
}
