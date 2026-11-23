import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

extension UTType {
    static let viaformProject = UTType(filenameExtension: "viaform") ?? .data
}

// MARK: Summary header (both platforms)

/// The figures that matter first: what one build costs and weighs, made against bought, for how
/// many builds. Two rows when the panel is narrow, never a clipped figure.
struct BomSummary: View {
    @Bindable var model: BomModel

    var body: some View {
        let f = BomFigures(model: model)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 26) { f.prefix; f.suffix }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 22) { f.prefix }
                HStack(alignment: .top, spacing: 22) { f.suffix }
            }
        }
    }
}

struct BomFigures: View {
    let model: BomModel

    var body: some View { prefix; suffix }

    private var t: BomTotals { model.rollup.totals }
    private var c: String { model.currency }

    @ViewBuilder var prefix: some View {
        let missing = t.missingPrice + t.unsourced
        figure("Cost per build", BomFormat.money(t.costPerBuild, c) + (t.costComplete ? "" : "+"),
               t.costComplete ? "Made \(BomFormat.money(t.madeCost / Double(max(model.rollup.builds, 1)), c)), bought \(BomFormat.money(t.boughtCost / Double(max(model.rollup.builds, 1)), c))"
                              : "\(missing) line\(missing == 1 ? "" : "s") without a price or cost")
        figure("Mass per build", BomFormat.mass(t.massG) + (t.massComplete ? "" : "+"), "Made \(BomFormat.mass(t.massMadeG)), bought \(BomFormat.mass(t.massBoughtG))")
        part("Made", model.split(made: true))
        part("Bought", model.split(made: false))
    }

    @ViewBuilder var suffix: some View {
        figure("Total, \(model.rollup.builds) build\(model.rollup.builds == 1 ? "" : "s")", BomFormat.money(t.totalCost, c) + (t.costComplete ? "" : "+"),
               "Made \(BomFormat.money(t.madeCost, c)), bought \(BomFormat.money(t.boughtCost, c))")
        figure("Flagged", "\(t.flagged)", "\(t.unsourced) unsourced, \(t.stale) stale", alert: t.flagged > 0)
    }

    private func part(_ title: String, _ s: BomModel.Split) -> some View {
        figure(title, "\(s.lines)", "\(s.parts) part\(s.parts == 1 ? "" : "s") · \(BomFormat.mass(s.mass))" + (s.unpriced > 0 ? " · \(s.unpriced) without cost" : " · \(BomFormat.money(s.cost, c))"))
    }

    private func figure(_ title: String, _ value: String, _ detail: String?, alert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(value.isEmpty ? "0" : value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                .foregroundStyle(alert ? Color.orange : Color.primary)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .fixedSize()
    }
}

/// One chip per supplier: what goes in its cart.
struct BomCarts: View {
    let model: BomModel
    var onExport: (String, String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.rollup.carts) { cart in
                    Menu {
                        Button("Export \(cart.supplier) Cart (CSV)") { onExport("supplier", cart.supplier) }
                        if cart.supplier == "DigiKey" { Button("DigiKey Bulk Add (CSV)") { onExport("digikey", nil) } }
                        if cart.supplier == "Mouser" { Button("Mouser BOM Import (CSV)") { onExport("mouser", nil) } }
                        Button("Group by Supplier") { model.grouping = .supplier }
                    } label: {
                        HStack(spacing: 6) {
                            Text(cart.supplier).font(.system(size: 12, weight: .semibold))
                            Text("\(cart.items.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(BomFormat.money(cart.total, model.currency)).font(.system(size: 12)).monospacedDigit()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
        }
    }
}

/// The flags of a line, as small coloured tags.
struct BomFlagTags: View {
    let flags: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(flags, id: \.self) { f in
                Text(BomFlag.label(f)).font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(color(f).opacity(0.18), in: Capsule())
                    .foregroundStyle(color(f))
            }
        }
    }

    private func color(_ f: String) -> Color {
        switch f {
        case "unsourced", "out_of_stock", "lifecycle", "no_price", "not_in_file": .red
        case _ where BomFlag.quiet.contains(f): .secondary
        default: .orange
        }
    }
}

// MARK: Detail (both platforms)

struct BomDetail: View {
    @Bindable var model: BomModel
    let row: BomRow
    @State private var notes = ""
    @State private var qty = ""

