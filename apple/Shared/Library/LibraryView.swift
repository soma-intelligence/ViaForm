import SwiftUI
import UniformTypeIdentifiers

/// The Libraries panel: one search over KiCad, standard hardware, the shops' APIs and the saved
/// parts; the saved parts with their CAD files; the sources with their keys (in the Keychain).
/// Shops without an open API are searched in the browser and saved from a pasted link.
struct LibraryView: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    @Bindable var model: LibraryModel
    let design: DesignModel
    let pcb: PCBModel
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Libraries", systemImage: "books.vertical").font(VFFont.title).foregroundStyle(theme.ink)
                Spacer()
                #if os(iOS)
                Button("Done", action: close).font(VFFont.rowEmphasis).buttonStyle(.vfGhost(tint: theme.accentText))
                #else
                VFIconButton("xmark", label: String(localized: "Close Libraries"), action: close)
                #endif
            }
            .padding(.horizontal, VFSpace.panelPadding).padding(.top, VFSpace.l)
            VFSegmented(String(localized: "Section"), selection: $model.tab) { String(localized: String.LocalizationValue($0.rawValue)) }
            .padding(.horizontal, VFSpace.panelPadding).padding(.vertical, VFSpace.m)
            if let m = model.message {
                InlineError(m, severity: model.messageIsError ? .error : .warning, dismiss: { model.say(nil) })
                    .padding(.horizontal, VFSpace.panelPadding).padding(.bottom, VFSpace.m)
            }
            Divider()
            switch model.tab {
            case .search: LibrarySearchTab(model: model, design: design, pcb: pcb)
            case .saved: LibrarySavedTab(model: model, design: design, pcb: pcb)
            case .sources: LibrarySourcesTab(model: model)
            }
        }
        .task { await model.load() }
        .sheet(item: $model.draft) { d in LibraryEditor(model: model, item: d) }
        .onChange(of: model.notice) { _, n in
            guard let n else { return }
            model.notice = nil
            if let toasts {
                if n.undo { toasts.show(n.text, actionTitle: String(localized: "Undo")) { Task { await model.undoRemoveRoot() } } }
                else { toasts.show(n.text) }
            }
        }
    }
}

// MARK: Search

