#if os(macOS)
import SwiftUI

/// "SolidWorks extras": the behaviours ViaForm took from SolidWorks that Fusion does not have,
/// behind one setting, off by default so the Mac app works as Fusion does. Today: the
/// confirmation corner under the view cube (M-18) and the contextual S bar over the toolbox
/// search (M-15). With the setting off, S opens the plain toolbox search.
/// `--solidworks-extras` turns it on for one launch (captures and tests).
enum SolidWorksExtras {
    static let storageKey = "viaform.desk.solidworksExtras"
    static let launchFlag = "--solidworks-extras"

    static var on: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag) || UserDefaults.standard.bool(forKey: storageKey)
    }
}

/// The Settings switch (General pane).
struct SolidWorksExtrasToggle: View {
    @AppStorage(SolidWorksExtras.storageKey) private var on = false

    var body: some View {
        Section {
            Toggle("SolidWorks extras", isOn: $on)
                .toggleStyle(.vfSwitch)
        } footer: {
            Text("Adds the confirmation corner under the view cube and the S key's tool grid above the search.")
                .font(VFFont.small)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
