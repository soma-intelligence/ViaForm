#if os(macOS)
import SwiftUI

// Selection filter surfaces (M-9) and Edit from the canvas (M-10). The filter itself and the
// face to feature lookup are DesignModel's (Shared/Model/SelectionModes.swift); these views
// only show and set them.

/// Words for the selection filter (its title and symbol are SelectionFilter's own).
enum SelectFilterUI {
    static func title(_ f: SelectionFilter) -> String { f.title }
    static func symbol(_ f: SelectionFilter) -> String { f.symbol }

    static func help(_ f: SelectionFilter) -> String {
        switch f {
        case .auto: String(localized: "A click picks what is under the pointer")
        case .body: String(localized: "A click picks whole bodies")
        case .face: String(localized: "A click picks faces only")
        case .edge: String(localized: "A click picks edges only")
        case .sketch: String(localized: "A click picks sketch curves and points only")
        }
    }
}

/// The SELECT ribbon panel (Fusion): the current filter as a big icon whose menu picks another.
struct SelectFilterPanel: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: DesignModel

    var body: some View {
        VStack(spacing: 1) {
            Menu {
                SelectFilterMenuItems(model: model)
            } label: {
                Image(systemName: SelectFilterUI.symbol(model.selectionFilter))
                    .font(VFFont.glyph(18))
                    .foregroundStyle(model.selectionFilter == .auto ? theme.ink : theme.accentText)
                    .frame(width: 36, height: 32)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Selection filter: \(SelectFilterUI.title(model.selectionFilter))"))
            .accessibilityLabel(String(localized: "Selection filter"))
            .accessibilityValue(SelectFilterUI.title(model.selectionFilter))
            Menu {
                SelectFilterMenuItems(model: model)
            } label: {
                VFCaption("Select")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
        }
        .padding(.horizontal, VFSpace.xs)
    }
}

/// The filter choices, ticked on the current one.
struct SelectFilterMenuItems: View {
    @Bindable var model: DesignModel

    var body: some View {
        Picker(String(localized: "Selection Filter"), selection: $model.selectionFilter) {
            ForEach(SelectionFilter.allCases) { f in
                Label(SelectFilterUI.title(f), systemImage: SelectFilterUI.symbol(f)).tag(f)
            }
        }
        .pickerStyle(.inline)
    }
}

/// The status bar's filter control: the filter's symbol and name, a menu to change it.
struct SelectFilterStatusControl: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: DesignModel

    var body: some View {
        Menu {
            SelectFilterMenuItems(model: model)
        } label: {
            Label(SelectFilterUI.title(model.selectionFilter), systemImage: SelectFilterUI.symbol(model.selectionFilter))
                .font(VFFont.small)
                .foregroundStyle(model.selectionFilter == .auto ? theme.inkSecondary : theme.accentText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(SelectFilterUI.help(model.selectionFilter))
        .accessibilityLabel(String(localized: "Selection filter"))
        .accessibilityValue(SelectFilterUI.title(model.selectionFilter))
    }
}

// MARK: Edit from the canvas (M-10)

@MainActor
enum CanvasEdit {
    /// "Edit <feature>" and "Edit <sketch>" for one picked face, when the engine names the
    /// feature that made it. `fallback` opens the generic sheet for a feature with no dialog.
    static func actions(_ model: DesignModel, fallback: @escaping (String) -> Void) -> [PillAction] {
        guard model.selection.count == 1, let pick = model.selection.first, pick.isFace,
              let owner = model.owningFeature(ofFace: pick) else { return [] }
        var out = [PillAction(id: "editFeature", title: String(localized: "Edit \(owner.feature)"), symbol: "slider.horizontal.3") {
            FeatureEditor.edit(model, feature: owner.feature) { fallback(owner.feature) }
        }]
        if let sk = owner.sketch {
            let name = model.snapshot.sketches.first { $0.id == sk }?.name ?? String(localized: "Sketch")
            out.append(PillAction(id: "editSketch", title: String(localized: "Edit \(name)"), symbol: "pencil.line") {
                FeatureEditor.editSketch(model, sketch: sk)
            })
        }
        return out
    }
}
#endif