private struct LibrarySearchTab: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: LibraryModel
    let design: DesignModel
    let pcb: PCBModel
    @State private var link = ""
    @Environment(\.openURL) private var openURL
    private var network: VFNetwork { VFNetwork.shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: VFSpace.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                TextField("Search parts", text: $model.query, prompt: Text("LM358, M3x12, 608 bearing, stepper motor…"))
                    .textFieldStyle(.plain)
                    .font(VFFont.row)
                    .onSubmit { Task { await model.search() } }
                // A reserved slot: the field never moves when the spinner comes and goes.
                ZStack {
                    if model.searching { ProgressView().controlSize(.small).accessibilityLabel("Searching") }
                }
                .frame(width: 18, height: 18)
            }
            .padding(VFSpace.m)
            .background(theme.well, in: RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous))
            .padding(VFSpace.panelPadding)
            if !network.online {
                Label("Offline. Shop searches wait for the network; KiCad, hardware and saved parts still answer.", systemImage: "wifi.slash")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .padding(.horizontal, VFSpace.panelPadding).padding(.bottom, VFSpace.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            List {
                results
                Section("Search in a shop's own site") {
                    let shops = model.sources.filter { $0.searchUrl != nil && $0.enabled }
                    FlowRow(shops) { s in
                        Button(s.name) { Task { if let u = await model.searchPage(s.id) { openURL(u) } } }
                            .buttonStyle(.vfSecondary)
                            .help("Opens \(s.name) in the browser; save a part from it with its link below")
                    }
                    .vfDisabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty, reason: String(localized: "Type what to search for first"))
                }
                Section("Save a part from its link") {
                    HStack {
                        TextField("Product link", text: $link, prompt: Text("https://www.amazon.com/dp/…, mcmaster.com/…, aliexpress…"))
                            .vfField()
                            .onSubmit(paste)
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                        Button("Add", action: paste)
                            .buttonStyle(.vfSecondary)
                            .vfDisabled(link.isEmpty, reason: String(localized: "Paste a product link first"))
                    }
                    Text("Only the text of the link is read: the page is never fetched.").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// Before the first search: an invitation. After it: one "no results" for every source, or
    /// the sources with hits, each source error with Retry. Old hits stay dimmed while a new
    /// search runs.
    @ViewBuilder private var results: some View {
        if model.searchedQuery == nil {
            if !model.searching {
                EmptyState(String(localized: "Search every library at once"), systemImage: "magnifyingglass",
                           message: String(localized: "KiCad symbols and footprints, standard hardware, your saved parts and the shops whose keys you added."))
                    .listRowBackground(Color.clear)
            }
        } else if model.hits.allSatisfy({ $0.items.isEmpty && $0.error == nil }) {
            ContentUnavailableView.search(text: model.searchedQuery ?? model.query)
                .listRowBackground(Color.clear)
        } else {
            ForEach(model.hits.filter { !$0.items.isEmpty || $0.error != nil }, id: \.source) { h in
                Section {
                    if let e = h.error {
                        let offline = !network.online
                        InlineError(offline ? String(localized: "Offline. This shop answers once the network is back.") : e,
                                    severity: .warning, details: offline ? e : nil,
                                    retry: model.retrying.contains(h.source) ? nil : { Task { await model.retry(source: h.source) } })
                    }
                    ForEach(h.items) { it in LibraryRow(model: model, item: it, design: design, pcb: pcb) }
                } header: {
                    HStack {
                        Text(h.source == "mine" ? String(localized: "My saved parts") : model.source(h.source)?.name ?? h.source)
                        Spacer()
                        if model.retrying.contains(h.source) { ProgressView().controlSize(.mini) }
                        if h.total > h.items.count { Text("\(h.items.count) of \(h.total)").foregroundStyle(theme.inkSecondary) }
                    }
                }
                .opacity(model.searching ? 0.45 : 1)
            }
            let empty = model.hits.filter { $0.items.isEmpty && $0.error == nil }
            if !empty.isEmpty {
                Text("No results in \(empty.map { $0.source == "mine" ? String(localized: "My saved parts") : model.source($0.source)?.name ?? $0.source }.formatted(.list(type: .and)))")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .opacity(model.searching ? 0.45 : 1)
            }
        }
    }

    private func paste() {
        let l = link
        Task { await model.paste(link: l); if model.draft != nil { link = "" } }
    }
}

/// Buttons that wrap onto as many lines as they need.
private struct FlowRow<Data: RandomAccessCollection, Content: View>: View where Data.Element: Identifiable {
    let data: Data
    let content: (Data.Element) -> Content
    init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: VFSpace.s, alignment: .leading)], alignment: .leading, spacing: VFSpace.s) {
            ForEach(data) { content($0) }
        }
    }
}

// MARK: One part

private struct LibraryRow: View {
    @Environment(\.viaFormTheme) private var theme
    let model: LibraryModel
    let item: LibraryItem
    let design: DesignModel
    let pcb: PCBModel
    var savedTab = false
    @State private var attaching = false
    @State private var confirm: ConfirmRequest?
    @Environment(\.openURL) private var openURL

