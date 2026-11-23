import SwiftUI
import UniformTypeIdentifiers

/// The Libraries panel: one search over KiCad, standard hardware, the shops' APIs and the saved
/// parts; the saved parts with their CAD files; the sources with their keys (in the Keychain).
/// Shops without an open API are searched in the browser and saved from a pasted link.
struct LibraryView: View {
    @Bindable var model: LibraryModel
    let design: DesignModel
    let pcb: PCBModel
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Libraries", systemImage: "books.vertical").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close")
            }
            .padding(.horizontal, 14).padding(.top, 12)
            Picker("", selection: $model.tab) {
                ForEach(LibraryModel.Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 14).padding(.vertical, 10)
            if let m = model.message {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: model.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.messageIsError ? .orange : .green)
                    Text(m).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.say(nil) } label: { Image(systemName: "xmark").font(.caption) }.buttonStyle(.borderless)
                }
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 14).padding(.bottom, 8)
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
    }
}

// MARK: Search

private struct LibrarySearchTab: View {
    @Bindable var model: LibraryModel
    let design: DesignModel
    let pcb: PCBModel
    @State private var link = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("LM358, M3x12, 608 bearing, stepper motor…", text: $model.query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.search() } }
                if model.searching { ProgressView().controlSize(.small) }
            }
            .padding(8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .padding(14)
            List {
                ForEach(model.hits, id: \.source) { h in
                    Section {
                        if let e = h.error {
                            Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        } else if h.items.isEmpty {
                            Text("Nothing found").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(h.items) { it in LibraryRow(model: model, item: it, design: design, pcb: pcb) }
                    } header: {
                        HStack {
                            Text(h.source == "mine" ? "My saved parts" : model.source(h.source)?.name ?? h.source)
                            Spacer()
                            if h.total > h.items.count { Text("\(h.items.count) of \(h.total)").foregroundStyle(.secondary) }
                        }
                    }
                }
                Section("Search in a shop's own site") {
                    let shops = model.sources.filter { $0.searchUrl != nil && $0.enabled }
                    FlowRow(shops) { s in
                        Button(s.name) { Task { if let u = await model.searchPage(s.id) { openURL(u) } } }
                            .controlSize(.small)
                            .help("Opens \(s.name) in the browser; save a part from it with its link below")
                    }
                    .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section("Save a part from its link") {
                    HStack {
                        TextField("https://www.amazon.com/dp/…, mcmaster.com/…, aliexpress…", text: $link)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(paste)
                        Button("Add", action: paste).disabled(link.isEmpty)
                    }
                    Text("Only the text of the link is read: the page is never fetched.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(data) { content($0) }
        }
    }
}

// MARK: One part

private struct LibraryRow: View {
    let model: LibraryModel
    let item: LibraryItem
    let design: DesignModel
    let pcb: PCBModel
    var savedTab = false
    @State private var attaching = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name.isEmpty ? item.partNumber : item.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 4)
                if model.isSaved(item) && !savedTab { Image(systemName: "bookmark.fill").foregroundStyle(Color.accentColor).font(.caption) }
            }
            Text([item.partNumber, item.manufacturer, model.source(item.source)?.name].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let d = item.description { Text(d).font(.caption).lineLimit(2) }
            HStack(spacing: 10) {
                if let p = item.priceText { Text(p).font(.caption.monospacedDigit()) }
                if let s = item.stock { Text("\(Int(s)) in stock").font(.caption).foregroundStyle(s > 0 ? .green : .orange) }
            }
            if let n = item.notes, savedTab { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            if savedTab && !item.files.isEmpty {
                ForEach(item.files, id: \.path) { f in Label(f.label, systemImage: "doc").font(.caption2).foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                ForEach(item.uses, id: \.self) { u in
                    Button { Task { await model.use(u, of: item, design: design, pcb: pcb) } } label: { Label(u.label, systemImage: u.symbol) }
                }
                Spacer(minLength: 0)
                if let u = LibraryModel.web(item.url) {
                    Button { openURL(u) } label: { Image(systemName: "safari") }.help("Open the product page")
                }
                if let d = LibraryModel.web(item.datasheet) {
                    Button { openURL(d) } label: { Image(systemName: "doc.richtext") }.help("Open the datasheet")
                }
                if savedTab {
                    Button { model.draft = item } label: { Image(systemName: "pencil") }.help("Edit")
                    Button { attaching = true } label: { Image(systemName: "paperclip") }.help("Attach a STEP, .kicad_mod or .kicad_sym file")
                    Button(role: .destructive) { Task { await model.remove(item) } } label: { Image(systemName: "trash") }.help("Remove from the library")
                } else if item.source != "kicad" && item.source != "standard" || !model.isSaved(item) {
                    Button { Task { await model.save(item) } } label: { Image(systemName: model.isSaved(item) ? "bookmark.fill" : "bookmark") }
                        .help(model.isSaved(item) ? "Saved; save again to refresh price and stock" : "Save to my library")
                }
            }
            .buttonStyle(.borderless).controlSize(.small).font(.caption)
        }
        .padding(.vertical, 3)
        .fileImporter(isPresented: $attaching, allowedContentTypes: [.data]) { r in
            if case let .success(url) = r { Task { await model.attach(url, to: item) } }
        }
    }
}

// MARK: Saved

private struct LibrarySavedTab: View {
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
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(model.sources.filter { $0.access == "manual" }) { s in
                        Button(s.name) { var it = LibraryItem(source: s.id); it.domain = s.domain; model.draft = it }
                    }
                } label: { Label("Add Part", systemImage: "plus") }
                .fixedSize()
            }
            .padding(14)
            if shown.isEmpty {
                ContentUnavailableView("No saved parts", systemImage: "bookmark", description: Text("Save parts from a search, paste a product link, or add one by hand."))
            } else {
                List(shown) { it in LibraryRow(model: model, item: it, design: design, pcb: pcb, savedTab: true) }
                    .listStyle(.inset)
            }
        }
    }
}

