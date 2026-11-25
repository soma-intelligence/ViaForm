import SwiftUI
#if os(macOS)
import AppKit
#endif

// Privacy settings (UI-UX-AUDIT P2-23, decision D-23): usage reporting opt-in (off, and nothing
// is sent today), recent projects, and where ViaForm keeps its files.

enum PrivacySettings {
    /// Off by default. ViaForm has no reporting code today: the switch records the choice only.
    static let telemetryKey = "viaform.privacy.telemetry"

    /// Where ViaForm keeps the files it writes on its own (not the projects the reader saves).
    struct Place: Identifiable {
        let id: String
        let title: String
        let detail: String
        let url: URL
    }

    static var places: [Place] {
        let fm = FileManager.default
        var out: [Place] = []
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let root = support.appendingPathComponent("ViaForm", isDirectory: true)
            out.append(Place(id: "support", title: String(localized: "App Data"),
                             detail: String(localized: "Autosaved pipelines, the part library and simulation loads."),
                             url: root))
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let id = Bundle.main.bundleIdentifier ?? "ViaForm"
            out.append(Place(id: "caches", title: String(localized: "Caches"),
                             detail: String(localized: "Rebuilt when needed. Safe to delete while ViaForm is closed."),
                             url: caches.appendingPathComponent(id, isDirectory: true)))
        }
        #if os(iOS)
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            out.append(Place(id: "documents", title: String(localized: "Projects"),
                             detail: String(localized: "Shown in the Files app under On My iPad, ViaForm."),
                             url: docs))
        }
        #endif
        return out
    }

    /// The path with the home folder written as ~.
    static func shortPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let p = url.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

/// The Privacy settings, as Form sections (Mac Settings tab, iPad browser sheet).
struct PrivacySettingsSections: View {
    @AppStorage(PrivacySettings.telemetryKey) private var telemetry = false
    @State private var confirm: ConfirmRequest?
    @State private var cleared = false

    var body: some View {
        Section {
            Toggle("Share Anonymous Usage Data", isOn: $telemetry)
                .toggleStyle(.vfSwitch)
        } header: {
            Text("Usage Data")
        } footer: {
            Text("Off unless you turn it on. This version of ViaForm has no usage reporting, so nothing is sent, whatever this says. If reporting is added, it would send only the app and system version, which stages and commands you use and how long jobs take. Never your designs, file names or account. Crash reports go through Apple and follow System Settings, Privacy and Security, Analytics.")
                .font(VFFont.small)
                .foregroundStyle(.secondary)
        }
        #if os(macOS)
        Section {
            LabeledContent {
                Button("Clear Recent Projects…") {
                    confirm = ConfirmRequest(
                        title: String(localized: "Clear recent projects?"),
                        message: String(localized: "The list on the start window and in File, Open Recent is emptied. The project files stay where they are."),
                        verb: String(localized: "Clear List"), destructive: true,
                        perform: {
                            NSDocumentController.shared.clearRecentDocuments(nil)
                            cleared = true
                        })
                }
                .buttonStyle(.vfSecondary)
                .vfDisabled(NSDocumentController.shared.recentDocumentURLs.isEmpty && !cleared,
                            reason: String(localized: "There are no recent projects."))
            } label: {
                Text("Recent Projects")
                if cleared { Text("Cleared.") }
            }
        }
        #endif
        Section {
            ForEach(PrivacySettings.places) { place in
                LabeledContent {
                    #if os(macOS)
                    Button("Show in Finder") { reveal(place.url) }
                        .buttonStyle(.vfSecondary)
                    #endif
                } label: {
                    Text(place.title)
                    Text(PrivacySettings.shortPath(place.url))
                        .font(VFFont.mono)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(place.url.path)
                    Text(place.detail)
                }
            }
        } header: {
            Text("Files on This Device")
        } footer: {
            Text("Projects are saved where you choose. Everything ViaForm writes stays on this device.")
                .font(VFFont.small)
                .foregroundStyle(.secondary)
        }
        .confirmSheet($confirm)
    }

    #if os(macOS)
    /// Shows the folder in the Finder; selects its nearest existing parent when it is not made yet.
    private func reveal(_ url: URL) {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 {
            u = u.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }
    #endif
}

/// The Privacy settings as a whole form (Mac Settings tab).
struct PrivacySettingsForm: View {
    var body: some View {
        Form { PrivacySettingsSections() }
            .formStyle(.grouped)
    }
}