    private var title: String { item.name.isEmpty ? item.partNumber : item.name }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink).lineLimit(2)
                Spacer(minLength: VFSpace.xs)
                if model.isSaved(item) && !savedTab {
                    Label("Saved", systemImage: "bookmark.fill").font(VFFont.small).foregroundStyle(theme.accentText)
                }
            }
            Text([item.partNumber, item.manufacturer, model.source(item.source)?.name].compactMap { $0 }.joined(separator: " · "))
                .font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
            if let d = item.description { Text(d).font(VFFont.small).foregroundStyle(theme.ink).lineLimit(2) }
            HStack(spacing: VFSpace.m) {
                if let p = item.priceText { Text(p).font(VFFont.small) }
                if let s = item.stock {
                    // A word and a shape, never the colour alone.
                    Label(s > 0 ? String(localized: "\(Int(s)) in stock") : String(localized: "Out of stock"),
                          systemImage: s > 0 ? "checkmark.circle" : "xmark.circle")
                        .font(VFFont.small).foregroundStyle(s > 0 ? theme.success : theme.warning)
                }
            }
            if let n = item.notes, savedTab { Text(n).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(3) }
            if savedTab && !item.files.isEmpty {
                ForEach(item.files, id: \.path) { f in Label(f.label, systemImage: "doc").font(VFFont.micro).foregroundStyle(theme.inkSecondary) }
            }
            HStack(spacing: VFSpace.s) {
                ForEach(item.uses, id: \.self) { u in
                    Button { Task { await model.use(u, of: item, design: design, pcb: pcb) } } label: { Label(LocalizedStringKey(u.label), systemImage: u.symbol) }
                        .buttonStyle(.vfGhost(tint: theme.accentText)).font(VFFont.small)
                }
                Spacer(minLength: 0)
                if let u = LibraryModel.web(item.url) {
                    VFIconButton("safari", label: String(localized: "Open the product page")) { openURL(u) }
                }
                if let d = LibraryModel.web(item.datasheet) {
                    VFIconButton("doc.richtext", label: String(localized: "Open the datasheet")) { openURL(d) }
                }
                if savedTab {
                    VFIconButton("pencil", label: String(localized: "Edit")) { model.draft = item }
                    VFIconButton("paperclip", label: String(localized: "Attach a STEP, .kicad_mod or .kicad_sym file")) { attaching = true }
                    VFIconButton("trash", label: String(localized: "Delete from the library"), role: .destructive) { askDelete() }
                } else if item.source != "kicad" && item.source != "standard" || !model.isSaved(item) {
                    VFIconButton(model.isSaved(item) ? "bookmark.fill" : "bookmark",
                                 label: model.isSaved(item) ? String(localized: "Save again to refresh price and stock") : String(localized: "Save to my library"),
                                 isOn: model.isSaved(item)) { Task { await model.save(item) } }
                }
            }
        }
        .padding(.vertical, VFSpace.xxs)
        .contextMenu {
            ForEach(item.uses, id: \.self) { u in
                Button(LocalizedStringKey(u.label), systemImage: u.symbol) { Task { await model.use(u, of: item, design: design, pcb: pcb) } }
            }
            if savedTab {
                Button("Edit", systemImage: "pencil") { model.draft = item }
                Button("Delete from Library…", systemImage: "trash", role: .destructive) { askDelete() }
            }
        }
        .fileImporter(isPresented: $attaching, allowedContentTypes: [.data]) { r in
            if case let .success(url) = r { Task { await model.attach(url, to: item) } }
        }
        .confirmSheet($confirm)
    }

    private func askDelete() {
        let files = item.files.count
        confirm = ConfirmRequest(
            title: String(localized: "Delete \(title) from the library?"),
            message: files == 0 ? String(localized: "The saved part is deleted. This cannot be undone.")
                                : String(localized: "The saved part and its \(files) CAD files are deleted from the library folder. This cannot be undone."),
            verb: String(localized: "Delete Part"),
            perform: { Task { await model.remove(item) } })
    }
}

// MARK: Saved

private struct LibrarySavedTab: View {
    @Environment(\.viaFormTheme) private var theme
    let model: LibraryModel
    let design: DesignModel
    let pcb: PCBModel
    @State private var filter = ""

