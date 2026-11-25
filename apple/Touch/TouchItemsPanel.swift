#if os(iOS)
import SwiftUI

// The iPad Items manager after Shapr3D (docs/research/cad-ui/shapr3d-ipad.md 6): it slides in
// from the left. Filter All / Bodies / Sketches / Planes and Axes; folders; rows select (several
// at once, solid accent with light text); a bottom bar acts on the selection: Rename, Delete,
// More. Construction planes and axes are listed and each plane is sketchable (B-14). Every action
// is an engine command (PanelOps). A long press lifts a row (or the selection it is part of) to
// drag it onto a folder.

/// A side panel over the viewport (iPad): Items on the left, History on the right. Opaque
/// white, the full height of the screen (`TouchSidePanel`).
struct TouchPanelCard: ViewModifier {
    let on: Bool
    var width: CGFloat = TouchRail.itemsWidth

    func body(content: Content) -> some View {
        if on {
            content.modifier(TouchSidePanel(width: width))
        } else {
            content
        }
    }
}

/// Which side panels are open: Items (left) and History (right), each on its own (T-6).
struct TouchPanels: Equatable {
    var items = false
    var history = false

    init() {}

    init(_ side: TouchSideCard?) {
        items = side == .items
        history = side == .history
    }

    /// "Items", "History" or "Items,History", as the scene keeps it.
    init(stored: String) {
        let parts = stored.split(separator: ",").map(String.init)
        items = parts.contains(TouchSideCard.items.rawValue)
        history = parts.contains(TouchSideCard.history.rawValue)
    }

    var stored: String {
        [items ? TouchSideCard.items.rawValue : nil, history ? TouchSideCard.history.rawValue : nil]
            .compactMap { $0 }.joined(separator: ",")
    }

    var any: Bool { items || history }

    /// The one-card binding the top capsule's Items | History switch takes: it reads the open
    /// panel (History first) and toggles the one tapped, so both can be open at once.
    func sideBinding(_ panels: Binding<TouchPanels>) -> Binding<TouchSideCard?> {
        Binding(
            get: { panels.wrappedValue.history ? .history : (panels.wrappedValue.items ? .items : nil) },
            set: { new in
                let shown: TouchSideCard? = panels.wrappedValue.history ? .history : (panels.wrappedValue.items ? .items : nil)
                switch new {
                case .items?: panels.wrappedValue.items.toggle()
                case .history?: panels.wrappedValue.history.toggle()
                case nil:
                    if shown == .history { panels.wrappedValue.history = false } else { panels.wrappedValue.items = false }
                }
            })
    }
}

enum ItemsFilter: String, CaseIterable, Identifiable {
    case all, bodies, sketches, construction
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .bodies: String(localized: "Bodies")
        case .sketches: String(localized: "Sketches")
        case .construction: String(localized: "Planes and Axes")
        }
    }

    /// The segment label: "Planes" stands for Planes and Axes where width is short.
    var shortTitle: String { self == .construction ? String(localized: "Planes") : title }

    func shows(_ kind: PanelItem.Kind) -> Bool {
        switch self {
        case .all: true
        case .bodies: kind == .body
        case .sketches: kind == .sketch
        case .construction: kind == .construction
        }
    }

    /// The plural name of a kind, for messages.
    static func title(of kind: PanelItem.Kind) -> String {
        switch kind {
        case .body: String(localized: "bodies")
        case .sketch: String(localized: "sketches")
        case .construction: String(localized: "planes and axes")
        }
    }

    /// The kind a new empty folder gets.
    var folderKind: PanelItem.Kind {
        switch self {
        case .sketches: .sketch
        case .construction: .construction
        default: .body
        }
    }
}

