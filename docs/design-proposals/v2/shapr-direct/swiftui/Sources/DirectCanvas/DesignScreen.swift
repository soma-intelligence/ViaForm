import SwiftUI

/// Mac window: full-bleed viewport, floating title bar, then floating cards per workspace.
struct MacShell<Content: View>: View {
    @Bindable var studio: Studio
    let title: String
    @ViewBuilder var content: (ConceptSpace) -> Content

    var body: some View {
        GeometryReader { geo in
            let cs = ConceptSpace(size: geo.size)
            ZStack(alignment: .topLeading) {
                ViewportBackground()
                content(cs)
                VStack(spacing: 0) {
                    TitleBar(title: title, workspace: $studio.workspace) { studio.palette = true }
                    Spacer()
                }
                .padding(12)
                if studio.palette {
                    CommandPalette(studio: studio)
                }
            }
        }
    }
}

enum Rails {
    static let design: [RailTool] = [
        .init(id: "select", glyph: "cursorarrow", label: "Select"),
        .init(id: "sketch", glyph: "scribble.variable", label: "Sketch", key: "S"),
        .init(id: "plane", glyph: "square.on.square", label: "Plane"),
        .init(id: "extrude", glyph: "cube", label: "Extrude", key: "E"),
        .init(id: "fillet", glyph: "vf.fillet", label: "Fillet", key: "F"),
        .init(id: "move", glyph: "arrow.up.and.down.and.arrow.left.and.right", label: "Move", key: "M"),
        .init(id: "joint", glyph: "link", label: "Joint", key: "J"),
        .init(id: "measure", glyph: "ruler", label: "Measure"),
        .init(id: "section", glyph: "square.split.diagonal.2x2", label: "Section")
    ]
    static let generative: [RailTool] = [
        .init(id: "preserve", glyph: "cube", label: "Preserve"),
        .init(id: "obstacle", glyph: "exclamationmark.triangle", label: "Obstacle"),
        .init(id: "load", glyph: "arrow.down", label: "Load"),
        .init(id: "constraint", glyph: "link", label: "Constraint"),
        .init(id: "objective", glyph: "target", label: "Objective"),
        .init(id: "generate", glyph: "sparkles", label: "Generate"),
        .init(id: "compare", glyph: "square.on.square", label: "Compare")
    ]
    static let simulation: [RailTool] = [
        .init(id: "play", glyph: "play.fill", label: "Run"),
        .init(id: "step", glyph: "forward.end", label: "Step"),
        .init(id: "camera", glyph: "camera", label: "Camera"),
        .init(id: "wind", glyph: "wind", label: "Wind"),
        .init(id: "gates", glyph: "rectangle.dashed", label: "Gates"),
        .init(id: "record", glyph: "circle", label: "Record")
    ]
    static let electronics: [RailTool] = [
        .init(id: "select", glyph: "cursorarrow", label: "Select"),
        .init(id: "route", glyph: "point.topleft.down.to.point.bottomright.curvepath", label: "Route", key: "R"),
        .init(id: "via", glyph: "circle.circle", label: "Via", key: "V"),
        .init(id: "part", glyph: "cpu", label: "Place part"),
        .init(id: "pour", glyph: "drop", label: "Copper pour"),
        .init(id: "measure", glyph: "ruler", label: "Measure"),
        .init(id: "drc", glyph: "checkmark.circle", label: "Design rules")
    ]
    static let mechanics: [RailTool] = [
        .init(id: "select", glyph: "cursorarrow", label: "Select"),
        .init(id: "joint", glyph: "link", label: "Joint", key: "J"),
        .init(id: "motor", glyph: "gearshape", label: "Motor"),
        .init(id: "limits", glyph: "gauge.with.needle", label: "Limits"),
        .init(id: "drive", glyph: "play.fill", label: "Drive"),
        .init(id: "interference", glyph: "square.on.square.dashed", label: "Interference")
    ]
}

struct DesignScreen: View {
    @Bindable var studio: Studio

    var body: some View {
        MacShell(studio: studio, title: "Robotic Hand v3") { cs in
            let handRect = cs.rect(385, 172, 945, 912)
            let phalanx = cs.p(620, 332)
            ZStack(alignment: .topLeading) {
                // soft indigo glow under the selected phalanx (in the app: selection pass in Metal)
                Ellipse().fill(VF.accent.opacity(0.32)).frame(width: 90, height: 130).blur(radius: 22)
                    .position(phalanx)
                ModelImage(name: "hand_design", rect: handRect)

                // Context capsule at the selection anchor, actions depend on the selection type (body)
                AnchorLayout(anchor: cs.p(650, 178), side: .above, gap: 10) {
                    ContextCapsule(actions: [
                        .init(id: "fillet", glyph: "vf.fillet", title: "Fillet"),
                        .init(id: "shell", glyph: "cube.transparent", title: "Shell"),
                        .init(id: "move", glyph: "arrow.up.and.down.and.arrow.left.and.right", title: "Move"),
                        .init(id: "joint", glyph: "link", title: "Joint"),
                        .init(id: "regen", glyph: "arrow.triangle.2.circlepath", title: "Regenerate")
                    ], style: .stacked, stepper: "2.0 mm")
                }

                ToolRail(tools: Rails.design, active: studio.activeTool[.design] ?? "select") { studio.activeTool[.design] = $0 }
                    .padding(.leading, 16).padding(.top, 136)

                RightColumn {
                    ItemsHistoryCard(mode: $studio.sidebar, items: Sample.handItems, history: Sample.handHistory,
                                     selected: studio.sidebar == .items ? studio.selection : "h5") { studio.selection = $0 }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Middle phalanx").font(.system(size: 17, weight: .semibold)).foregroundStyle(VF.text)
                        CardDivider()
                        PropertyRows(rows: Sample.phalanx)
                    }
                    .padding(16)
                    .card()
                }

                ViewCubeSlot()
                BottomFurniture()
            }
        }
    }
}

/// Right sidebar column, 296 pt, 12 pt from the edges, under the title bar.
struct RightColumn<Content: View>: View {
    var width: CGFloat = 296
    @ViewBuilder var content: Content
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 12) { content; Spacer(minLength: 0) }
                .frame(width: width)
        }
        .padding(.top, 76).padding(.trailing, 12).padding(.bottom, 12)
    }
}

struct ViewCubeSlot: View {
    var trailing: CGFloat = 296 + 12 + 22
    var body: some View {
        HStack { Spacer(); ViewCube() }
            .padding(.top, 84).padding(.trailing, trailing)
    }
}

struct BottomFurniture: View {
    var nav = true
    var body: some View {
        VStack {
            Spacer()
            ZStack(alignment: .bottomLeading) {
                AxisTriad().padding(.leading, 30).padding(.bottom, 12)
                if nav { HStack { Spacer(); NavCapsule(); Spacer() } }
            }
        }
        .padding(.bottom, 22)
    }
}