    var body: some View {
        let shown = model.items.filter { it in
            filter.isEmpty || [it.name, it.partNumber, it.manufacturer ?? "", it.notes ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(filter)
        }
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter).vfField()
                Menu {
                    ForEach(model.sources.filter { $0.access == "manual" }) { s in
                        Button(s.name) { var it = LibraryItem(source: s.id); it.domain = s.domain; model.draft = it }
                    }
                } label: { Label("Add Part", systemImage: "plus") }
                .menuStyle(.vfPill)
            }
            .padding(VFSpace.panelPadding)
            if !model.loaded {
                DelayedProgress(label: String(localized: "Reading the library"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                EmptyState(String(localized: "No saved parts"), systemImage: "bookmark",
                           message: String(localized: "Save parts from a search, paste a product link, or add one by hand."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                List(shown) { it in LibraryRow(model: model, item: it, design: design, pcb: pcb, savedTab: true) }
                    .listStyle(.inset)
            }
        }
    }
}

// MARK: Sources

private struct LibrarySourcesTab: View {
    @Environment(\.viaFormTheme) private var theme
    let model: LibraryModel
    @State private var addingRoot = false

    var body: some View {
        List {
            Section("On this Mac") {
                ForEach(model.sources.filter { $0.access == "local" }) { s in LibrarySourceRow(model: model, source: s) }
                ForEach(model.kicadRoots, id: \.self) { r in
                    HStack {
                        Label(r, systemImage: "folder").font(VFFont.small).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        VFIconButton("minus.circle", label: String(localized: "Remove this folder from the list"), role: .destructive) {
                            Task { await model.removeKicadRoot(r) }
                        }
                    }
                }
                Button { addingRoot = true } label: { Label("Add a KiCad Library Folder…", systemImage: "folder.badge.plus") }
                    .buttonStyle(.vfGhost(tint: theme.accentText)).font(VFFont.small)
            }
            Section("Official APIs, with your keys") {
                ForEach(model.sources.filter { $0.access == "api" }) { s in LibrarySourceRow(model: model, source: s) }
            }
            Section("By hand: link, part number and CAD files") {
                ForEach(model.sources.filter { $0.access == "manual" }) { s in LibrarySourceRow(model: model, source: s) }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if !model.loaded { DelayedProgress(label: String(localized: "Reading the sources")) }
        }
        .fileImporter(isPresented: $addingRoot, allowedContentTypes: [.folder]) { r in
            if case let .success(url) = r { Task { await model.setKicadRoots(model.kicadRoots + [url.path]) } }
        }
    }
}

private struct LibrarySourceRow: View {
    @Environment(\.viaFormTheme) private var theme
    let model: LibraryModel
    let source: LibrarySource
    @State private var open = false
    @State private var typed: [String: String] = [:]
    @State private var confirm: ConfirmRequest?
    @Environment(\.openURL) private var openURL

    /// The source's state in a word and a shape (never the colour alone).
    private var status: (VFStatus, String) {
        if !source.enabled { return (.empty, String(localized: "Off")) }
        if source.ready { return (.current, String(localized: "Ready")) }
        return (.stale, source.access == "api" ? String(localized: "No keys") : String(localized: "Not ready"))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: VFSpace.s) {
                Text(source.summary).font(VFFont.small).fixedSize(horizontal: false, vertical: true)
                ForEach(source.caveats ?? [], id: \.self) { c in
                    Label(c, systemImage: "info.circle").font(VFFont.micro).foregroundStyle(theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if let keys = source.keys, !keys.isEmpty {
                    ForEach(keys, id: \.id) { k in
                        let saved = model.hasKey(source, k.id)
                        let title = saved ? String(localized: "\(k.label) (saved; type to replace)")
                                          : (k.optional ? String(localized: "\(k.label) (optional)") : k.label)
                        SecureField(title, text: binding(k.id), prompt: Text(k.placeholder ?? (saved ? String(localized: "Saved") : k.label)))
                            .vfField().font(VFFont.small)
                    }
                    HStack {
                        Button("Save in Keychain") { let t = typed; typed = [:]; Task { await model.setKeys(source, t) } }
                            .vfDisabled(typed.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty },
                                        reason: String(localized: "Type a key first"))
                        if source.ready {
                            Button("Forget Keys…", role: .destructive) { askForget() }
                        }
                    }
                    .buttonStyle(.vfSecondary)
                }
                HStack(spacing: VFSpace.l) {
                    if let u = LibraryModel.web(source.signup) { Button("Get Keys") { openURL(u) } }
                    if let u = LibraryModel.web(source.terms) { Button("Terms") { openURL(u) } }
                }
                .buttonStyle(.vfGhost(tint: theme.accentText)).font(VFFont.small)
            }
            .padding(.vertical, VFSpace.xs)
        } label: {
            HStack {
                VFStatusDot(status: status.0, size: 7, reason: status.1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: VFSpace.xs) {
                        Text(source.name).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                        if source.planned { Text("Planned").font(VFFont.micro).foregroundStyle(theme.inkSecondary) }
                    }
                    Text(source.detail.map { "\(status.1) · \($0)" } ?? status.1)
                        .font(VFFont.micro).foregroundStyle(theme.inkSecondary).lineLimit(1)
                }
                Spacer()
                Toggle(String(localized: "Search \(source.name)"), isOn: Binding(get: { source.enabled }, set: { on in Task { await model.setEnabled(source.id, on) } }))
                    .toggleStyle(.vfSwitch).labelsHidden().fixedSize()
            }
        }
        .confirmSheet($confirm)
    }

    private func askForget() {
        let n = (source.keys ?? []).filter { model.hasKey(source, $0.id) }.count
        confirm = ConfirmRequest(
            title: String(localized: "Forget the \(source.name) keys?"),
            message: String(localized: "\(n) keys are deleted from the Keychain. To search \(source.name) again you will need to paste them from the shop's site."),
            verb: String(localized: "Forget Keys"),
            perform: { Task { await model.forgetKeys(source) } })
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { typed[id] ?? "" }, set: { typed[id] = $0 })
    }
}

