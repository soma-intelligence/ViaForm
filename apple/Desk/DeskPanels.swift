#if os(macOS)
import AppKit
import SwiftUI

// MARK: Marking menu

/// The right-click wheel: eight commands around the cursor and an overflow list under it.
/// Drag or click toward a slice to run it; Escape or a click outside closes it.
struct MarkingMenu: View {
    let model: DesignModel
    let at: CGPoint

    private struct Slot: Identifiable {
        let id: String
        let symbol: String
        let run: (DesignModel) -> Void
    }

    private var wheel: [Slot] {
        if model.sketchOpen {
            return [
                Slot(id: "Line", symbol: Tool.line.symbol) { $0.tool = .line },
                Slot(id: "Finish Sketch", symbol: "checkmark.circle") { $0.finishSketch() },
                Slot(id: "Rectangle", symbol: Tool.rectangle.symbol) { $0.tool = .rectangle },
                Slot(id: "Redo", symbol: "arrow.uturn.forward") { $0.redo() },
                Slot(id: "Trim", symbol: Tool.trim.symbol) { $0.tool = .trim },
                Slot(id: "Delete", symbol: "trash") { $0.deleteSelection() },
                Slot(id: "Circle", symbol: Tool.circle.symbol) { $0.tool = .circle },
                Slot(id: "Undo", symbol: "arrow.uturn.backward") { $0.undo() },
            ]
        }
        return [
            Slot(id: "Sketch", symbol: Tool.sketch.symbol) { m in
                if m.selection.contains(where: \.isFace) { m.sketchOnSelectedFace() } else { m.tool = .sketch }
            },
            Slot(id: "Press Pull", symbol: Tool.pressPull.symbol) { $0.tool = .pressPull },
            Slot(id: "Extrude", symbol: Tool.extrude.symbol) { $0.tool = .extrude },
            Slot(id: "Redo", symbol: "arrow.uturn.forward") { $0.redo() },
            Slot(id: "Move", symbol: Tool.move.symbol) { $0.tool = .move },
            Slot(id: "Delete", symbol: "trash") { $0.deleteSelection() },
            Slot(id: "Fillet", symbol: Tool.fillet.symbol) { $0.tool = .fillet },
            Slot(id: "Undo", symbol: "arrow.uturn.backward") { $0.undo() },
        ]
    }

    private var overflow: [Slot] {
        [
            Slot(id: "Repeat Last", symbol: "repeat") { m in if let t = m.lastTool { m.tool = t } },
            Slot(id: "Fit", symbol: "arrow.up.left.and.down.right.magnifyingglass") { $0.zoomToFit() },
            Slot(id: "Measure", symbol: "ruler") { $0.measureSelection() },
            Slot(id: "Toolbox Search", symbol: "magnifyingglass") { $0.toolboxOpen = true },
        ]
    }

    private let radius: CGFloat = 92

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .onTapGesture { model.markingMenu = nil }
            Circle().fill(.ultraThinMaterial).frame(width: 30, height: 30)
                .overlay(Circle().stroke(Color.black.opacity(0.2)))
                .position(at)
            // Order: top, top right, right, bottom right, bottom, bottom left, left, top left.
            ForEach(Array(wheel.enumerated()), id: \.element.id) { i, slot in
                let a = -Double.pi / 2 + Double(i) * .pi / 4
                pill(slot)
                    .position(x: at.x + radius * cos(a) * (i % 4 == 0 ? 1 : 1.25), y: at.y + radius * sin(a) * 0.82)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(overflow) { slot in
                    Button { fire(slot) } label: {
                        Label(slot.id, systemImage: slot.symbol).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).frame(height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 12))
            .frame(width: 170)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.15)))
            .position(x: at.x, y: at.y + radius + 74)
        }
    }

    private func pill(_ slot: Slot) -> some View {
        Button { fire(slot) } label: {
            HStack(spacing: 6) {
                Image(systemName: slot.symbol).frame(width: 16)
                Text(slot.id)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).frame(height: 26)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.black.opacity(0.15)))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func fire(_ slot: Slot) {
        model.markingMenu = nil
        slot.run(model)
    }
}

// MARK: Toolbox search

/// S opens a search over every registry command; Return runs the first match.
struct ToolboxSearch: View {
    @Bindable var model: DesignModel
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [CommandInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(model.commands.filter { $0.key != nil }.prefix(12)) }
        return Array(model.commands.filter {
            $0.label.lowercased().contains(q) || $0.id.lowercased().contains(q) || $0.panel.lowercased().contains(q)
        }.prefix(14))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { if let c = matches.first { run(c) } }
                    .onExitCommand { close() }
            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(matches) { c in
                        Button { run(c) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: CommandSymbol.of(c.icon, id: c.id)).frame(width: 18)
                                Text(c.label)
                                Spacer()
                                Text(c.tab.capitalized + " · " + c.panel.capitalized).foregroundStyle(.secondary).font(.system(size: 11))
                                if let k = c.key { Text(k).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                            }
                            .font(.system(size: 13))
                            .padding(.horizontal, 12).frame(height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.15)))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .onAppear { focused = true }
    }

    private func run(_ c: CommandInfo) {
        close()
        CommandRouter.run(c, model)
    }

    private func close() {
        query = ""
        model.toolboxOpen = false
    }
}

// MARK: Data panel

/// The slide-in file panel: new design, the sample and the recent files.
struct DataPanel: View {
    let model: DesignModel
    @Binding var shown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Data").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { shown = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(12)
            Divider()
            HStack(spacing: 8) {
                Button("New Design") { model.newDesign(); shown = false }
                Button("Open…") { FileActions.open(model); shown = false }
            }
            .padding(12)
            Text("SAMPLES").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).padding(.horizontal, 12)
            tile("Bracket", "cube.fill") { model.loadSample(); shown = false }
            Text("RECENT").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(NSDocumentController.shared.recentDocumentURLs, id: \.self) { url in
                        tile(url.deletingPathExtension().lastPathComponent, "doc") { model.open(url); shown = false }
                    }
                }
            }
            Spacer()
        }
        .frame(width: 260)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func tile(_ name: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .frame(width: 44, height: 34)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                Text(name).font(.system(size: 12)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
