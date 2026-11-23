import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
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
            HStack(alignment: .top, spacing: VFSpace.xxl) { f.prefix; f.suffix }
            VStack(alignment: .leading, spacing: VFSpace.l) {
                HStack(alignment: .top, spacing: VFSpace.xl) { f.prefix }
                HStack(alignment: .top, spacing: VFSpace.xl) { f.suffix }
            }
        }
    }
}

struct BomFigures: View {
    @Environment(\.viaFormTheme) private var theme
    let model: BomModel

    var body: some View { prefix; suffix }

    private var t: BomTotals { model.rollup.totals }
    private var c: String { model.currency }
    private var builds: Double { Double(max(model.rollup.builds, 1)) }

    @ViewBuilder var prefix: some View {
        let unpriced = model.unpricedLines
        figure(String(localized: "Cost per build"), BomFormat.money(t.costPerBuild, c) + (t.costComplete ? "" : "+"),
               t.costComplete ? String(localized: "Made \(BomFormat.money(t.madeCost / builds, c)), bought \(BomFormat.money(t.boughtCost / builds, c))")
                              : (unpriced == 1 ? String(localized: "1 line without a price") : String(localized: "\(unpriced) lines without a price")),
               alert: !t.costComplete)
        figure(String(localized: "Mass per build"), BomFormat.mass(t.massG) + (t.massComplete ? "" : "+"),
               String(localized: "Made \(BomFormat.mass(t.massMadeG)), bought \(BomFormat.mass(t.massBoughtG))"))
        part(String(localized: "Made"), model.split(made: true))
        part(String(localized: "Bought"), model.split(made: false))
    }

    @ViewBuilder var suffix: some View {
        let b = model.rollup.builds
        figure(b == 1 ? String(localized: "Total, 1 build") : String(localized: "Total, \(b) builds"),
               BomFormat.money(t.totalCost, c) + (t.costComplete ? "" : "+"),
               String(localized: "Made \(BomFormat.money(t.madeCost, c)), bought \(BomFormat.money(t.boughtCost, c))"))
        figure(String(localized: "Flagged"), "\(t.flagged)", String(localized: "\(t.unsourced) unsourced, \(t.stale) stale"), alert: t.flagged > 0)
    }

    private func part(_ title: String, _ s: BomModel.Split) -> some View {
        let parts = s.parts == 1 ? String(localized: "1 part") : String(localized: "\(s.parts) parts")
        let cost = s.unpriced > 0 ? String(localized: "\(s.unpriced) without a price") : BomFormat.money(s.cost, c)
        return figure(title, "\(s.lines)", "\(parts) · \(BomFormat.mass(s.mass)) · \(cost)")
    }

    private func figure(_ title: String, _ value: String, _ detail: String?, alert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            VFCaption(title)
            HStack(spacing: VFSpace.xs) {
                if alert { Image(systemName: "exclamationmark.triangle.fill").font(VFFont.glyph(13)).accessibilityHidden(true) }
                Text(value).font(VFFont.hud).lineLimit(1)
            }
            .foregroundStyle(alert ? theme.warning : theme.ink)
            if let detail { Text(detail).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1) }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// One chip per supplier: what goes in its cart.
struct BomCarts: View {
    @Environment(\.viaFormTheme) private var theme
    let model: BomModel
    var onExport: (String, String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VFSpace.m) {
                ForEach(model.rollup.carts) { cart in
                    Menu {
                        Button("Export \(cart.supplier) Cart (CSV)") { onExport("supplier", cart.supplier) }
                        if cart.supplier == "DigiKey" { Button("DigiKey Bulk Add (CSV)") { onExport("digikey", nil) } }
                        if cart.supplier == "Mouser" { Button("Mouser BOM Import (CSV)") { onExport("mouser", nil) } }
                        Button("Group by Supplier") { model.grouping = .supplier }
                    } label: {
                        HStack(spacing: VFSpace.s) {
                            Text(cart.supplier).font(VFFont.rowEmphasis)
                            Text(cart.items.count == 1 ? String(localized: "1 line") : String(localized: "\(cart.items.count) lines"))
                                .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                            Text(BomFormat.money(cart.total, model.currency)).font(VFFont.row)
                        }
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, VFSpace.m).padding(.vertical, VFSpace.xs)
                        .background(theme.well, in: Capsule())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
        }
    }
}

/// The flags of a line, as small tags: a word and a symbol, the colour only adds to them.
struct BomFlagTags: View {
    @Environment(\.viaFormTheme) private var theme
    let flags: [String]
    var body: some View {
        HStack(spacing: VFSpace.xs) {
            ForEach(flags, id: \.self) { f in
                Label(BomFlag.label(f), systemImage: symbol(f))
                    .labelStyle(.titleAndIcon)
                    .font(VFFont.micro)
                    .padding(.horizontal, VFSpace.xs + 1).padding(.vertical, 1)
                    .background(color(f).opacity(0.14), in: Capsule())
                    .foregroundStyle(color(f))
            }
        }
    }

    private func symbol(_ f: String) -> String {
        if BomFlag.severe.contains(f) { return "xmark.octagon" }
        if BomFlag.quiet.contains(f) { return "info.circle" }
        return "exclamationmark.triangle"
    }