/// Bodies, sketches, planes and axes, with folders, visibility and a selection action bar.
struct ItemsPanel: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    let model: DesignModel
    var floating = true

    @State private var filter: ItemsFilter = .all
    /// Selected sketches and construction items; selected bodies are the design's selection.
    @State private var picked: Set<PanelItem> = []
    @State private var openFolders: Set<Int> = []
    @State private var renameItem: PanelItem?
    @State private var renameFolder: ItemFolder?
    @State private var renameText = ""
    @State private var error: String?
    /// Bumped when the folder store changes (it is not observed).
    @State private var folderTick = 0
    /// The construction plane and axis form (agent F's ConstructForm).
    @State private var showConstruct = false
    @State private var showMass = false
    /// The folder a dragged row hovers over (T-14: long press, then drag onto a folder).
    @State private var dropFolder: Int?

    var body: some View {
        let _ = units
        let _ = folderTick
        VStack(spacing: 0) {
            header
            List {
                components
                folderRows
                section(.body, String(localized: "Bodies"))
                section(.sketch, String(localized: "Sketches"))
                section(.construction, String(localized: "Planes and Axes"))
                if visibleCount == 0 {
                    empty.listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, VFSize.touchTarget)
            if let error {
                InlineError(error, dismiss: { self.error = nil }).padding(VFSpace.m)
            }
            actionBar
        }
        .modifier(TouchPanelCard(on: floating))
        .sheet(isPresented: $showConstruct) {
            ConstructForm(model: model, kind: .offset) { showConstruct = false }
                .viaFormTheme()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showMass) {
            MassPropertiesView(model: model) { showMass = false }
                .viaFormTheme()
                .presentationDetents([.medium, .large])
        }
        .alert(String(localized: "Rename"), isPresented: Binding(get: { renameItem != nil || renameFolder != nil },
                                                                 set: { if !$0 { renameItem = nil; renameFolder = nil } })) {
            TextField(String(localized: "Name"), text: $renameText)
            Button(String(localized: "Rename")) { commitRename() }
            Button(String(localized: "Cancel"), role: .cancel) { renameItem = nil; renameFolder = nil }
        }
    }

    // MARK: Data

    private var folders: [ItemFolder] { ItemFolderStore.shared.folders(model).filter { filter.shows($0.kind) } }

    private var foldered: Set<String> { Set(ItemFolderStore.shared.folders(model).flatMap(\.items).map(\.id)) }

    private func items(_ kind: PanelItem.Kind) -> [PanelItem] {
        guard filter.shows(kind) else { return [] }
        let inFolder = foldered
        return PanelOps.items(model.snapshot).filter { $0.kind == kind && !inFolder.contains($0.id) }
    }

    private var visibleCount: Int {
        PanelOps.items(model.snapshot).filter { filter.shows($0.kind) }.count + folders.count
            + (filter == .all ? model.assembly.count : 0)
    }

    private var selection: [PanelItem] {
        let bodies = model.snapshot.bodies.filter { model.selectedBodies.contains($0.name) }
            .map { PanelItem(kind: .body, name: $0.name, feature: nil) }
        let present = Set(PanelOps.items(model.snapshot))
        return bodies + picked.filter { present.contains($0) }.sorted { $0.name < $1.name }
    }

    private func isSelected(_ i: PanelItem) -> Bool {
        i.kind == .body ? model.selectedBodies.contains(i.name) : picked.contains(i)
    }

    private func toggle(_ i: PanelItem) {
        if i.kind == .body {
            if model.selectedBodies.contains(i.name) { model.selectedBodies.remove(i.name) } else { model.selectedBodies.insert(i.name) }
        } else if picked.contains(i) {
            picked.remove(i)
        } else {
            picked.insert(i)
        }
    }

    private func deselectAll() {
        model.selectedBodies = []
        picked = []
    }

    // MARK: Header

    /// "All Items" with its filter menu in the middle, New Folder on the right, as the
    /// reference manager's title row. Add Plane or Axis sits in the same menu.
    private var header: some View {
        ZStack {
            Menu {
                Picker(String(localized: "Show"), selection: $filter) {
                    ForEach(ItemsFilter.allCases) { f in Text(f == .all ? String(localized: "All Items") : f.title).tag(f) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Add Plane or Axis…", systemImage: "square.3.layers.3d") { showConstruct = true }
            } label: {
                HStack(spacing: VFSpace.xs) {
                    Text(filter == .all ? String(localized: "All Items") : filter.title).font(VFFont.rowEmphasis)
                    Image(systemName: "chevron.up.chevron.down").font(VFFont.icon(10, weight: .semibold)).accessibilityHidden(true)
                }
                .foregroundStyle(theme.ink)
                .frame(minHeight: VFSize.touchTarget)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Show"))
            .accessibilityValue(filter.title)
            HStack {
                Spacer(minLength: 0)
                VFIconButton("folder.badge.plus",
                             label: selection.isEmpty ? String(localized: "New Folder") : String(localized: "New Folder from Selection"),
                             size: 16, tint: theme.accentText) { newFolder() }
            }
        }
        .padding(.horizontal, VFSpace.m)
        .padding(.top, VFSpace.xs)
    }

    // MARK: Sections

    @ViewBuilder private var components: some View {
        if filter == .all, !model.assembly.isEmpty {
            Section("Components") {
                ForEach(model.assembly) { c in
                    HStack {
                        Image(systemName: c.linkedPCB ? "cpu" : "shippingbox").foregroundStyle(c.linkedPCB ? theme.accentText : theme.inkSecondary)
                            .accessibilityHidden(true)
                        Text(c.occurrence ?? c.name).foregroundStyle(theme.ink)
                        Spacer()
                        if c.linkedPCB { Image(systemName: "link").foregroundStyle(theme.accentText).accessibilityLabel(Text("Linked to the board")) }
                        if c.grounded { Image(systemName: "pin.fill").foregroundStyle(theme.inkSecondary).accessibilityLabel(Text("Grounded")) }
                    }
                    .font(VFFont.row)
                    .frame(minHeight: VFSize.touchTarget)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedBodies = Set(c.bodies) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Selects its bodies"))
                    .contextMenu {
                        Button("Select Bodies", systemImage: "cursorarrow") { model.selectedBodies = Set(c.bodies) }
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    @ViewBuilder private var folderRows: some View {
        if !folders.isEmpty {
            Section("Folders") {
                ForEach(folders) { f in
                    let open = openFolders.contains(f.id)
                    Button {
                        if open { openFolders.remove(f.id) } else { openFolders.insert(f.id) }
                    } label: {
                        HStack(spacing: VFSpace.m) {
                            Image(systemName: open ? "folder.fill" : "folder").foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(VFFont.row).foregroundStyle(theme.ink)
                                Text("^[\(f.items.count) item](inflect: true)").font(VFFont.micro).foregroundStyle(theme.inkSecondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right.circle")
                                .rotationEffect(.degrees(open ? 90 : 0))
                                .foregroundStyle(theme.inkSecondary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: VFSize.touchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: String.self) { ids, _ in
                        drop(ids, into: f)
                    } isTargeted: { on in
                        if on { dropFolder = f.id } else if dropFolder == f.id { dropFolder = nil }
                    }
                    .accessibilityValue(open ? String(localized: "Open") : String(localized: "Closed"))
                    .contextMenu {
                        Button("Rename", systemImage: "character.cursor.ibeam") { renameText = f.name; renameFolder = f }
                        if !selection.isEmpty {
                            Button("Move Selection Here", systemImage: "folder") { move(into: f) }
                        }
                        Button("Ungroup", systemImage: "folder.badge.minus") {
                            error = ItemFolderStore.shared.ungroup(f.id, model)
                            folderTick += 1
                        }
                    }
                    .listRowBackground(dropFolder == f.id ? theme.accent.opacity(0.18) : Color.clear)
                    if open {
                        if f.items.isEmpty {
                            Text("Folder is empty").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                                .padding(.leading, VFSpace.xxl)
                                .listRowBackground(Color.clear)
                        }
                        ForEach(f.items) { i in itemRow(i).padding(.leading, VFSpace.xl) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func section(_ kind: PanelItem.Kind, _ title: String) -> some View {
        let list = items(kind)
        if !list.isEmpty {
            // One flat list, as the reference: the kinds follow each other with no headers.
            Section {
                ForEach(list) { i in itemRow(i) }
            }
            .listSectionSeparator(.hidden)
        }
    }

    @ViewBuilder private var empty: some View {
        switch filter {
        case .all: EmptyState(String(localized: "Workspace is empty"), systemImage: "folder",
                              message: String(localized: "Sketch on a plane, then extrude, to make the first body."))
        case .bodies: EmptyState(String(localized: "No bodies"), systemImage: "cube")
        case .sketches: EmptyState(String(localized: "No sketches"), systemImage: "pencil.and.outline")
        case .construction: EmptyState(String(localized: "No planes or axes"), systemImage: "square.3.layers.3d",
                                       message: String(localized: "Add a construction plane to sketch away from the base planes."),
                                       actionTitle: String(localized: "Add Plane"), action: { showConstruct = true })
        }
    }

    // MARK: Rows

    private func itemRow(_ i: PanelItem) -> some View {
        let selected = isSelected(i)
        let visible = isVisible(i)
        return HStack(spacing: VFSpace.m) {
            Image(systemName: symbol(i)).foregroundStyle(selected ? theme.onAccent : theme.inkSecondary).accessibilityHidden(true)
            // The name alone, as the reference rows; the details stay for VoiceOver.
            Text(i.name).font(VFFont.row.weight(.medium)).lineLimit(1)
                .foregroundStyle(selected ? theme.onAccent : (visible ? theme.ink : theme.inkTertiary))
                .accessibilityValue(subtitle(i) ?? "")
            Spacer(minLength: 0)
            if i.kind != .construction {
                VFIconButton(visible ? "eye" : "eye.slash",
                             label: visible ? String(localized: "Hide \(i.name)") : String(localized: "Show \(i.name)"),
                             size: 15, tint: selected ? theme.onAccent : (visible ? theme.ink : theme.inkTertiary)) {
                    PanelOps.setVisible([i], !visible, model)
                }
            }
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .onTapGesture { toggle(i) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text("Selects it; select several to act on them together"))
        .contextMenu { menu(for: [i]) }
        .draggable(i.id) {
            Label(dragTitle(i), systemImage: symbol(i)).font(VFFont.row).padding(VFSpace.s)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous)
                .fill(selected ? theme.accent : Color.clear)
                .padding(.horizontal, VFSpace.s)
                .padding(.vertical, VFSpace.xxs)
        )
    }

    private func isVisible(_ i: PanelItem) -> Bool {
        switch i.kind {
        case .body: model.snapshot.bodies.first(where: { $0.name == i.name })?.visible ?? true
        case .sketch: model.snapshot.sketches.first(where: { $0.id == i.feature })?.visible ?? true
        case .construction: true
        }
    }

    private func symbol(_ i: PanelItem) -> String {
        switch i.kind {
        case .body: "cube.fill"
        case .sketch: "pencil.and.outline"
        case .construction:
            switch model.snapshot.timeline.first(where: { $0.id == i.feature })?.type {
            case "ConstructionAxis": "line.diagonal"
            case "ConstructionPoint": "smallcircle.filled.circle"
            default: "square.3.layers.3d"
            }
        }
    }

    private func subtitle(_ i: PanelItem) -> String? {
        switch i.kind {
        case .body:
            return model.snapshot.bodies.first(where: { $0.name == i.name })?.volume_mm3.map { VFFormat.volume($0) }
        case .sketch:
            guard let s = model.snapshot.sketches.first(where: { $0.id == i.feature }) else { return nil }
            return s.profiles.map { String(AttributedString(localized: "^[\($0) profile](inflect: true)").characters) }
        case .construction:
            switch model.snapshot.timeline.first(where: { $0.id == i.feature })?.type {
            case "ConstructionAxis": return String(localized: "Axis")
            case "ConstructionPoint": return String(localized: "Point")
            default: return String(localized: "Plane")
            }
        }
    }

    // MARK: Actions

    /// The row menu and the More menu: what fits the items.
    @ViewBuilder private func menu(for items: [PanelItem]) -> some View {
        if items.count == 1, let i = items.first {
            Button(isSelected(i) ? String(localized: "Deselect") : String(localized: "Select"), systemImage: "cursorarrow") { toggle(i) }
            Button("Rename", systemImage: "character.cursor.ibeam") { renameText = i.name; renameItem = i }
            if i.kind == .sketch, let f = i.feature {
                Button("Edit Sketch", systemImage: "pencil") { PanelOps.editSketch(f, model) }
            }
            if i.kind == .construction, symbol(i) == "square.3.layers.3d" {
                Button("Sketch on Plane", systemImage: "pencil.and.outline") { PanelOps.sketch(on: i, model) }
            }
        }
        if items.contains(where: { $0.kind != .construction }) {
            Button("Hide", systemImage: "eye.slash") { PanelOps.setVisible(items, false, model) }
            Button("Show", systemImage: "eye") { PanelOps.setVisible(items, true, model) }
        }
        if items.contains(where: { $0.kind == .body }) {
            Button("Mass Properties", systemImage: "scalemass") { showMass = true }
        }
        Button("New Folder from Selection", systemImage: "folder.badge.plus") { group(items) }
        let targets = ItemFolderStore.shared.folders(model).filter { f in items.contains { $0.kind == f.kind } }
        if !targets.isEmpty {
            Menu("Move to Folder") {
                ForEach(targets) { f in Button(f.name) { move(items, into: f) } }
            }
        }
        Divider()
        Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) { delete(items) }
    }

    /// Rename, Delete and More… along the bottom, in accent text, grey until something is picked.
    private var actionBar: some View {
        let sel = selection
        return HStack(spacing: VFSpace.s) {
            Button("Rename") { if let i = sel.first { renameText = i.name; renameItem = i } }
                .buttonStyle(.vfTouch)
                .vfDisabled(sel.count != 1, reason: String(localized: "Select one item to rename"))
            Spacer(minLength: 0)
            Button(String(localized: "Delete")) { delete(sel) }
                .buttonStyle(.vfTouch)
                .vfDisabled(sel.isEmpty, reason: String(localized: "Select items to delete"))
            Spacer(minLength: 0)
            Menu {
                menu(for: sel)
                Button("Deselect All", systemImage: "xmark.circle") { deselectAll() }
            } label: {
                Text("More…").frame(minHeight: VFSize.touchTarget).contentShape(Rectangle())
            }
            .disabled(sel.isEmpty)
            .hoverEffect(.highlight)
        }
        .font(VFFont.row)
        .foregroundStyle(sel.isEmpty ? theme.inkTertiary : theme.accentText)
        .padding(.horizontal, VFSpace.xl)
        .padding(.bottom, VFSpace.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(sel.count) selected"))
    }

    private func delete(_ items: [PanelItem]) {
        guard !items.isEmpty else { return }
        if let why = PanelOps.delete(items, model) { error = why; return }
        picked.subtract(items)
        let step = DesignStep(model)
        let what = items.count == 1 ? items[0].name : String(localized: "\(items.count) items")
        toasts?.show(String(localized: "Deleted \(what)"), systemImage: "trash", actionTitle: String(localized: "Undo")) { step.undo() }
    }

    private func group(_ items: [PanelItem]) {
        switch PanelOps.group(items, name: nil, model) {
        case .success(let made):
            for f in made { ItemFolderStore.shared.add(f, model); openFolders.insert(f.id) }
            deselectAll()
        case .failure(let why): error = why.message
        }
        folderTick += 1
    }

    private func newFolder() {
        if !selection.isEmpty { group(selection); return }
        switch PanelOps.newFolder(filter.folderKind, model) {
        case .success(let f):
            ItemFolderStore.shared.add(f, model)
            renameText = f.name
            renameFolder = f
        case .failure(let why): error = why.message
        }
        folderTick += 1
    }

    private func move(_ items: [PanelItem]? = nil, into f: ItemFolder) {
        error = ItemFolderStore.shared.move(items ?? selection, into: f.id, model)
        openFolders.insert(f.id)
        folderTick += 1
    }

    /// What a drag of `i` carries: the whole selection when `i` is part of it, else `i` alone.
    private func dragged(_ i: PanelItem) -> [PanelItem] {
        isSelected(i) ? selection : [i]
    }

    private func dragTitle(_ i: PanelItem) -> String {
        let n = dragged(i).count
        return n > 1 ? String(localized: "\(n) items") : i.name
    }

    /// Rows dropped on a folder move into it (the ones of the folder's kind), with the rest of
    /// the selection when the dragged row was selected.
    private func drop(_ ids: [String], into f: ItemFolder) -> Bool {
        dropFolder = nil
        let all = PanelOps.items(model.snapshot)
        let hit = all.filter { ids.contains($0.id) }
        var moving: [PanelItem] = []
        for i in hit { for x in dragged(i) where !moving.contains(x) { moving.append(x) } }
        moving = moving.filter { $0.kind == f.kind }
        guard !moving.isEmpty else {
            error = String(localized: "This folder holds \(ItemsFilter.title(of: f.kind)) only.")
            return false
        }
        move(moving, into: f)
        return error == nil
    }

    private func commitRename() {
        let text = renameText
        if let f = renameFolder {
            renameFolder = nil
            error = ItemFolderStore.shared.rename(f.id, to: text, model)
            folderTick += 1
        } else if let i = renameItem {
            renameItem = nil
            error = PanelOps.rename(i, to: text, model)
            if error == nil, picked.remove(i) != nil {
                picked.insert(PanelItem(kind: i.kind, name: text.trimmingCharacters(in: .whitespacesAndNewlines), feature: i.feature))
            }
        }
    }
}

// MARK: - Section view (B-15, touch side)

/// Section View on touch: pick the plane (a base plane or a construction plane), drag or type the
/// offset, Delete Section. Drives agent C's `SectionController` (engine cut plus renderer clip).
struct TouchSectionControl: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let close: () -> Void
    @State private var plane = "XZ"
    @State private var offset: Double = 0

    private var planes: [String] {
        ["XY", "XZ", "YZ"] + model.snapshot.timeline.filter { $0.type == "ConstructionPlane" }.map(\.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            HStack(spacing: VFSpace.s) {
                Image(systemName: "square.split.diagonal.2x2").foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                Text("Section View").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                Spacer(minLength: 0)
                Menu {
                    ForEach(planes, id: \.self) { p in
                        Button { plane = p; cut() } label: { Label(p, systemImage: p == plane ? "checkmark" : "square") }
                    }
                } label: {
                    Text(plane).font(VFFont.row.weight(.medium)).foregroundStyle(theme.accentText)
                        .padding(.horizontal, VFSpace.m)
                        .frame(minHeight: VFSize.touchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Section plane"))
                .accessibilityValue(plane)
            }
            HStack(spacing: VFSpace.s) {
                Slider(value: $offset, in: -100...100) { editing in if !editing { cut() } }
                    .accessibilityLabel(Text("Offset"))
                Text(VFFormat.length(offset)).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            Button(String(localized: "Delete Section"), role: .destructive) { clear() }
                .buttonStyle(.vfSecondary)
        }
        .padding(VFSpace.l)
        .frame(width: 280)
        .vfSurface(.floating, radius: VFRadius.touchFloating)
        .onAppear(perform: cut)
    }

    private func cut() {
        SectionController.of(model).set(named: plane, offset: offset, model: model)
    }

    private func clear() {
        close()
    }
}

#endif
