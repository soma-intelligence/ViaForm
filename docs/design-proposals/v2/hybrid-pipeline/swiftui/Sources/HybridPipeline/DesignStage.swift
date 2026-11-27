import SwiftUI

enum DesignStage {
    static let states: PipelineStates = [
        .design: .upToDate, .generative: .upToDate, .mechanics: .stale, .electronics: .upToDate,
        .simulation: .upToDate, .training: .running, .render: .upToDate, .manufacture: .failed,
    ]

    static var screen: StageScreen {
        StageScreen(
            project: "Robotic Hand H1",
            workspace: .design,
            states: states,
            groups: [
                .init(title: "Create", tools: [.init(glyph: .png("sketch")), .init(glyph: .png("extrude")), .init(glyph: .png("revolve")), .init(glyph: .png("cylinder"))]),
                .init(title: "Modify", tools: [.init(glyph: .png("presspull"), isOn: true), .init(glyph: .png("fillet")), .init(glyph: .png("chamfer")), .init(glyph: .png("shell")), .init(glyph: .png("combine"))]),
                .init(title: "Construct", tools: [.init(glyph: .png("plane")), .init(glyph: .png("plane_angle")), .init(glyph: .png("axis_through_cylinder")), .init(glyph: .png("point_vertex"))]),
                .init(title: "Assemble", tools: [.init(glyph: .png("component")), .init(glyph: .png("joint")), .init(glyph: .png("rigid_group")), .init(glyph: .png("fastener"))]),
                .init(title: "Inspect", tools: [.init(glyph: .png("measure")), .init(glyph: .png("interference")), .init(glyph: .png("section"))]),
                .init(title: "Insert", tools: [.init(glyph: .png("import")), .init(glyph: .png("library")), .init(glyph: .png("mount"))]),
            ],
            primary: [.init(title: "Parametric", symbol: "checkmark", kind: .green)],
            rows: [
                .init(indent: 0, disclosure: .open, symbol: "cube.transparent", title: "Robotic Hand H1"),
                .init(indent: 1, disclosure: .closed, symbol: "gearshape", title: "Document Settings"),
                .init(indent: 1, disclosure: .closed, symbol: "scope", title: "Origin", eye: .off),
                .init(indent: 1, disclosure: .open, symbol: "folder", title: "Bodies"),
                .init(indent: 2, disclosure: .closed, symbol: "cube", title: "Palm"),
                .init(indent: 2, disclosure: .closed, symbol: "folder", title: "Index"),
                .init(indent: 2, disclosure: .closed, symbol: "folder", title: "Middle finger"),
                .init(indent: 2, disclosure: .closed, symbol: "folder", title: "Ring"),
                .init(indent: 2, disclosure: .closed, symbol: "folder", title: "Little"),
                .init(indent: 2, disclosure: .open, symbol: "folder", title: "Thumb"),
                .init(indent: 3, disclosure: .none, symbol: "cube.fill", title: "Proximal", selected: true),
                .init(indent: 3, disclosure: .none, symbol: "cube", title: "Distal"),
                .init(indent: 1, disclosure: .closed, symbol: "gearshape.2", title: "Motors", detail: "(16)"),
                .init(indent: 1, disclosure: .closed, symbol: "link", title: "Joints", detail: "(16)"),
                .init(indent: 1, disclosure: .closed, symbol: "pencil.and.outline", title: "Sketches", detail: "(9)", eye: .off),
            ],
            outputs: [
                .init(symbol: "cube", title: "Design bodies", status: .upToDate),
                .init(symbol: "gearshape.2", title: "Assembly", status: .stale),
                .init(symbol: "wind", title: "Flight data", status: .upToDate),
                .init(symbol: "graduationcap", title: "Policy", status: .running),
                .init(symbol: "camera.aperture", title: "Renders", status: .upToDate),
                .init(symbol: "shippingbox", title: "Build pack", status: .failed),
            ],
            inspector: AnyView(inspector),
            viewport: AnyView(DesignViewport()),
            bottom: AnyView(FeatureTimeline()),
            bottomHeight: 112,
            bottomFullWidth: true,
            status: StatusBar(leading: statusLeading("Thumb Proximal selected", .upToDate),
                              trailing: ["Units  mm", "Zoom 100%"],
                              trailingDot: ("viaform core", .upToDate))
        )
    }

