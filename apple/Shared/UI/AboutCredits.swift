import SwiftUI
#if os(macOS)
import AppKit
#endif

// UI-UX-AUDIT P3-14: the credits of the About panel (Mac) and the About ViaForm page (iPad), from
// one list. Sources: docs/specs/LICENSING.md (sections 2.2, 4.2 and 4.3), the root Cargo.toml and
// `cargo tree -p viaform-ffi` (what the app links). MuJoCo is not listed: the shipped bridge is
// built without its `mujoco` feature, so the app only writes MJCF files and links no MuJoCo code.

struct CreditEntry: Identifiable, Hashable {
    let name: String
    /// SPDX expression, as the package declares it.
    let licence: String
    let link: String
    /// What it does in ViaForm, a few words.
    let role: String
    var id: String { name }
}

enum AboutCredits {
    static let appLicence = "GPL-3.0-or-later"
    static let copyright = "Copyright 2026 Soma Labs"

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    static var versionLine: String { String(localized: "Version \(version) (build \(build))") }

    static var entries: [CreditEntry] {
        [
            CreditEntry(name: "ViaForm", licence: appLicence, link: "https://github.com/soma-intelligence/ViaForm",
                        role: String(localized: "This app, by Soma Labs")),
            CreditEntry(name: "SolidCraft", licence: "MIT OR Apache-2.0", link: "https://github.com/tangency-labs/solidcraft",
                        role: String(localized: "Solid modelling engine")),
            CreditEntry(name: "PCBCraft", licence: "GPL-3.0-or-later", link: "https://github.com/soma-intelligence/pcbcraft",
                        role: String(localized: "Circuit board engine")),
            CreditEntry(name: "solidcore-record", licence: "Apache-2.0", link: "https://github.com/tangency-labs/solidcore",
                        role: String(localized: "Model history records")),
            CreditEntry(name: "nalgebra", licence: "Apache-2.0", link: "https://github.com/dimforge/nalgebra",
                        role: String(localized: "Linear algebra")),
            CreditEntry(name: "parry3d", licence: "Apache-2.0", link: "https://github.com/dimforge/parry",
                        role: String(localized: "Collision geometry")),
            CreditEntry(name: "cadmpeg-codec-step", licence: "Apache-2.0", link: "https://crates.io/crates/cadmpeg-codec-step",
                        role: String(localized: "STEP files")),
            CreditEntry(name: "gltf", licence: "MIT OR Apache-2.0", link: "https://github.com/gltf-rs/gltf",
                        role: String(localized: "glTF files")),
            CreditEntry(name: "image", licence: "MIT OR Apache-2.0", link: "https://github.com/image-rs/image",
                        role: String(localized: "Images")),
            CreditEntry(name: "zip", licence: "MIT", link: "https://github.com/zip-rs/zip2",
                        role: String(localized: "Project archives")),
            CreditEntry(name: "rayon", licence: "MIT OR Apache-2.0", link: "https://github.com/rayon-rs/rayon",
                        role: String(localized: "Parallel solving")),
            CreditEntry(name: "serde and serde_json", licence: "MIT OR Apache-2.0", link: "https://serde.rs",
                        role: String(localized: "Project files")),
            CreditEntry(name: "ureq and rustls", licence: "MIT OR Apache-2.0, ISC", link: "https://github.com/rustls/rustls",
                        role: String(localized: "Secure downloads")),
            CreditEntry(name: "ring", licence: "Apache-2.0 AND ISC", link: "https://github.com/briansmith/ring",
                        role: String(localized: "Cryptography")),
            CreditEntry(name: "webpki-roots", licence: "CDLA-Permissive-2.0", link: "https://github.com/rustls/webpki-roots",
                        role: String(localized: "Root certificates")),
            CreditEntry(name: "encoding_rs", licence: "(Apache-2.0 OR MIT) AND BSD-3-Clause", link: "https://github.com/hsivonen/encoding_rs",
                        role: String(localized: "Text encodings")),
            CreditEntry(name: "subtle", licence: "BSD-3-Clause", link: "https://github.com/dalek-cryptography/subtle",
                        role: String(localized: "Constant time checks")),
            CreditEntry(name: String(localized: "Other Rust crates"), licence: "MIT, Apache-2.0, BSD, ISC, Zlib, Unicode-3.0",
                        link: "https://crates.io", role: String(localized: "About 240 more, all permissive")),
            CreditEntry(name: "SF Symbols", licence: String(localized: "Apple licence"), link: "https://developer.apple.com/sf-symbols/",
                        role: String(localized: "Interface symbols")),
        ]
    }

    static let solidCraftNotice = "https://github.com/tangency-labs/solidcraft/blob/main/NOTICE"

