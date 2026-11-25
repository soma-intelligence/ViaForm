import SwiftUI

/// The Change Parameters table (B-10), shared by both apps.
/// - `.full`: the Mac sheet, with the columns Parameter, Name, Unit, Expression, Value, Comments,
///   user parameters first and the model parameters folded by feature.
/// - `.compact`: the inspector section and the iPad Items panel, one row per parameter (name,
///   expression, value), the comment under it.
/// Every edit is one engine command through `ParametersModel`; names and expressions complete
/// from the design's parameters.
struct ParametersTable: View {
    enum Style { case full, compact }

    @Environment(\.viaFormTheme) private var theme
    let design: DesignModel
    var style: Style = .compact
    /// The model parameters (feature inputs) as well as the user ones.
    var showsModel = true
    @State private var adding = false

    private var model: ParametersModel { ParametersModel.shared(for: design) }

    var body: some View {
        let p = model
        let _ = design.snapshot.revision
        VStack(alignment: .leading, spacing: VFSpace.s) {
            toolbar(p)
            if adding { AddParameterRow(model: p, compact: style == .compact) { adding = false } }
            if let e = p.error {
                Label(e, systemImage: "exclamationmark.circle.fill")
                    .font(VFFont.small).foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("Error: \(e)"))
            }
            if style == .full { fullTable(p) } else { compactList(p) }
        }
        .environment(\.vfParameters, p.context)
        .onAppear { p.reloadIfNeeded() }
        .onChange(of: design.snapshot.revision) { _, _ in p.reloadIfNeeded() }
        .onChange(of: design.snapshot.undo) { _, _ in p.reloadIfNeeded() }
    }

    private func toolbar(_ p: ParametersModel) -> some View {
        HStack(spacing: VFSpace.s) {
            Button {
                p.clearError()
                adding.toggle()
            } label: {
                Label(String(localized: "User Parameter"), systemImage: "plus")
            }
            .buttonStyle(.vfSecondary)
            .controlSize(.small)
            .help(String(localized: "Add a user parameter"))
            Spacer(minLength: 0)
            Text("\(p.userRows.count) user, \(p.modelRows.count) model")
                .font(VFFont.micro).foregroundStyle(theme.inkTertiary)
        }
    }

    // MARK: Full table (Mac sheet)

    private enum Column {
        static let parameter: CGFloat = 130
        static let name: CGFloat = 110
        static let unit: CGFloat = 44
        static let expression: CGFloat = 170
        static let value: CGFloat = 90
    }

    private func fullTable(_ p: ParametersModel) -> some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: VFSpace.m, verticalSpacing: VFSpace.xs) {
                GridRow {
                    header(String(localized: "Parameter"), Column.parameter)
                    header(String(localized: "Name"), Column.name)
                    header(String(localized: "Unit"), Column.unit)
                    header(String(localized: "Expression"), Column.expression)
                    header(String(localized: "Value"), Column.value)
                    header(String(localized: "Comments"), nil)
                    Color.clear.frame(width: 20, height: 1)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                groupRow(String(localized: "User Parameters"), count: p.userRows.count)
                if p.userRows.isEmpty {
                    GridRow {
                        Text("No user parameters yet. Add one, then type its name in any value field.")
                            .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                            .gridCellColumns(7)
                    }
                }
                ForEach(p.userRows) { r in fullRow(r, p) }
                if showsModel {
                    ForEach(p.modelGroups, id: \.feature) { g in
                        groupRow(g.feature, count: g.rows.count)
                        ForEach(g.rows) { r in fullRow(r, p) }
                    }
                }
            }
            .padding(.vertical, VFSpace.xs)
        }
    }

    private func header(_ t: String, _ w: CGFloat?) -> some View {
        Text(t).font(VFFont.caps).foregroundStyle(theme.inkSecondary)
            .frame(width: w, alignment: .leading)
            .frame(maxWidth: w == nil ? .infinity : nil, alignment: .leading)
    }

    private func groupRow(_ title: String, count: Int) -> some View {
        GridRow {
            HStack(spacing: VFSpace.xs) {
                Text(title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                Text("\(count)").font(VFFont.micro).foregroundStyle(theme.inkTertiary)
            }
            .gridCellColumns(7)
            .padding(.top, VFSpace.s)
        }
    }

    private func fullRow(_ r: ParametersModel.Row, _ p: ParametersModel) -> some View {
        GridRow {
            HStack(spacing: VFSpace.xs) {
                Button { p.setFavorite(r.name, !r.favorite) } label: {
                    Image(systemName: r.favorite ? "star.fill" : "star")
                        .font(VFFont.glyph(10))
                        .foregroundStyle(r.favorite ? theme.accentText : theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .help(r.favorite ? String(localized: "Remove from favourites") : String(localized: "Add to favourites"))
                .accessibilityLabel(Text(r.favorite ? "Unfavourite \(r.name)" : "Favourite \(r.name)"))
                Text(r.owner).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
            }
            .frame(width: Column.parameter, alignment: .leading)
            CommitTextField(String(localized: "Name"), value: r.name) { p.rename(r.name, to: $0) }
                .frame(width: Column.name)
            Text(r.unit.isEmpty ? "-" : r.unit).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                .frame(width: Column.unit, alignment: .leading)
            ExpressionCell(model: p, row: r)
                .frame(width: Column.expression)
            Text(valueText(r)).font(VFFont.row).monospacedDigit()
                .foregroundStyle(r.error == nil ? theme.ink : theme.danger)
                .lineLimit(1)
                .frame(width: Column.value, alignment: .trailing)
                .help(r.error ?? usedByText(r))
            CommitTextField(String(localized: "Comment"), value: r.comment) { p.setComment(r.name, $0) }
                .frame(minWidth: 120, maxWidth: .infinity)
            deleteButton(r, p).frame(width: 20)
        }
    }

    @ViewBuilder private func deleteButton(_ r: ParametersModel.Row, _ p: ParametersModel) -> some View {
        if r.isUser {
            VFIconButton("trash", label: String(localized: "Delete \(r.name)"), size: 11) { p.delete(r.name) }
                .vfDisabled(!r.usedBy.isEmpty, reason: String(localized: "Used by \(r.usedBy.joined(separator: ", "))"))
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func valueText(_ r: ParametersModel.Row) -> String {
        guard r.error == nil, let v = r.shown else { return String(localized: "Error") }
        return VFFormat.value(v, r.vfUnit)
    }

    private func usedByText(_ r: ParametersModel.Row) -> String {
        r.usedBy.isEmpty ? String(localized: "Not used yet") : String(localized: "Used by \(r.usedBy.joined(separator: ", "))")
    }

    // MARK: Compact list (inspector, iPad)

    private func compactList(_ p: ParametersModel) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            if p.userRows.isEmpty {
                Text("No user parameters yet. Add one, then type its name in any value field.")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(p.userRows) { r in compactRow(r, p) }
            if showsModel, !p.modelRows.isEmpty {
                DisclosureGroup {
                    ForEach(p.modelRows) { r in compactRow(r, p) }
                } label: {
                    Text("Model parameters \(p.modelRows.count)").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
            }
        }
    }

    private func compactRow(_ r: ParametersModel.Row, _ p: ParametersModel) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            HStack(spacing: VFSpace.s) {
                if r.isUser {
                    CommitTextField(String(localized: "Name"), value: r.name) { p.rename(r.name, to: $0) }
                        .frame(maxWidth: 110)
                } else {
                    Text(r.name).font(VFFont.row).foregroundStyle(theme.ink).lineLimit(1)
                        .help(r.owner)
                }
                ExpressionCell(model: p, row: r)
                Text(valueText(r)).font(VFFont.small).monospacedDigit()
                    .foregroundStyle(r.error == nil ? theme.inkSecondary : theme.danger)
                    .lineLimit(1).fixedSize()
                    .help(r.error ?? usedByText(r))
            }
            if r.isUser || !r.comment.isEmpty {
                HStack(spacing: VFSpace.s) {
                    Text(r.isUser ? r.owner : r.owner).font(VFFont.micro).foregroundStyle(theme.inkTertiary)
                    CommitTextField(String(localized: "Comment"), value: r.comment, font: VFFont.micro) { p.setComment(r.name, $0) }
                }
            }
        }
        .contextMenu {
            Button(r.favorite ? String(localized: "Remove from favourites") : String(localized: "Add to favourites")) {
                p.setFavorite(r.name, !r.favorite)
            }
            if r.isUser {
                Button(String(localized: "Delete \(r.name)"), role: .destructive) { p.delete(r.name) }
                    .disabled(!r.usedBy.isEmpty)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A text field that sends its value once, on Return or focus loss, and shows the stored value
/// again when the engine refuses it.
struct CommitTextField: View {
    let title: String
    let value: String
    var font: Font = VFFont.row
    let commit: (String) -> String?
    @State private var text = ""
    @FocusState private var focused: Bool

    init(_ title: String, value: String, font: Font = VFFont.row, commit: @escaping (String) -> String?) {
        self.title = title
        self.value = value
        self.font = font
        self.commit = commit
    }

    var body: some View {
        TextField(title, text: $text)
            .labelsHidden()
            .font(font)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            #if os(iOS)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit(send)
            .onAppear { text = value }
            .onChange(of: value) { _, v in if !focused { text = v } }
            .onChange(of: focused) { _, f in if !f { send() } }
            .accessibilityLabel(title)
    }

    private func send() {
        guard text != value else { return }
        if commit(text) != nil { text = value }
    }
}

/// The Expression cell: the stored expression, an fx marker when it names other parameters,
/// completion of names while typing, one `parameters.change` on Return or focus loss.
struct ExpressionCell: View {
    @Environment(\.viaFormTheme) private var theme
    let model: ParametersModel
    let row: ParametersModel.Row
    @State private var text = ""
    @State private var suggestions: [ParametersModel.Suggestion] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            HStack(spacing: VFSpace.xs) {
                if !row.uses.isEmpty {
                    Image(systemName: "function").font(VFFont.glyph(10, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .help(String(localized: "Driven by \(row.uses.joined(separator: ", "))"))
                        .accessibilityLabel(Text("Linked to \(row.uses.joined(separator: ", "))"))
                }
                TextField(String(localized: "Expression"), text: $text)
                    .labelsHidden()
                    .font(VFFont.row).monospacedDigit()
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    #endif
                    .onSubmit(send)
                    .onKeyPress(.tab) {
                        guard let first = suggestions.first else { return .ignored }
                        accept(first)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        text = row.expression
                        suggestions = []
                        return .handled
                    }
                    .accessibilityLabel(Text("Expression of \(row.name)"))
            }
            if focused, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { s in
                        Button { accept(s) } label: {
                            HStack {
                                Text(s.text).font(VFFont.small).foregroundStyle(theme.ink)
                                Spacer(minLength: VFSpace.s)
                                Text(s.detail).font(VFFont.micro).foregroundStyle(theme.inkSecondary).lineLimit(1)
                            }
                            .padding(.horizontal, VFSpace.s).padding(.vertical, VFSpace.xxs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .vfSurface(.floating)
            }
        }
        .onAppear { text = row.expression }
        .onChange(of: row.expression) { _, e in if !focused { text = e } }
        .onChange(of: focused) { _, f in if !f { send() } }
        .onChange(of: text) { _, t in
            suggestions = focused ? NumberField.completions(t, model.context).filter { $0.text != row.name } : []
        }
    }

    private func accept(_ s: ParametersModel.Suggestion) {
        if let w = ParameterContext.trailingWord(text) { text.removeLast(w.count) }
        text += s.text
        suggestions = []
    }

    private func send() {
        suggestions = []
        guard text.trimmingCharacters(in: .whitespaces) != row.expression else { return }
        if model.change(row.name, expression: text) != nil { text = row.expression }
    }
}

/// The inline "+ User Parameter" row: name, unit, expression, comment, then Add.
struct AddParameterRow: View {
    @Environment(\.viaFormTheme) private var theme
    let model: ParametersModel
    var compact = false
    let done: () -> Void
    @State private var name = ""
    @State private var unit = "mm"
    @State private var expression = ""
    @State private var comment = ""

    /// The units a new parameter takes: a length, an angle, a bare number.
    private static let units: [(String, String)] = [("mm", "mm"), ("deg", "deg"), ("", "No unit")]

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: VFSpace.xs))
                             : AnyLayout(HStackLayout(spacing: VFSpace.s))
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            layout {
                TextField(String(localized: "Name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel(Text("New parameter name"))
                Picker(String(localized: "Unit"), selection: $unit) {
                    ForEach(Self.units, id: \.0) { u in Text(LocalizedStringKey(u.1)).tag(u.0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField(String(localized: "Expression"), text: $expression)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel(Text("New parameter expression"))
                TextField(String(localized: "Comment"), text: $comment)
                    .textFieldStyle(.roundedBorder)
            }
            .font(VFFont.row)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { model.clearError(); done() }
                    .buttonStyle(.vfSecondary).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Add")) {
                    if model.add(name: name, expression: expression, unit: unit, comment: comment) == nil { done() }
                }
                .buttonStyle(.vfPrimary).controlSize(.small)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || expression.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(VFSpace.s)
        .vfSurface(.well)
    }
}

/// The Change Parameters window content for the Mac (a sheet over the project window).
struct ChangeParametersSheet: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let design: DesignModel

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.l) {
            HStack {
                Text("Change Parameters").font(VFFont.title).foregroundStyle(theme.ink)
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .buttonStyle(.vfPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            ParametersTable(design: design, style: .full)
        }
        .padding(VFSpace.xl)
        .frame(minWidth: 820, minHeight: 420)
        .background(theme.panel)
    }
}

extension ParametersModel {
    /// One table model per open design, shared by the inspector, the sheet and the fields.
    nonisolated(unsafe) private static let registry = NSMapTable<DesignModel, ParametersModel>.weakToStrongObjects()

    static func shared(for design: DesignModel) -> ParametersModel {
        if let m = registry.object(forKey: design) { return m }
        let m = ParametersModel(design: design)
        registry.setObject(m, forKey: design)
        return m
    }
}

extension View {
    /// Lets every NumberField below link to `design`'s parameters (completion, fx marker).
    /// One line where a design's views are built: `.vfParameterLinks(model)`.
    func vfParameterLinks(_ design: DesignModel) -> some View {
        modifier(ParameterLinks(design: design))
    }
}

private struct ParameterLinks: ViewModifier {
    let design: DesignModel
    func body(content: Content) -> some View {
        let p = ParametersModel.shared(for: design)
        let _ = design.snapshot.revision
        content
            .environment(\.vfParameters, p.context)
            .onAppear { p.reloadIfNeeded() }
            .onChange(of: design.snapshot.revision) { _, _ in p.reloadIfNeeded() }
            .onChange(of: design.snapshot.undo) { _, _ in p.reloadIfNeeded() }
    }
}