    var body: some View {
        let l = row.line
        let r = row.roll
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title.isEmpty ? row.ref : row.title).font(.headline)
                    Text([row.ref, l.manufacturer ?? "", row.mpn].filter { !$0.isEmpty }.joined(separator: "  ·  ")).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    if !r.flags.isEmpty { BomFlagTags(flags: r.flags).padding(.top, 2) }
                }
                ForEach(r.notes, id: \.self) { n in Label(n, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            Section("Quantity") {
                HStack {
                    Text("Per build")
                    Spacer()
                    TextField("Qty", text: $qty).multilineTextAlignment(.trailing).frame(width: 70)
                        .onSubmit { if let n = Int(qty) { model.setQty(row, n) } }
                }
                LabeledContent("For \(model.rollup.builds) builds", value: "\(r.need)")
                if r.orderQty != r.need, r.orderQty > 0 { LabeledContent("Ordered", value: "\(r.orderQty)") }
                if let p = l.placed { LabeledContent("Placed in the design", value: "\(p)") }
                Toggle("Leave out of the rollup", isOn: Binding(get: { r.excluded }, set: { model.setExcluded(row, $0) }))
            }
            if let made = l.made {
                Section("Made") {
                    LabeledContent("Material", value: made.material ?? "")
                    LabeledContent("Process", value: made.process ?? "")
                    LabeledContent("Cost each", value: made.unitCostUsd == nil ? "No estimate yet" : BomFormat.money(made.unitCostUsd, model.currency))
                    if let u = l.usedBy, u.count > 1 { LabeledContent("Parts", value: u.joined(separator: ", ")) }
                    ForEach(l.meshes ?? [], id: \.self) { m in BomMeshLink(path: m) }
                }
            } else {
                Section("Sourcing") {
                    let offers = l.offers ?? []
                    if offers.isEmpty { Text("No supplier offer yet").foregroundStyle(.secondary) }
                    if offers.count > 1 {
                        Picker("Supplier", selection: Binding(get: { l.supplier ?? "" }, set: { model.setSupplier(row, $0.isEmpty ? nil : $0) })) {
                            Text("Cheapest").tag("")
                            ForEach(offers, id: \.supplier) { Text($0.supplier).tag($0.supplier) }
                        }
                    }
                    ForEach(offers, id: \.self) { o in offer(o, chosen: o.supplier == r.supplier) }
                }
            }
            Section("Figures") {
                LabeledContent("Unit price", value: BomFormat.money(r.unitPrice, model.currency))
                LabeledContent("Extended", value: BomFormat.money(r.extended, model.currency))
                LabeledContent("Per build", value: BomFormat.money(r.perBuildCost, model.currency))
                LabeledContent("Mass each", value: BomFormat.mass(l.massG))
                if let d = l.dimsMm, d.count == 3 { LabeledContent("Size", value: d.map { $0.formatted(.number.precision(.fractionLength(0...1))) }.joined(separator: " x ") + " mm") }
                LabeledContent("Checked on", value: r.checkedOn ?? "never")
            }
            if let specs = l.keySpecs, !specs.isEmpty {
                Section("Key specs") {
                    ForEach(specs.keys.sorted(), id: \.self) { k in LabeledContent(k.replacingOccurrences(of: "_", with: " "), value: specs[k]?.text ?? "") }
                }
            }
            if !(l.alternates ?? []).isEmpty || !(l.usedBy ?? []).isEmpty {
                Section("Use") {
                    if let a = l.alternates, !a.isEmpty { LabeledContent("Alternates", value: a.joined(separator: ", ")) }
                    if let u = l.usedBy, !u.isEmpty { LabeledContent("Used by", value: u.joined(separator: ", ")) }
                    LabeledContent("Category", value: row.category)
                    LabeledContent("Subassembly", value: row.subassembly)
                }
            }
            Section("Notes") {
                if let n = l.notes, !n.isEmpty { Text(n).font(.callout).foregroundStyle(.secondary) }
                TextField("Your notes", text: $notes, axis: .vertical).lineLimit(2...5)
                    .onSubmit { model.setNotes(row, notes) }
                if notes != (l.userNotes ?? "") { Button("Save Notes") { model.setNotes(row, notes) } }
                if let u = BomModel.web(l.datasheetUrl) { Link("Datasheet", destination: u) }
                if let u = BomModel.web(l.cadSource) { Link("CAD model (STEP)", destination: u) }
            }
            if l.origin == "manual" {
                Section { Button("Remove Line", role: .destructive) { model.remove(row) } }
            }
        }
        .formStyle(.grouped)
        .onAppear { sync() }
        .onChange(of: row) { _, _ in sync() }
    }