// MARK: Editor

/// A part entered by hand or from a pasted link: part number, name, link and notes.
private struct LibraryEditor: View {
    @Environment(\.viaFormTheme) private var theme
    let model: LibraryModel
    let original: LibraryItem
    @State var item: LibraryItem
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(model: LibraryModel, item: LibraryItem) {
        self.model = model
        original = item
        _item = State(initialValue: item)
    }

    private var edited: Bool { item != original }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.l) {
            Text(item.key.isEmpty ? "New Part" : "Edit Part").font(VFFont.title).foregroundStyle(theme.ink)
            Form {
                LabeledContent("Source") {
                    VFMenuPicker(String(localized: "Source"), selection: $item.source, items: model.sources.map(\.id)) { id in
                        model.source(id)?.name ?? id
                    }
                }
                .vfDisabled(!item.key.isEmpty, reason: String(localized: "A saved part keeps its source"))
                TextField("Part number", text: $item.partNumber, prompt: Text("91290A115, B07…, 1005004…"))
                    .vfDisabled(!item.key.isEmpty, reason: String(localized: "A saved part keeps its part number"))
                TextField("Name", text: $item.name)
                TextField("Manufacturer", text: text(\.manufacturer))
                TextField("Link", text: text(\.url), prompt: Text("https://…"))
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                LabeledContent("Kind") {
                    VFMenuPicker(String(localized: "Kind"), selection: $item.domain, items: ["electronics", "mechanical", "both"]) { d in
                        switch d {
                        case "electronics": String(localized: "Electronics")
                        case "mechanical": String(localized: "Mechanical")
                        default: String(localized: "Both")
                        }
                    }
                }
                TextField("Notes", text: text(\.notes), prompt: Text("Price, MOQ, size, where it goes…"), axis: .vertical)
                    .lineLimit(3...6)
            }
            .formStyle(.grouped)
            if let s = model.source(item.source), s.id == "mcmaster" || s.access == "manual" {
                Text("Download the CAD file from the shop's page yourself, then attach it from Saved.")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.vfSecondary).keyboardShortcut(.cancelAction)
                Button("Save Part") {
                    let it = item
                    saving = true
                    Task { if await model.save(it) != nil { dismiss() }; saving = false }
                }
                .buttonStyle(.vfPrimary(loading: saving))
                .keyboardShortcut(.defaultAction)
                .vfDisabled(item.partNumber.trimmingCharacters(in: .whitespaces).isEmpty, reason: String(localized: "Type the part number first"))
            }
        }
        .padding(VFSpace.xl)
        .interactiveDismissDisabled(edited)
        #if os(macOS)
        .frame(width: 440)
        #endif
    }

    private func text(_ kp: WritableKeyPath<LibraryItem, String?>) -> Binding<String> {
        Binding(get: { item[keyPath: kp] ?? "" }, set: { item[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }
}