    private func color(_ f: String) -> Color {
        if BomFlag.severe.contains(f) { return theme.danger }
        if BomFlag.quiet.contains(f) { return theme.inkSecondary }
        return theme.warning
    }
}

/// The line's status: a symbol and a word ("Problem", "Check", "OK"), with the flags and notes
/// in the tooltip; a failed price check says so.
struct BomStatusCell: View {
    @Environment(\.viaFormTheme) private var theme
    let model: BomModel
    let row: BomRow

    var body: some View {
        let s = BomFlag.severity(row.roll.flags)
        let failure = model.refreshFailures[row.id]
        let color = s == 2 ? theme.danger : (s == 1 ? theme.warning : theme.inkSecondary)
        HStack(spacing: VFSpace.xs) {
            if let failure {
                Label(failure.offline ? String(localized: "Offline") : String(localized: "Not checked"),
                      systemImage: failure.offline ? "wifi.slash" : "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(theme.warning)
            } else {
                Label(BomFlag.word(s), systemImage: BomFlag.symbol(s)).foregroundStyle(color)
            }
        }
        .font(VFFont.small)
        .lineLimit(1)
        .help(([failure.map { String(localized: "Price check failed: \($0.reason)") }].compactMap { $0 }
                + row.roll.flags.map(BomFlag.label) + row.roll.notes).joined(separator: "\n"))
    }
}

// MARK: Quantity

/// Parses a typed count: a whole number, 0 or more.
enum BomQty {
    static func parse(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let n = Int(t), n >= 0 else { return nil }
        return n
    }

    static var error: String { String(localized: "Whole number, 0 or more") }
}

// MARK: Detail (both platforms)

struct BomDetail: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: BomModel
    let row: BomRow
    @State private var notes = ""
    @State private var qty = ""
    /// The line the typed text belongs to: a change of line commits it to that line first.
    @State private var editing: String?
    @FocusState private var focus: Field?

    private enum Field { case qty, notes }

    private var qtyError: String? { BomQty.parse(qty) == nil ? BomQty.error : nil }
    private var notesChanged: Bool { notes != (row.line.userNotes ?? "") }