    private func sync() {
        notes = row.line.userNotes ?? ""
        qty = "\(row.line.perBuild)"
    }

    private func offer(_ o: BomOffer, chosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? Color.accentColor : .secondary)
                Text(o.supplier).fontWeight(.semibold)
                if let s = o.sku, !s.isEmpty { Text(s).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer()
                if let u = BomModel.web(o.url) { Link(destination: u) { Image(systemName: "arrow.up.right.square") } }
            }
            let breaks = o.breaks ?? []
            Text(breaks.isEmpty ? (o.unitPriceUsd.map { "\(BomFormat.money($0, model.currency)) each" } ?? "No price")
                               : breaks.map { "\($0.qty)+ \(BomFormat.money($0.unitPrice, model.currency))" }.joined(separator: "   "))
                .font(.caption).monospacedDigit()
            HStack(spacing: 10) {
                if let m = o.moq, m > 1 { Text(o.pack != nil ? "Packs of \(m)" : "MOQ \(m)") }
                if let s = o.stockNote { Text(s) }
                if let c = o.checkedOn { Text("checked \(c)\(o.via.map { $0 == "file" ? "" : " via \($0)" } ?? "")") }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// A made part's mesh file (STL or 3MF): shown in Finder on the Mac, named on iPad.
struct BomMeshLink: View {
    let path: String
    var body: some View {
        let url = URL(fileURLWithPath: path)
        let exists = FileManager.default.fileExists(atPath: path)
        #if os(macOS)
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Label(url.lastPathComponent, systemImage: url.pathExtension.lowercased() == "3mf" ? "cube.transparent" : "cube")
        }
        .buttonStyle(.link)
        .disabled(!exists)
        .help(exists ? path : "Not on disk: \(path)")
        #else
        Label(url.lastPathComponent, systemImage: "cube").foregroundStyle(exists ? .primary : .secondary)
        #endif
    }
}

// MARK: Actions (both platforms)

struct BomActions: View {
    @Bindable var model: BomModel
    let design: DesignModel
    let pcb: PCBModel
    var importFile: () -> Void
    var export: (String, String?) -> Void
    var saveProject: () -> Void
    var openProject: () -> Void