    static var inspector: some View {
        InspectorPanel {
            InspectorSection(title: "Selection", showsDivider: false) {
                SelectionCard(symbol: "cube", title: "Thumb Proximal", subtitle: "Body in Thumb, PA12")
            }
            flowAndLinked(consumes: "Finger study #7", produces: "Body for Mechanics", states: states, current: .design)
            InspectorSection(title: "Parameters") {
                KVRow(label: "Length", value: "22.00", unit: "mm")
                KVRow(label: "Width", value: "9.80", unit: "mm")
                KVRow(label: "Wall", value: "1.20", unit: "mm", divider: false)
            }
            InspectorSection(title: "Motor") {
                KVRow(label: "Type", value: "Micro 8 mm")
                KVRow(label: "Torque", value: "0.12", unit: "N m")
                KVRow(label: "Gear", value: "136:1", divider: false)
            }
            InspectorSection(title: "Physical") {
                KVRow(label: "Material", value: "PA12")
                KVRow(label: "Mass", value: "3.8", unit: "g", divider: false)
            }
        }
    }
}

struct DesignViewport: View {
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let h = size.height * 0.95
            let w = h * 572 / 758
            let img = CGRect(x: (size.width - w) / 2 - 20, y: (size.height - h) / 2 + 8, width: w, height: h)
            let rel = { (x: CGFloat, y: CGFloat) in CGPoint(x: img.minX + x * img.width, y: img.minY + y * img.height) }
            let sel = CGRect(origin: rel(0.577, 0.455), size: CGSize(width: 0.218 * w, height: 0.231 * h))
            let pillSize = CGSize(width: 318, height: 84)
            ZStack(alignment: .topLeading) {
                ViewportBackground()
                Art.image("hand").resizable().frame(width: img.width, height: img.height)
                    .position(x: img.midX, y: img.midY)
                DimensionLine(a: rel(0.69, 0.75), b: rel(0.90, 0.53))
                    .stroke(VF.accent, lineWidth: 1.5)
                DimensionCallout(text: "22.00 mm").position(rel(0.93, 0.66))
                ContextPill(actions: [
                    .init(symbol: "arrow.up.and.down", title: "Press Pull", png: "presspull", isOn: true),
                    .init(symbol: "", title: "Fillet", png: "fillet"),
                    .init(symbol: "", title: "Joint", png: "joint"),
                    .init(symbol: "gearshape", title: "Motor"),
                    .init(symbol: "ellipsis", title: "More"),
                ], buttonSize: CGSize(width: 50, height: 46))
                .position(Anchor.place(pillSize, near: sel, in: size))
                ViewCube(s: 38).position(x: size.width - 16 - 33, y: 16 + 38)
                Triad().position(x: 16 + 32, y: size.height - 16 - 36)
                NavPill().position(x: size.width / 2, y: size.height - 16 - 20)
            }
        }
    }
}

struct FeatureTimeline: View {
    static let icons = ["sketch", "extrude", "revolve", "fillet", "presspull", "shell", "sketch", "extrude",
                        "chamfer", "combine", "hole", "joint", "component", "fastener", "rigid_group", "mount",
                        "plane", "extrude", "fillet", "joint", "section", "shell", "combine", "presspull", "fillet", "joint"]
    let playhead = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CapsLabel(text: "Timeline", color: VF.text.opacity(0.78))
                Text("26 features").font(.system(size: 11)).monospacedDigit().foregroundStyle(VF.secondary)
                Spacer()
                Image(systemName: "rectangle.compress.vertical").font(.system(size: 11)).foregroundStyle(VF.secondary)
            }
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    transport("backward.end.fill")
                    Image(systemName: "play.fill").font(.system(size: 15)).foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 9).fill(VF.accent))
                    transport("forward.end.fill")
                }
                Hairline(vertical: true).frame(height: 44)
                HStack(spacing: 0) {
                    ForEach(Array(Self.icons.enumerated()), id: \.offset) { i, name in
                        if i == playhead { playheadMark }
                        VStack(spacing: 4) {
                            ToolIcon(glyph: .png(name), size: 26)
                                .opacity(i >= playhead ? 0.38 : 1)
                                .frame(width: 32, height: 32)
                                .background(RoundedRectangle(cornerRadius: 6).fill(i == 10 ? VF.accent.opacity(0.22) : Color.white.opacity(0.04)))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(i == 10 ? VF.accent : .clear))
                            Text("\(i + 1)").font(.system(size: 10.5)).monospacedDigit()
                                .foregroundStyle(i >= playhead ? VF.tertiary : VF.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(VF.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var playheadMark: some View {
        VStack(spacing: 0) {
            Capsule().fill(VF.accent).frame(width: 10, height: 12)
            Rectangle().fill(VF.accent).frame(width: 2, height: 42)
        }
        .frame(width: 10)
        .offset(y: -6)
    }

    private func transport(_ s: String) -> some View {
        Image(systemName: s).font(.system(size: 13)).foregroundStyle(VF.text.opacity(0.85)).frame(width: 30, height: 38)
    }
}