    var body: some View {
        let l = row.line
        let r = row.roll
        Form {
            Section {
                VStack(alignment: .leading, spacing: VFSpace.xs) {
                    Text(row.title.isEmpty ? row.ref : row.title).font(VFFont.title).foregroundStyle(theme.ink)
                    Text([row.ref, l.manufacturer ?? "", row.mpn].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                        .font(VFFont.row).foregroundStyle(theme.inkSecondary).textSelection(.enabled)
                    if !r.flags.isEmpty { BomFlagTags(flags: r.flags).padding(.top, VFSpace.xxs) }
                }
                ForEach(r.notes, id: \.self) { n in
                    Label(n, systemImage: "exclamationmark.triangle").font(VFFont.small).foregroundStyle(theme.warning)
                }
                if let f = model.refreshFailures[row.id] {
                    InlineError(f.offline ? String(localized: "Not checked: offline.") : String(localized: "The price check could not read this part number."),
                                severity: .warning, details: f.reason,
                                retryTitle: String(localized: "Retry Failed"), retry: model.refreshing ? nil : { model.retryFailed() })
                }
            }
            Section("Quantity") {
                VStack(alignment: .trailing, spacing: VFSpace.xxs) {
                    HStack {
                        Text("Per build")
                        Spacer()
                        TextField("Per build", text: $qty)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 80)
                            .focused($focus, equals: .qty)
                            .onSubmit(commitQty)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .onExitCommandIfMac { qty = "\(row.line.perBuild)" }
                    }
                    if let qtyError {
                        Label(qtyError, systemImage: "exclamationmark.circle.fill")
                            .font(VFFont.small).foregroundStyle(theme.danger)
                    }
                }
                LabeledContent(model.rollup.builds == 1 ? String(localized: "For 1 build") : String(localized: "For \(model.rollup.builds) builds"), value: "\(r.need)")
                if r.orderQty != r.need, r.orderQty > 0 { LabeledContent("Ordered", value: "\(r.orderQty)") }
                if let p = l.placed { LabeledContent("Placed in the design", value: "\(p)") }
                Toggle("Leave out of the rollup", isOn: Binding(get: { r.excluded }, set: { model.setExcluded(row, $0) }))
            }
            if let made = l.made {
                Section("Made") {
                    LabeledContent("Material", value: made.material ?? String(localized: "Not set"))
                    LabeledContent("Process", value: made.process ?? String(localized: "Not set"))
                    LabeledContent("Cost each", value: made.unitCostUsd == nil ? String(localized: "No estimate yet") : BomFormat.money(made.unitCostUsd, model.currency))
                    if let u = l.usedBy, u.count > 1 { LabeledContent("Parts", value: u.joined(separator: ", ")) }
                    ForEach(l.meshes ?? [], id: \.self) { m in BomMeshLink(path: m) }
                }
            } else {
                Section("Sourcing") {
                    let offers = l.offers ?? []
                    if offers.isEmpty { Text("No supplier offer yet").foregroundStyle(theme.inkSecondary) }
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
                LabeledContent("Unit price") { MoneyText(value: r.unitPrice, currency: model.currency) }
                LabeledContent("Extended") { MoneyText(value: r.extended, currency: model.currency) }
                LabeledContent("Per build") { MoneyText(value: r.perBuildCost, currency: model.currency) }
                LabeledContent("Mass each", value: BomFormat.mass(l.massG))
                if let d = l.dimsMm, d.count == 3 {
                    LabeledContent("Size", value: d.map { $0.formatted(.number.precision(.fractionLength(0...1))) }.joined(separator: " x ") + " mm")
                }
                LabeledContent("Price checked") {
                    Text(BomFormat.checked(r.checkedOn)).help(BomFormat.fullDate(r.checkedOn))
                }
            }
            if let specs = l.keySpecs, !specs.isEmpty {
                Section("Key specs") {
                    ForEach(specs.keys.sorted(), id: \.self) { k in LabeledContent(k.replacingOccurrences(of: "_", with: " ").capitalized, value: specs[k]?.text ?? "") }
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
                if let n = l.notes, !n.isEmpty { Text(n).font(VFFont.row).foregroundStyle(theme.inkSecondary) }
                TextField("Your notes", text: $notes, axis: .vertical).lineLimit(2...5)
                    .focused($focus, equals: .notes)
                    .onSubmit(commitNotes)
                Button("Save Notes", action: commitNotes)
                    .vfDisabled(!notesChanged, reason: String(localized: "No changes to save"))
                if let u = BomModel.web(l.datasheetUrl) { Link("Datasheet", destination: u) }
                if let u = BomModel.web(l.cadSource) { Link("CAD model (STEP)", destination: u) }
            }
            if l.origin == "manual" {
                Section { Button("Remove Line", role: .destructive) { model.remove(row) } }
            }
        }
        .formStyle(.grouped)
        .onAppear { sync() }
        .onChange(of: row.id) { old, _ in commitPending(to: old); sync() }
        .onChange(of: row.line.perBuild) { _, n in if focus != .qty { qty = "\(n)" } }
        .onChange(of: row.line.userNotes) { _, n in if focus != .notes { notes = n ?? "" } }
        .onChange(of: focus) { old, _ in
            if old == .qty { commitQty() }
            if old == .notes { commitNotes() }
        }
        .onDisappear { commitPending(to: editing) }
    }

    private func sync() {
        notes = row.line.userNotes ?? ""
        qty = "\(row.line.perBuild)"
        editing = row.id
    }

    private func commitQty() {
        if let n = BomQty.parse(qty) { model.setQty(row, n) }
    }

    private func commitNotes() { model.setNotes(row, notes) }

    /// The text typed for the line shown before: written to that line, never to the next one.
    private func commitPending(to id: String?) {
        guard let id, let old = model.rows.first(where: { $0.id == id }) else { return }
        if let n = BomQty.parse(qty), n != old.line.perBuild { model.setQty(old, n) }
        if notes != (old.line.userNotes ?? "") { model.setNotes(old, notes) }
    }

    private func offer(_ o: BomOffer, chosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs + 1) {
            HStack {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? theme.accentText : theme.inkTertiary)
                    .accessibilityLabel(chosen ? Text("Chosen") : Text("Not chosen"))
                Text(o.supplier).font(VFFont.rowEmphasis)
                if let s = o.sku, !s.isEmpty { Text(s).foregroundStyle(theme.inkSecondary).textSelection(.enabled) }
                Spacer()
                if let u = BomModel.web(o.url) {
                    Link(destination: u) { Image(systemName: "arrow.up.right.square") }
                        .accessibilityLabel(Text("Open \(o.supplier)"))
                        .help(String(localized: "Open \(o.supplier)"))
                }
            }
            let breaks = o.breaks ?? []
            Text(breaks.isEmpty ? (o.unitPriceUsd.map { String(localized: "\(BomFormat.money($0, model.currency)) each") } ?? String(localized: "No price"))
                               : breaks.map { "\($0.qty)+ \(BomFormat.money($0.unitPrice, model.currency))" }.joined(separator: "   "))
                .font(VFFont.small)
            HStack(spacing: VFSpace.m) {
                if let m = o.moq, m > 1 { Text(o.pack != nil ? String(localized: "Packs of \(m)") : String(localized: "MOQ \(m)")) }
                if let s = o.stockNote { Text(s) }
                if let c = o.checkedOn {
                    let via = o.via.map { $0 == "file" ? "" : String(localized: " via \($0)") } ?? ""
                    Text("Checked \(BomFormat.checked(c))\(via)").help(BomFormat.fullDate(c))
                }
            }
            .font(VFFont.micro).foregroundStyle(theme.inkSecondary)
        }
    }
}

/// Several lines selected: what they add up to and what can be done to all of them.
struct BomMultiDetail: View {
    @Environment(\.viaFormTheme) private var theme
    let model: BomModel
    let rows: [BomRow]