    var body: some View {
        Menu {
            Button("Import Component File…", systemImage: "doc.badge.plus", action: importFile)
            ForEach(["hand", "drone"], id: \.self) { n in
                if BomModel.assemblyFile(n) != nil {
                    Button("Import \(n.capitalized) Assembly (Made and Bought)", systemImage: "square.stack.3d.down.right") { model.importAssemblies([n]) }
                }
            }
            if let dir = BomModel.componentsFolder {
                Button("Import \(dir.lastPathComponent) (Component Files Only)", systemImage: "tray.and.arrow.down") { model.importFile(dir) }
            }
            Button("Bring In Design Parts", systemImage: "cube") { model.syncDesign(design) }
            Button("Bring In PCB Components", systemImage: "cpu") { model.syncPCB(pcb) }
            Button("Add Line", systemImage: "plus") { model.addLine() }
            Divider()
            ForEach(model.doc.imports, id: \.origin) { i in
                Button("Remove \(i.origin) (\(i.lines) lines)", systemImage: "minus.circle") { model.removeOrigin(i.origin) }
            }
        } label: { Label("Add", systemImage: "plus.rectangle.on.rectangle") }
        Button { Task { await model.refreshPrices() } } label: {
            Label(model.refreshing ? "Checking…" : "Refresh Prices", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(model.refreshing || model.rows.isEmpty)
        .help("Check price and stock of every part number with the distributors whose keys are in the Keychain")
        Menu {
            Button("Whole BOM (CSV)") { export("csv", nil) }
            Button("DigiKey Bulk Add (CSV)") { export("digikey", nil) }.disabled(!model.rollup.carts.contains { $0.supplier == "DigiKey" })
            Button("Mouser BOM Import (CSV)") { export("mouser", nil) }.disabled(!model.rollup.carts.contains { $0.supplier == "Mouser" })
            Divider()
            ForEach(model.rollup.carts) { c in Button("\(c.supplier) Cart (CSV)") { export("supplier", c.supplier) } }
            Divider()
            Button("Save Project with BOM…", action: saveProject)
            Button("Open Project…", action: openProject)
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
    }
}

#if os(macOS)

// MARK: Mac: sortable, grouped table with inline edits

struct BomPanel: View {
    @Bindable var model: BomModel
    let design: DesignModel
    let pcb: PCBModel
    var close: () -> Void
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.rows.isEmpty {
                empty
            } else {
                HSplitView {
                    table.frame(minWidth: 620)
                    Group {
                        if let r = model.selected { BomDetail(model: model, row: r) }
                        else { Text("Select a line").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                    .frame(minWidth: 280, idealWidth: 330, maxWidth: 460)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.selection) { _, _ in model.highlight(design) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .folder], allowsMultipleSelection: true) { r in
            if case let .success(urls) = r { urls.forEach(model.importFile) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One row when it fits; else the title and actions over the table controls. Nothing
            // in either row wraps onto a second line of its own.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { titleGroup; Spacer(minLength: 12); controls; actions }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) { titleGroup; Spacer(minLength: 12); actions }
                    HStack(spacing: 10) { controls; Spacer(minLength: 0) }
                }
            }
            .controlSize(.small)
            BomSummary(model: model)
            if !model.rollup.carts.isEmpty { BomCarts(model: model, onExport: export) }
            if let m = model.message {
                Text(m).font(.system(size: 11)).foregroundStyle(model.messageIsError ? Color.red : Color.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var titleGroup: some View {
        HStack(spacing: 10) {
            Text("Bill of Materials").font(.system(size: 13, weight: .bold)).lineLimit(1).fixedSize()
            if let r = model.doc.refreshedOn { Text("prices checked \(r)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Stepper(value: Binding(get: { model.doc.builds }, set: { model.setBuilds($0) }), in: 1...100_000) {
                HStack(spacing: 4) {
                    Text("Builds").foregroundStyle(.secondary).lineLimit(1)
                    TextField("", value: Binding(get: { model.doc.builds }, set: { model.setBuilds($0) }), format: .number)
                        .frame(width: 54).multilineTextAlignment(.trailing)
                }
            }
            .fixedSize()
            Picker("Group", selection: $model.grouping) { ForEach(BomModel.Grouping.allCases) { Text($0.rawValue).tag($0) } }
                .fixedSize()
            Toggle("Flagged", isOn: $model.onlyFlagged).toggleStyle(.button).fixedSize()
            TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder).frame(width: 150)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            BomActions(model: model, design: design, pcb: pcb, importFile: { importing = true }, export: export, saveProject: saveProject, openProject: openProject)
                .fixedSize()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close the BOM")
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("No lines yet").font(.headline)
            Text("Import a component file, or bring in the design's parts and the PCB's components.").foregroundStyle(.secondary)
            HStack {
                Button("Import Component File…") { importing = true }
                if BomModel.assemblyFile("hand") != nil || BomModel.assemblyFile("drone") != nil {
                    Button("Import Hand and Drone Assemblies") { model.importAssemblies(["hand", "drone"].filter { BomModel.assemblyFile($0) != nil }) }
                } else if let dir = BomModel.componentsFolder { Button("Import \(dir.lastPathComponent)") { model.importFile(dir) } }
                Button("Bring In Design Parts") { model.syncDesign(design) }
                Button("Bring In PCB Components") { model.syncPCB(pcb) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(of: BomRow.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            Group {
                TableColumn("", value: \BomRow.flagCount) { r in
                    let s = BomFlag.severity(r.roll.flags)
                    Image(systemName: s >= 1 ? "exclamationmark.triangle.fill" : (s == -1 ? "info.circle" : "checkmark.circle"))
                        .foregroundStyle(s == 2 ? Color.red : s == 1 ? Color.orange : Color.secondary.opacity(0.5))
                        .help(r.roll.notes.joined(separator: "\n"))
                }
                .width(22)
                TableColumn("Ref", value: \BomRow.ref) { r in Text(r.ref).fontWeight(.medium).foregroundStyle(r.roll.excluded ? .secondary : .primary) }.width(min: 40, ideal: 54)
                TableColumn("Description", value: \BomRow.title) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).lineLimit(1)
                        Text([r.line.manufacturer ?? "", r.mpn].filter { !$0.isEmpty }.joined(separator: " ")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .strikethrough(r.roll.excluded)
                }
                .width(min: 160, ideal: 260)
                TableColumn("Category", value: \BomRow.category) { r in Text(r.category).foregroundStyle(.secondary) }.width(min: 56, ideal: 72)
                TableColumn("Kind", value: \BomRow.kind) { r in Text(r.kind).foregroundStyle(r.roll.made ? Color.purple : .secondary) }.width(52)
                TableColumn("Qty", value: \BomRow.qty) { r in BomQtyCell(model: model, row: r) }.width(48)
                TableColumn("Need", value: \BomRow.need) { r in
                    Text(r.roll.orderQty > r.need ? "\(r.need) (\(r.roll.orderQty))" : "\(r.need)").monospacedDigit()
                        .help(r.roll.orderQty > r.need ? "Ordered \(r.roll.orderQty) for MOQ or a price break" : "")
                }
                .width(min: 44, ideal: 64)
            }
            Group {
                TableColumn("Supplier", value: \BomRow.supplier) { r in Text(r.roll.made ? (r.line.made?.process ?? "Made") : r.supplier).foregroundStyle(r.supplier.isEmpty && !r.roll.made ? Color.red : .primary) }.width(min: 70, ideal: 96)
                TableColumn("Unit", value: \BomRow.unit) { r in Text(BomFormat.money(r.roll.unitPrice, model.currency)).monospacedDigit() }.width(min: 54, ideal: 64)
                TableColumn("Extended", value: \BomRow.extended) { r in Text(BomFormat.money(r.roll.extended, model.currency)).monospacedDigit().fontWeight(.medium) }.width(min: 60, ideal: 76)
                TableColumn("Mass", value: \BomRow.mass) { r in Text(BomFormat.mass(r.roll.massG)).monospacedDigit() }.width(min: 44, ideal: 56)
                TableColumn("Stock", value: \BomRow.checked) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.roll.lifecycle ?? r.roll.stockNote ?? "").lineLimit(1).foregroundStyle(r.roll.lifecycle != nil ? Color.red : .primary)
                        Text(r.roll.checkedOn.map { "checked \($0)" } ?? "never checked").font(.system(size: 10)).foregroundStyle(r.roll.flags.contains("stale") ? Color.orange : .secondary)
                    }
                }
                .width(min: 80, ideal: 120)
                TableColumn("Notes") { r in BomNotesCell(model: model, row: r) }.width(min: 80, ideal: 140)
            }
        } rows: {
            ForEach(model.groups) { g in
                Section {
                    ForEach(g.rows) { TableRow($0) }
                } header: {
                    HStack {
                        Text(model.grouping == .none ? "All lines" : g.name.prefix(1).uppercased() + g.name.dropFirst()).fontWeight(.semibold)
                        Text("\(g.rows.count)").foregroundStyle(.secondary)
                        Spacer()
                        Text(BomFormat.mass(g.mass)).foregroundStyle(.secondary)
                        Text(BomFormat.money(g.extended, model.currency)).monospacedDigit()
                    }
                }
            }
        }
        .contextMenu(forSelectionType: BomRow.ID.self) { ids in
            if let id = ids.first, let r = model.rows.first(where: { $0.id == id }) {
                Button(r.roll.excluded ? "Include in Rollup" : "Leave Out of Rollup") { model.setExcluded(r, !r.roll.excluded) }
                if let u = BomModel.web(r.roll.url) { Link("Open Supplier Page", destination: u) }
                if let u = BomModel.web(r.line.datasheetUrl) { Link("Open Datasheet", destination: u) }
                if r.line.origin == "manual" { Button("Remove Line", role: .destructive) { model.remove(r) } }
            }
        }
    }

    private func export(_ format: String, _ supplier: String?) {
        guard let e = model.export(format, supplier: supplier) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = e.filename
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try e.text.write(to: url, atomically: true, encoding: .utf8)
            model.say("Exported \(url.lastPathComponent)")
        } catch { model.say(error.localizedDescription, error: true) }
    }

    private func saveProject() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (model.doc.name?.isEmpty == false ? model.doc.name! : design.snapshot.name) + ".viaform"
        panel.allowedContentTypes = [.viaformProject]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.saveFromPanel(url, design: design, pcb: pcb)
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.viaformProject]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openFromPanel(url, design: design, pcb: pcb)
    }
}

/// The count per build, typed in place.
struct BomQtyCell: View {
    let model: BomModel
    let row: BomRow
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain).multilineTextAlignment(.trailing).monospacedDigit()
            .foregroundStyle(row.line.qtyOverride != nil ? Color.accentColor : .primary)
            .help(row.line.qtyOverride != nil ? "Changed by hand (the source says \(row.line.qty))" : "Count per build")
            .onSubmit { if let n = Int(text) { model.setQty(row, n) } else { text = "\(row.qty)" } }
            .onAppear { text = "\(row.qty)" }
            .onChange(of: row.qty) { _, q in text = "\(q)" }
    }
}

/// The user's notes, typed in place.
struct BomNotesCell: View {
    let model: BomModel
    let row: BomRow
    @State private var text = ""