    #if os(macOS)
    /// The Credits text of the standard About panel: one paragraph per entry (name and licence,
    /// then the role and a link), in label colours so it reads in light and dark.
    static func attributedCredits() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 8
        func add(_ s: String, _ font: NSFont, _ colour: NSColor, link: String? = nil) {
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: para]
            if let link, let url = URL(string: link) { a[.link] = url }
            out.append(NSAttributedString(string: s, attributes: a))
        }
        add(String(localized: "Free software, \(appLicence)\n"), bold, .labelColor)
        add(String(localized: "Built with these engines and components.\n"), small, .secondaryLabelColor)
        for e in entries {
            // One paragraph per entry: line separators, not new paragraphs, before the role and the link.
            add(e.name, bold, .labelColor)
            add("  \(e.licence)\u{2028}", small, .secondaryLabelColor)
            add("\(e.role).\u{2028}", small, .secondaryLabelColor)
            add(e.link.replacingOccurrences(of: "https://", with: ""), small, .linkColor, link: e.link)
            add("\n", small, .secondaryLabelColor)
        }
        add(String(localized: "SolidCraft notices:") + "\u{2028}", small, .secondaryLabelColor)
        add(solidCraftNotice.replacingOccurrences(of: "https://", with: ""), small, .linkColor, link: solidCraftNotice)
        return out
    }
    #endif
}

#if os(macOS)
/// The app menu's About ViaForm: the standard panel with the version, build, copyright and the
/// credits. `--open-about` opens it at launch (screenshots); `--theme light|dark` then pins its look.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ViaForm",
            .applicationVersion: AboutCredits.version,
            .version: String(localized: "Build \(AboutCredits.build)"),
            .credits: AboutCredits.attributedCredits(),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "\(AboutCredits.copyright). \(AboutCredits.appLicence).",
        ])
        NSApp.activate()
    }

    /// Runs once, the first time the app menu is built.
    static let launchHook: Void = {
        guard ProcessInfo.processInfo.arguments.contains("--open-about") else { return }
        if let mode = ThemeMode.launchOverride, mode != .system {
            NSApp.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { show() } }
    }()
}
#endif

/// The About ViaForm page of the iPad browser sheet: version, licence, then every credit with
/// its link. Content, so a plain list (no glass).
struct AboutCreditsView: View {
    @Environment(\.viaFormTheme) private var theme

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: VFSpace.xs) {
                    Text("ViaForm").font(VFFont.heading).foregroundStyle(theme.ink)
                    Text(AboutCredits.versionLine).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    Text("\(AboutCredits.copyright). Licensed under \(AboutCredits.appLicence).")
                        .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
                .accessibilityElement(children: .combine)
                .padding(.vertical, VFSpace.xs)
            }
            Section {
                ForEach(AboutCredits.entries) { e in
                    if let url = URL(string: e.link) {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: VFSpace.xxs) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(e.name).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                                    Spacer(minLength: VFSpace.m)
                                    Text(e.licence).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                                        .multilineTextAlignment(.trailing)
                                }
                                Text(e.role).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                                Text(e.link.replacingOccurrences(of: "https://", with: ""))
                                    .font(VFFont.small).foregroundStyle(theme.accentText).lineLimit(1)
                            }
                            .frame(minHeight: VFSize.touchTarget)
                        }
                        .accessibilityHint(String(localized: "Opens \(e.link) in the browser"))
                    }
                }
            } header: {
                Text("Engines and Components")
            } footer: {
                if let url = URL(string: AboutCredits.solidCraftNotice) {
                    Link("SolidCraft notices", destination: url).font(VFFont.small)
                }
            }
        }
        .navigationTitle("About ViaForm")
    }
}

/// `--selftest` checks for the credits list (P3-14).
enum AboutCreditsSelfTest {
    static func checks() -> [(Bool, String)] {
        let all = AboutCredits.entries
        let linked = all.allSatisfy { e in
            !e.licence.trimmingCharacters(in: .whitespaces).isEmpty
                && e.link.hasPrefix("https://") && URL(string: e.link)?.host != nil
        }
        let gpl = all.contains { $0.name == "ViaForm" && $0.licence == "GPL-3.0-or-later" }
        let unique = Set(all.map(\.name)).count == all.count
        var out: [(Bool, String)] = [
            (!all.isEmpty, "P3-14 the About credits list is not empty (\(all.count) entries)"),
            (linked, "P3-14 every credit has a licence and an https link"),
            (gpl && unique, "P3-14 the credits carry the ViaForm GPL-3.0-or-later line, no duplicate names"),
        ]
        #if os(macOS)
        let text = AboutCredits.attributedCredits().string
        out.append((text.contains("GPL-3.0-or-later") && all.allSatisfy { text.contains($0.name) },
                    "P3-14 the Mac About panel credits name every entry and the GPL licence"))
        #endif
        return out
    }
}