// MARK: Sources

private struct LibrarySourcesTab: View {
    let model: LibraryModel
    @State private var addingRoot = false

    var body: some View {
        List {
            Section("On this Mac") {
                ForEach(model.sources.filter { $0.access == "local" }) { s in LibrarySourceRow(model: model, source: s) }
                ForEach(model.kicadRoots, id: \.self) { r in
                    HStack {
                        Label(r, systemImage: "folder").font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { Task { await model.setKicadRoots(model.kicadRoots.filter { $0 != r }) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button { addingRoot = true } label: { Label("Add a KiCad Library Folder…", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless).font(.caption)
            }
            Section("Official APIs, with your keys") {
                ForEach(model.sources.filter { $0.access == "api" }) { s in LibrarySourceRow(model: model, source: s) }
            }
            Section("By hand: link, part number and CAD files") {
                ForEach(model.sources.filter { $0.access == "manual" }) { s in LibrarySourceRow(model: model, source: s) }
            }
        }
        .listStyle(.sidebar)
        .fileImporter(isPresented: $addingRoot, allowedContentTypes: [.folder]) { r in
            if case let .success(url) = r { Task { await model.setKicadRoots(model.kicadRoots + [url.path]) } }
        }
    }
}

private struct LibrarySourceRow: View {
    let model: LibraryModel
    let source: LibrarySource
    @State private var open = false
    @State private var typed: [String: String] = [:]
    @Environment(\.openURL) private var openURL

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                Text(source.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                ForEach(source.caveats ?? [], id: \.self) { c in
                    Label(c, systemImage: "info.circle").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let keys = source.keys, !keys.isEmpty {
                    ForEach(keys, id: \.id) { k in
                        let saved = LibraryKeychain.get(source.id, k.id) != nil
                        SecureField(saved ? "\(k.label) (saved; type to replace)" : k.label + (k.optional ? " (optional)" : ""), text: binding(k.id), prompt: Text(k.placeholder ?? (saved ? "•••••• saved" : k.label)))
                            .textFieldStyle(.roundedBorder).font(.caption)
                    }
                    HStack {
                        Button("Save in Keychain") { let t = typed; typed = [:]; Task { await model.setKeys(source, t) } }
                            .disabled(typed.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                        if source.ready { Button("Forget Keys", role: .destructive) { Task { await model.forgetKeys(source) } } }
                    }
                    .controlSize(.small)
                }
                HStack(spacing: 12) {
                    if let u = LibraryModel.web(source.signup) { Button("Get keys") { openURL(u) } }
                    if let u = LibraryModel.web(source.terms) { Button("Terms") { openURL(u) } }
                }
                .linkButtons().font(.caption)
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Circle().fill(!source.enabled ? Color.secondary.opacity(0.4) : source.ready ? .green : .orange).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(source.name).font(.system(size: 12, weight: .medium))
                        if source.planned { Text("planned").font(.caption2).foregroundStyle(.secondary) }
                    }
                    if let d = source.detail { Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { source.enabled }, set: { on in Task { await model.setEnabled(source.id, on) } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { typed[id] ?? "" }, set: { typed[id] = $0 })
    }
}

// MARK: Editor

/// A part entered by hand or from a pasted link: part number, name, link and notes.
private struct LibraryEditor: View {
    let model: LibraryModel
    @State var item: LibraryItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.key.isEmpty ? "New Part" : "Edit Part").font(.headline)
            Form {
                Picker("Source", selection: $item.source) {
                    ForEach(model.sources) { s in Text(s.name).tag(s.id) }
                }
                .disabled(!item.key.isEmpty)
                TextField("Part number", text: $item.partNumber, prompt: Text("91290A115, B07…, 1005004…"))
                    .disabled(!item.key.isEmpty)
                TextField("Name", text: $item.name)
                TextField("Manufacturer", text: text(\.manufacturer))
                TextField("Link", text: text(\.url), prompt: Text("https://…"))
                Picker("Kind", selection: $item.domain) {
                    Text("Electronics").tag("electronics"); Text("Mechanical").tag("mechanical"); Text("Both").tag("both")
                }
                TextField("Notes", text: text(\.notes), prompt: Text("Price, MOQ, size, where it goes…"), axis: .vertical)
                    .lineLimit(3...6)
            }
            .formStyle(.grouped)
            if let s = model.source(item.source), s.id == "mcmaster" || s.access == "manual" {
                Text("Download the CAD file from the shop's page yourself, then attach it from Saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { let it = item; Task { if await model.save(it) != nil { dismiss() } } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(item.partNumber.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        #if os(macOS)
        .frame(width: 440)
        #endif
    }

    private func text(_ kp: WritableKeyPath<LibraryItem, String?>) -> Binding<String> {
        Binding(get: { item[keyPath: kp] ?? "" }, set: { item[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }
}

private extension View {
    /// Link-styled buttons on the Mac; borderless on iPad and iPhone, where `.link` does not exist.
    @ViewBuilder func linkButtons() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }
}