    var body: some View {
        TextField("Add a note", text: $text)
            .textFieldStyle(.plain)
            .onSubmit { model.setNotes(row, text) }
            .onAppear { text = row.line.userNotes ?? "" }
            .onChange(of: row.line.userNotes) { _, n in text = n ?? "" }
    }
}

#else

// MARK: iPad and iPhone: list and detail

struct BomPanel: View {
    @Bindable var model: BomModel
    let design: DesignModel
    let pcb: PCBModel
    var close: () -> Void
    @State private var importing = false
    @State private var importingProject = false
    @State private var shared: URL?

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    BomSummary(model: model).listRowBackground(Color.clear)
                    Stepper("Builds: \(model.doc.builds)", value: Binding(get: { model.doc.builds }, set: { model.setBuilds($0) }), in: 1...100_000)
                    Picker("Group by", selection: $model.grouping) { ForEach(BomModel.Grouping.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("Only flagged lines", isOn: $model.onlyFlagged)
                    if !model.rollup.carts.isEmpty { BomCarts(model: model, onExport: export) }
                    if let m = model.message { Text(m).font(.caption).foregroundStyle(model.messageIsError ? Color.red : Color.secondary) }
                }
                ForEach(model.groups) { g in
                    Section {
                        ForEach(g.rows) { r in row(r).tag(r.id) }
                    } header: {
                        HStack {
                            Text(model.grouping == .none ? "All lines" : g.name.prefix(1).uppercased() + g.name.dropFirst())
                            Spacer()
                            Text(BomFormat.money(g.extended, model.currency)).monospacedDigit()
                        }
                    }
                }
            }
            .searchable(text: $model.filter)
            .navigationTitle("Bill of Materials")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: close) }
                ToolbarItemGroup(placement: .primaryAction) {
                    BomActions(model: model, design: design, pcb: pcb, importFile: { importing = true }, export: export, saveProject: saveProject, openProject: { importingProject = true })
                }
            }
        } detail: {
            if let r = model.selected { BomDetail(model: model, row: r).navigationTitle(r.ref) }
            else { Text("Select a line").foregroundStyle(.secondary) }
        }
        .onChange(of: model.selection) { _, _ in model.highlight(design) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: true) { r in
            if case let .success(urls) = r { urls.forEach(model.importFile) }
        }
        .fileImporter(isPresented: $importingProject, allowedContentTypes: [.viaformProject]) { r in
            if case let .success(url) = r { model.openFromPanel(url, design: design, pcb: pcb) }
        }
    }

    private func row(_ r: BomRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.ref).fontWeight(.semibold)
                    Text(r.title).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text("\(r.qty) per build").foregroundStyle(.secondary)
                    Text(r.roll.made ? "Made" : (r.supplier.isEmpty ? "Unsourced" : r.supplier)).foregroundStyle(r.supplier.isEmpty && !r.roll.made ? Color.red : .secondary)
                }
                .font(.caption)
                if !r.roll.flags.isEmpty { BomFlagTags(flags: r.roll.flags) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(BomFormat.money(r.roll.extended, model.currency)).monospacedDigit()
                Text(BomFormat.mass(r.roll.massG)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(r.roll.excluded ? 0.5 : 1)
    }

    /// Exports land in the app's Documents folder (shown in Files).
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private func export(_ format: String, _ supplier: String?) {
        guard let e = model.export(format, supplier: supplier) else { return }
        let url = documents.appendingPathComponent(e.filename)
        do {
            try e.text.write(to: url, atomically: true, encoding: .utf8)
            model.say("Saved \(e.filename) in ViaForm's Documents (Files app)")
        } catch { model.say(error.localizedDescription, error: true) }
    }

    private func saveProject() {
        let name = (model.doc.name?.isEmpty == false ? model.doc.name! : design.snapshot.name) + ".viaform"
        model.saveFromPanel(documents.appendingPathComponent(name), design: design, pcb: pcb)
    }
}

#endif