    var body: some View {
        let removable = model.removable(rows)
        let extended = rows.compactMap(\.roll.extended).reduce(0, +)
        let unpriced = rows.filter { $0.roll.extended == nil }.count
        Form {
            Section {
                Text("\(rows.count) lines selected").font(VFFont.title).foregroundStyle(theme.ink)
                LabeledContent("Extended") { MoneyText(value: extended, currency: model.currency) }
                if unpriced > 0 { LabeledContent("Without a price", value: "\(unpriced)") }
            }
            Section {
                Button("Include in Rollup") { model.setExcluded(rows, false) }
                    .vfDisabled(!rows.contains { $0.roll.excluded }, reason: String(localized: "Every selected line is in the rollup"))
                Button("Leave Out of Rollup") { model.setExcluded(rows, true) }
                    .vfDisabled(!rows.contains { !$0.roll.excluded }, reason: String(localized: "Every selected line is left out already"))
                Button("Copy Rows") { BomClipboard.copy(rows.map(\.tsv)) }
                Button("Copy MPNs") { BomClipboard.copy(rows.map(\.mpn).filter { !$0.isEmpty }) }
            }
            if !removable.isEmpty {
                Section {
                    Button(removable.count == 1 ? String(localized: "Remove 1 Line") : String(localized: "Remove \(removable.count) Lines"), role: .destructive) {
                        model.remove(removable)
                    }
                } footer: {
                    if removable.count < rows.count {
                        Text("Only lines added by hand can be removed; imported lines come back with their file.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Copies text lines to the pasteboard.
enum BomClipboard {
    static func copy(_ lines: [String]) {
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// A made part's mesh file (STL or 3MF): shown in Finder on the Mac, named on iPad.
struct BomMeshLink: View {
    @Environment(\.viaFormTheme) private var theme
    let path: String
    var body: some View {
        let url = URL(fileURLWithPath: path)
        let exists = FileManager.default.fileExists(atPath: path)
        #if os(macOS)
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Label(url.lastPathComponent, systemImage: url.pathExtension.lowercased() == "3mf" ? "cube.transparent" : "cube")
        }
        .buttonStyle(.link)
        .vfDisabled(!exists, reason: String(localized: "Not on disk: \(path)"))
        .help(exists ? path : String(localized: "Not on disk: \(path)"))
        #else
        Label(url.lastPathComponent, systemImage: "cube").foregroundStyle(exists ? theme.ink : theme.inkSecondary)
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
            if !model.doc.imports.isEmpty {
                Divider()
                ForEach(model.doc.imports, id: \.origin) { i in
                    Button(i.lines == 1 ? String(localized: "Remove \(i.origin) (1 line)") : String(localized: "Remove \(i.origin) (\(i.lines) lines)"),
                           systemImage: "minus.circle", role: .destructive) { model.removeOrigin(i.origin) }
                }
            }
        } label: { Label("Add", systemImage: "plus.rectangle.on.rectangle") }
        BomRefreshButton(model: model)
        Menu {
            Button("Whole BOM (CSV)") { export("csv", nil) }
            Button("DigiKey Bulk Add (CSV)") { export("digikey", nil) }
                .vfDisabled(!model.rollup.carts.contains { $0.supplier == "DigiKey" }, reason: String(localized: "No line is bought from DigiKey"))
            Button("Mouser BOM Import (CSV)") { export("mouser", nil) }
                .vfDisabled(!model.rollup.carts.contains { $0.supplier == "Mouser" }, reason: String(localized: "No line is bought from Mouser"))
            if !model.rollup.carts.isEmpty {
                Divider()
                ForEach(model.rollup.carts) { c in Button("\(c.supplier) Cart (CSV)") { export("supplier", c.supplier) } }
            }
            Divider()
            Button("Save Project with BOM…", action: saveProject)
            Button("Open Project…", action: openProject)
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
    }
}

/// Refresh Prices, then a determinate bar with Stop while it checks: one width for both, so the
/// header never jumps.
struct BomRefreshButton: View {
    @Environment(\.viaFormTheme) private var theme
    let model: BomModel
    private var network: VFNetwork { VFNetwork.shared }

    var body: some View {
        Group {
            if model.refreshing {
                HStack(spacing: VFSpace.s) {
                    ProgressView(value: Double(model.refreshDone), total: Double(max(model.refreshTotal, 1)))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Checking prices")
                        .accessibilityValue(Text("\(model.refreshDone) of \(model.refreshTotal)"))
                    Text("\(model.refreshDone) of \(model.refreshTotal)").font(VFFont.micro).foregroundStyle(theme.inkSecondary)
                        .fixedSize()
                    Button("Stop") { model.cancelRefresh() }
                }
            } else {
                Button { model.refreshPrices() } label: {
                    Label(network.online ? String(localized: "Refresh Prices") : String(localized: "Offline"),
                          systemImage: network.online ? "arrow.triangle.2.circlepath" : "wifi.slash")
                        .frame(maxWidth: .infinity)
                }
                .vfDisabled(model.rows.isEmpty || !network.online,
                            reason: model.rows.isEmpty ? String(localized: "Add lines first") : String(localized: "Offline: prices are checked once the network is back"))
                .help("Check price and stock of every part number with the distributors whose keys are in the Keychain")
            }
        }
        .frame(width: 190)
    }
}

/// Under the header: what runs, the last price check and the last error.
struct BomStatusLine: View {
    @Environment(\.viaFormTheme) private var theme
    let model: BomModel

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            HStack(spacing: VFSpace.m) {
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
                if let s = model.refreshSummary, !model.refreshing {
                    Label(s.text, systemImage: s.failed.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(VFFont.small)
                        .foregroundStyle(s.failed.isEmpty ? theme.inkSecondary : theme.warning)
                    if !model.refreshFailures.isEmpty {
                        Button("Retry Failed") { model.retryFailed() }.font(VFFont.small)
                    }
                }
                if let n = model.notice {
                    Label(n.text, systemImage: "checkmark.circle").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
            }
            if let m = model.message {
                InlineError(m, severity: model.messageIsError ? .error : .warning, dismiss: { model.say(nil) })
            }
        }
    }
}

/// The panel's toasts: removals with Undo, saves and exports with Reveal (Mac). Without a toast
/// host the notice stays in the status line.
private struct BomToasts: ViewModifier {
    @Environment(\.vfToasts) private var toasts
    let model: BomModel

    func body(content: Content) -> some View {
        content.onChange(of: model.notice) { _, n in
            guard let n, let toasts else { return }
            model.notice = nil
            if n.undo {
                toasts.show(n.text, actionTitle: String(localized: "Undo")) { model.undo() }
            } else if let url = n.reveal {
                #if os(macOS)
                toasts.show(n.text, actionTitle: String(localized: "Reveal")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                #else
                _ = url
                toasts.show(n.text)
                #endif
            } else {
                toasts.show(n.text)
            }
        }
    }
}

private extension View {
    func bomToasts(_ model: BomModel) -> some View { modifier(BomToasts(model: model)) }

    /// Escape reverts a field on the Mac.
    @ViewBuilder func onExitCommandIfMac(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

#if os(macOS)

// MARK: Mac: sortable, grouped table with inline edits

struct BomPanel: View {
    @Environment(\.viaFormTheme) private var theme
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
                        else if model.selection.count > 1 { BomMultiDetail(model: model, rows: model.selectedRows) }
                        else { EmptyState(String(localized: "Select a line"), systemImage: "list.bullet.rectangle",
                                          message: String(localized: "Its sourcing, figures and notes show here. Select several to change them together.")) }
                    }
                    .frame(minWidth: 280, idealWidth: 330, maxWidth: 460)
                }
            }
        }
        .background(theme.panel)
        .onChange(of: model.selection) { _, _ in model.highlight(design) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .folder], allowsMultipleSelection: true) { r in
            if case let .success(urls) = r { urls.forEach(model.importFile) }
        }
        .bomToasts(model)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: VFSpace.m) {
            // One row when it fits; else the title and actions over the table controls. Nothing
            // in either row wraps onto a second line of its own.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: VFSpace.m) { titleGroup; Spacer(minLength: VFSpace.l); controls; actions }
                VStack(alignment: .leading, spacing: VFSpace.m) {
                    HStack(spacing: VFSpace.m) { titleGroup; Spacer(minLength: VFSpace.l); actions }
                    HStack(spacing: VFSpace.m) { controls; Spacer(minLength: 0) }
                }
            }
            .controlSize(.small)
            BomSummary(model: model)
            if !model.rollup.carts.isEmpty { BomCarts(model: model, onExport: export) }
            BomStatusLine(model: model)
        }
        .padding(.horizontal, VFSpace.panelPadding).padding(.vertical, VFSpace.m)
    }

    private var titleGroup: some View {
        HStack(spacing: VFSpace.m) {
            Text("Bill of Materials").font(VFFont.title).foregroundStyle(theme.ink).lineLimit(1).fixedSize()
            if let r = model.doc.refreshedOn {
                Text("Prices checked \(BomFormat.checked(r))").font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1).fixedSize()
                    .help(BomFormat.fullDate(r))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: VFSpace.m) {
            Stepper(value: Binding(get: { model.doc.builds }, set: { model.setBuilds($0) }), in: 1...100_000) {
                HStack(spacing: VFSpace.xs) {
                    Text("Builds").foregroundStyle(theme.inkSecondary).lineLimit(1)
                    TextField("Builds", value: Binding(get: { model.doc.builds }, set: { model.setBuilds($0) }), format: .number)
                        .labelsHidden()
                        .frame(width: 54).multilineTextAlignment(.trailing)
                }
            }
            .fixedSize()
            Picker("Group", selection: $model.grouping) { ForEach(BomModel.Grouping.allCases) { Text($0.title).tag($0) } }
                .fixedSize()
            Toggle("Flagged", isOn: $model.onlyFlagged).toggleStyle(.button).fixedSize()
            TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder).frame(width: 150)
        }
    }

    private var actions: some View {
        HStack(spacing: VFSpace.m) {
            BomActions(model: model, design: design, pcb: pcb, importFile: { importing = true }, export: export, saveProject: saveProject, openProject: openProject)
                .fixedSize()
            VFIconButton("xmark", label: String(localized: "Close the Bill of Materials"), action: close)
        }
    }

    private var empty: some View {
        VStack(spacing: VFSpace.l) {
            if let busy = model.busy {
                DelayedProgress(label: busy)
            } else {
                EmptyState(String(localized: "No lines yet"), systemImage: "list.bullet.rectangle",
                           message: String(localized: "Import a component file, or bring in the design's parts and the board's components."),
                           actionTitle: String(localized: "Import Component File…")) { importing = true }
                HStack {
                    if BomModel.assemblyFile("hand") != nil || BomModel.assemblyFile("drone") != nil {
                        Button("Import Hand and Drone Assemblies") { model.importAssemblies(["hand", "drone"].filter { BomModel.assemblyFile($0) != nil }) }
                    } else if let dir = BomModel.componentsFolder { Button("Import \(dir.lastPathComponent)") { model.importFile(dir) } }
                    Button("Bring In Design Parts") { model.syncDesign(design) }
                    Button("Bring In PCB Components") { model.syncPCB(pcb) }
                }
                .buttonStyle(.vfSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(of: BomRow.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            Group {
                TableColumn("Status", value: \BomRow.flagCount) { r in BomStatusCell(model: model, row: r) }
                    .width(min: 74, ideal: 92)
                TableColumn("Ref", value: \BomRow.ref) { r in
                    Text(r.ref).fontWeight(.medium).foregroundStyle(r.roll.excluded ? theme.inkSecondary : theme.ink)
                }
                .width(min: 40, ideal: 54)
                TableColumn("Description", value: \BomRow.title) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).lineLimit(1)
                        Text([r.line.manufacturer ?? "", r.mpn].filter { !$0.isEmpty }.joined(separator: " ")).font(VFFont.micro).foregroundStyle(theme.inkSecondary).lineLimit(1)
                    }
                    .strikethrough(r.roll.excluded)
                    .help(r.roll.excluded ? String(localized: "Left out of the rollup") : "")
                }
                .width(min: 160, ideal: 260)
                TableColumn("Category", value: \BomRow.category) { r in Text(r.category).foregroundStyle(theme.inkSecondary) }.width(min: 56, ideal: 72)
                TableColumn("Kind", value: \BomRow.kind) { r in Text(r.kind).foregroundStyle(r.roll.made ? theme.ink : theme.inkSecondary) }.width(min: 52, ideal: 60)
                TableColumn("Qty", value: \BomRow.qty) { r in BomQtyCell(model: model, row: r) }.width(min: 48, ideal: 56)
                TableColumn("Need", value: \BomRow.need) { r in
                    Text(r.roll.orderQty > r.need ? "\(r.need) (\(r.roll.orderQty))" : "\(r.need)").monospacedDigit()
                        .help(r.roll.orderQty > r.need ? String(localized: "Ordered \(r.roll.orderQty) for MOQ or a price break") : "")
                }
                .width(min: 44, ideal: 64)
            }
            Group {
                TableColumn("Supplier", value: \BomRow.supplier) { r in
                    if r.roll.made {
                        Text(r.line.made?.process ?? String(localized: "Made"))
                    } else if r.supplier.isEmpty {
                        Label("Unsourced", systemImage: "xmark.octagon").foregroundStyle(theme.danger)
                    } else {
                        Text(r.supplier)
                    }
                }
                .width(min: 70, ideal: 96)
                TableColumn("Unit", value: \BomRow.unit) { r in MoneyText(value: r.roll.unitPrice, currency: model.currency) }.width(min: 60, ideal: 72)
                TableColumn("Extended", value: \BomRow.extended) { r in MoneyText(value: r.roll.extended, currency: model.currency).fontWeight(.medium) }.width(min: 64, ideal: 80)
                TableColumn("Mass", value: \BomRow.mass) { r in
                    Text(BomFormat.mass(r.roll.massG)).monospacedDigit().foregroundStyle(r.roll.massG == nil ? theme.inkTertiary : theme.ink)
                }
                .width(min: 44, ideal: 60)
                TableColumn("Stock", value: \BomRow.checked) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        if let life = r.roll.lifecycle {
                            Label(life, systemImage: "xmark.octagon").lineLimit(1).foregroundStyle(theme.danger)
                        } else {
                            Text(r.roll.stockNote ?? "").lineLimit(1)
                        }
                        let stale = r.roll.flags.contains("stale")
                        Label(r.roll.checkedOn == nil ? String(localized: "Never checked") : String(localized: "Checked \(BomFormat.checked(r.roll.checkedOn))"),
                              systemImage: stale ? "clock.badge.exclamationmark" : "clock")
                            .font(VFFont.micro).foregroundStyle(stale ? theme.warning : theme.inkSecondary)
                            .help(BomFormat.fullDate(r.roll.checkedOn) + (stale ? String(localized: " (stale)") : ""))
                    }
                }
                .width(min: 90, ideal: 130)
                TableColumn("Notes") { r in BomNotesCell(model: model, row: r) }.width(min: 80, ideal: 140)
            }
        } rows: {
            ForEach(model.groups) { g in
                Section {
                    ForEach(g.rows) { TableRow($0) }
                } header: {
                    HStack {
                        Text(g.name.prefix(1).uppercased() + g.name.dropFirst()).fontWeight(.semibold)
                        Text("\(g.rows.count)").foregroundStyle(theme.inkSecondary)
                        Spacer()
                        Text(BomFormat.mass(g.mass)).foregroundStyle(theme.inkSecondary)
                        if g.unpriced > 0 {
                            Text(g.unpriced == 1 ? String(localized: "1 without a price") : String(localized: "\(g.unpriced) without a price"))
                                .foregroundStyle(theme.warning)
                        }
                        MoneyText(value: g.extended, currency: model.currency)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: BomRow.ID.self) { ids in
            let rows = model.rows.filter { ids.contains($0.id) }
            if !rows.isEmpty { menu(rows) }
        }
        .copyable(model.selectedRows.map(\.tsv))
        .onDeleteCommand { model.remove(model.selectedRows) }
    }

    @ViewBuilder private func menu(_ rows: [BomRow]) -> some View {
        if rows.contains(where: { $0.roll.excluded }) {
            Button(rows.count == 1 ? String(localized: "Include in Rollup") : String(localized: "Include \(rows.count) Lines in Rollup")) { model.setExcluded(rows, false) }
        }
        if rows.contains(where: { !$0.roll.excluded }) {
            Button(rows.count == 1 ? String(localized: "Leave Out of Rollup") : String(localized: "Leave \(rows.count) Lines Out of Rollup")) { model.setExcluded(rows, true) }
        }
        Divider()
        Button(rows.count == 1 ? String(localized: "Copy MPN") : String(localized: "Copy \(rows.count) MPNs")) { BomClipboard.copy(rows.map(\.mpn).filter { !$0.isEmpty }) }
            .vfDisabled(rows.allSatisfy { $0.mpn.isEmpty }, reason: String(localized: "No part number on these lines"))
        Button(rows.count == 1 ? String(localized: "Copy Row") : String(localized: "Copy \(rows.count) Rows")) { BomClipboard.copy(rows.map(\.tsv)) }
        if rows.count == 1, let r = rows.first {
            if let u = BomModel.web(r.roll.url) { Link("Open Supplier Page", destination: u) }
            if let u = BomModel.web(r.line.datasheetUrl) { Link("Open Datasheet", destination: u) }
        }
        let removable = model.removable(rows)
        if !removable.isEmpty {
            Divider()
            Button(removable.count == 1 ? String(localized: "Remove Line") : String(localized: "Remove \(removable.count) Lines"), role: .destructive) {
                model.remove(removable)
            }
        }
    }

    private func export(_ format: String, _ supplier: String?) {
        Task {
            guard let e = await model.export(format, supplier: supplier) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = e.filename
            panel.allowedContentTypes = [.commaSeparatedText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try e.text.write(to: url, atomically: true, encoding: .utf8)
                model.notify(String(localized: "Exported \(url.lastPathComponent)"), reveal: url)
            } catch { model.say(error.localizedDescription, error: true) }
        }
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

/// The count per build, typed in place: a whole number, 0 or more. A wrong entry stays in the
/// field with the reason beside it (never a silent revert); Return or leaving the field commits,
/// Escape reverts.
struct BomQtyCell: View {
    @Environment(\.viaFormTheme) private var theme
    let model: BomModel
    let row: BomRow
    @State private var text = ""
    @FocusState private var focused: Bool

    private var invalid: Bool { BomQty.parse(text) == nil }

    var body: some View {
        HStack(spacing: VFSpace.xxs) {
            if invalid {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(theme.danger)
                    .help(BomQty.error).accessibilityLabel(BomQty.error)
            }
            TextField("Quantity", text: $text)
                .labelsHidden()
                .textFieldStyle(.plain).multilineTextAlignment(.trailing).monospacedDigit()
                .foregroundStyle(invalid ? theme.danger : (row.line.qtyOverride != nil ? theme.accentText : theme.ink))
                .help(invalid ? BomQty.error
                              : (row.line.qtyOverride != nil ? String(localized: "Changed by hand (the source says \(row.line.qty))") : String(localized: "Count per build")))
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { text = "\(row.qty)" }
        }
        .onAppear { text = "\(row.qty)" }
        .onChange(of: row.qty) { _, q in if !focused { text = "\(q)" } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        if let n = BomQty.parse(text) { model.setQty(row, n) }
    }
}

/// The user's notes, typed in place; leaving the field saves them.
struct BomNotesCell: View {
    let model: BomModel
    let row: BomRow
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Add a note", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { model.setNotes(row, text) }
            .onExitCommand { text = row.line.userNotes ?? "" }
            .onAppear { text = row.line.userNotes ?? "" }
            .onChange(of: row.line.userNotes) { _, n in if !focused { text = n ?? "" } }
            .onChange(of: focused) { _, f in if !f { model.setNotes(row, text) } }
    }
}

#else

// MARK: iPad and iPhone: list and detail

struct BomPanel: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: BomModel
    let design: DesignModel
    let pcb: PCBModel
    var close: () -> Void
    @State private var importing = false
    @State private var importingProject = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    BomSummary(model: model).listRowBackground(Color.clear)
                    Stepper("Builds: \(model.doc.builds)", value: Binding(get: { model.doc.builds }, set: { model.setBuilds($0) }), in: 1...100_000)
                    Picker("Group by", selection: $model.grouping) { ForEach(BomModel.Grouping.allCases) { Text($0.title).tag($0) } }
                    Toggle("Only flagged lines", isOn: $model.onlyFlagged)
                    if !model.rollup.carts.isEmpty { BomCarts(model: model, onExport: export) }
                    BomStatusLine(model: model)
                }
                if model.rows.isEmpty {
                    Section {
                        if let busy = model.busy {
                            DelayedProgress(label: busy)
                        } else {
                            EmptyState(String(localized: "No lines yet"), systemImage: "list.bullet.rectangle",
                                       message: String(localized: "Import a component file, or bring in the design's parts and the board's components."),
                                       actionTitle: String(localized: "Import Component File…")) { importing = true }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(model.groups) { g in
                    Section {
                        ForEach(g.rows) { r in
                            row(r).tag(r.id)
                                .contextMenu { menu([r]) }
                                .swipeActions {
                                    if r.line.origin == "manual" {
                                        Button("Remove", systemImage: "trash", role: .destructive) { model.remove(r) }
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text(g.name.prefix(1).uppercased() + g.name.dropFirst())
                            Spacer()
                            MoneyText(value: g.extended, currency: model.currency)
                        }
                    }
                }
            }
            .searchable(text: $model.filter)
            .navigationTitle("Bill of Materials")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
                ToolbarItemGroup(placement: .primaryAction) {
                    BomActions(model: model, design: design, pcb: pcb, importFile: { importing = true }, export: export, saveProject: saveProject, openProject: { importingProject = true })
                }
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                        .vfDisabled(!model.canUndo, reason: String(localized: "Nothing to undo"))
                    Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                        .vfDisabled(!model.canRedo, reason: String(localized: "Nothing to redo"))
                }
            }
        } detail: {
            if let r = model.selected { BomDetail(model: model, row: r).navigationTitle(r.ref) }
            else if model.selection.count > 1 { BomMultiDetail(model: model, rows: model.selectedRows) }
            else { EmptyState(String(localized: "Select a line"), systemImage: "list.bullet.rectangle") }
        }
        .onChange(of: model.selection) { _, _ in model.highlight(design) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: true) { r in
            if case let .success(urls) = r { urls.forEach(model.importFile) }
        }
        .fileImporter(isPresented: $importingProject, allowedContentTypes: [.viaformProject]) { r in
            if case let .success(url) = r { model.openFromPanel(url, design: design, pcb: pcb) }
        }
        .bomToasts(model)
    }

    @ViewBuilder private func menu(_ rows: [BomRow]) -> some View {
        if let r = rows.first {
            Button(r.roll.excluded ? "Include in Rollup" : "Leave Out of Rollup") { model.setExcluded(rows, !r.roll.excluded) }
            Button("Copy MPN", systemImage: "doc.on.doc") { BomClipboard.copy(rows.map(\.mpn).filter { !$0.isEmpty }) }
            Button("Copy Row", systemImage: "doc.on.doc") { BomClipboard.copy(rows.map(\.tsv)) }
            if r.line.origin == "manual" {
                Button("Remove Line", systemImage: "trash", role: .destructive) { model.remove(rows) }
            }
        }
    }

    private func row(_ r: BomRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: VFSpace.xxs) {
                HStack(spacing: VFSpace.s) {
                    Text(r.ref).font(VFFont.rowEmphasis)
                    Text(r.title).font(VFFont.row).lineLimit(1)
                }
                HStack(spacing: VFSpace.s) {
                    Text("\(r.qty) per build").foregroundStyle(theme.inkSecondary)
                    if r.roll.made {
                        Text("Made").foregroundStyle(theme.inkSecondary)
                    } else if r.supplier.isEmpty {
                        Label("Unsourced", systemImage: "xmark.octagon").foregroundStyle(theme.danger)
                    } else {
                        Text(r.supplier).foregroundStyle(theme.inkSecondary)
                    }
                    if r.roll.excluded { Text("Left out").foregroundStyle(theme.inkSecondary) }
                }
                .font(VFFont.small)
                if !r.roll.flags.isEmpty { BomFlagTags(flags: r.roll.flags) }
                if model.refreshFailures[r.id] != nil { BomStatusCell(model: model, row: r) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: VFSpace.xxs) {
                MoneyText(value: r.roll.extended, currency: model.currency).font(VFFont.row)
                Text(BomFormat.mass(r.roll.massG)).font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
        }
        .opacity(r.roll.excluded ? 0.55 : 1)
        .frame(minHeight: VFSize.touchRow)
    }

    /// Exports land in the app's Documents folder (shown in Files).
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private func export(_ format: String, _ supplier: String?) {
        Task {
            guard let e = await model.export(format, supplier: supplier) else { return }
            let url = documents.appendingPathComponent(e.filename)
            do {
                try e.text.write(to: url, atomically: true, encoding: .utf8)
                model.notify(String(localized: "Saved \(e.filename) in ViaForm's Documents (Files app)"))
            } catch { model.say(error.localizedDescription, error: true) }
        }
    }

    private func saveProject() {
        let name = (model.doc.name?.isEmpty == false ? model.doc.name! : design.snapshot.name) + ".viaform"
        model.saveFromPanel(documents.appendingPathComponent(name), design: design, pcb: pcb)
    }
}

#endif
