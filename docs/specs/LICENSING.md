# ViaForm licensing audit

Task P0.5-1 of `VIAFORM-SPEC.md`. Date: 2026-11-07. This is an engineering audit, not legal advice.
Have a lawyer confirm before relicensing and before the first App Store submission.

## 1. Goal

Relicense ViaForm from GPL-3.0-or-later to **MIT OR Apache-2.0** (D-13) so it can ship on the Mac
and iPad App Store (D-11, D-12).

## 2. Findings

### 2.1 Authorship of ViaForm's own code

`git log` of `soma-intelligence/ViaForm` (13 commits on HEAD):

| Author | Commits |
|---|---|
| Quentin Caron `<quentin.caron0@icloud.com>` | 12 |
| Quentin Caron `<quentincaron1999@live.fr>` | 1 |

All commits are by the owner, under two email addresses. Much of the current work is uncommitted
(see VIAFORM-SPEC 4.1), and it was written in this owner's sessions. **Result: the owner can relicense
ViaForm's own code**, provided:

1. No code was copied into ViaForm from GPL sources (check 2.4).
2. Code written by AI coding sessions for the owner is treated as the owner's work. Confirm with counsel.

### 2.2 Rust dependency licences (`cargo metadata`, 220 packages)

Every package is permissive (MIT, Apache-2.0, BSD, ISC, Zlib, Unicode or similar), except:

| Package | Licence | Action |
|---|---|---|
| `pcbcraft-engine`, `-io`, `-doc`, `-geom`, `-library`, `-rules` | GPL-3.0-or-later | Remove (clean-room `pcb` crate, RUST-ENGINES 3B) |
| `viaform-*` (bom, core, ffi, generative, library, node, sim) | GPL-3.0-or-later (ours) | Change to `MIT OR Apache-2.0` after PCBCraft is gone |
| `r-efi` | MIT OR Apache-2.0 OR LGPL-2.1-or-later | Fine: use under MIT or Apache-2.0 |

SolidCraft (`engines/solidcraft`) is `MIT OR Apache-2.0` with many outside contributors. That is
compatible. Its `NOTICE` and `ATTRIBUTION.md` must be reproduced in the app's Acknowledgements screen.

### 2.3 Where PCBCraft is linked today

| Crate or app | How |
|---|---|
| Workspace `Cargo.toml` | `pcbcraft-engine`, `pcbcraft-io` path dependencies |
| `core` | Depends on both (PCB session, KiCad export, link, project file) |
| `bridge` (`viaform-ffi`) | Depends on `pcbcraft-engine` (`pcb_*` functions) |
| `node` | Through `core` |
| `bom` | Dev-dependency only (tests). Remove the tests' use, or keep the tests outside shipped code |
| Apple apps | `PCBEngine.swift`, `PCBModel.swift`, `DeskPCBView.swift`, `DeskRootView.swift`, `FlowModel.swift`, `SelfTest.swift` call `pcb_*` |
| Electron | `engine.ts`, `pcb.ts`, `main.ts`, `api.ts`, tests |
| CI and scripts | `engine-sync.yml`, `scripts/engine-sync.sh` |

PCBCraft (`tangency-labs/pcbcraft`) is by a third party (author `bherbruck` in its history), so
relicensing it is not the owner's decision. Hence the clean-room replacement (D-12).

### 2.4 Copied code check (to do before relicensing)

- [ ] Search ViaForm crates and Swift for code copied from PCBCraft, KiCad or other GPL projects
      (compare with a similarity tool such as `jscpd` or a token-based clone detector against `engines/pcbcraft`).
- [ ] `library/src/kicad.rs` reads KiCad library files. It must be ViaForm's own parser written from the
      public format docs, not adapted from KiCad or PCBCraft code. Confirm, and record in `pcb/CLEANROOM.md`.
- [ ] `docs/design-proposals/v2/shapr-direct/.../ElectronicsScreen.swift` mentions PCBCraft only by name. Fine.

### 2.5 Data and assets

| Item | Licence | Rule |
|---|---|---|
| KiCad symbol, footprint and 3D libraries | CC-BY-SA 4.0 with an exception for designs | Never bundled. Read at run time from the user's KiCad install (as today) |
| Standard hardware tables | Generated from public standards by our code | Fine |
| SF Symbols | Apple licence: allowed in apps on Apple platforms | Fine on Apple platforms, not in Electron |
| Ribbon icon set | Our own artwork | Keep source files in the repo |
| Spec mockups (`docs/specs/visuals`) | Generated with Azure image models for internal design | Not shipped in the app |

### 2.6 Electron app

The Electron app is not shipped on the App Store and stays in maintenance. Its npm dependency licences
are not audited here. Audit them with `license-checker` before any Electron release under the new licence.

## 3. Steps to relicense

1. Finish the clean-room `pcb` crate and pass its parity checklist (RUST-ENGINES 3B.3).
2. Swap `core`, `bridge`, `node` and the apps to `pcb`; remove the `engines/pcbcraft` submodule, the
   engine-sync entries for it, and `bom`'s dev-dependency.
3. Run the copied-code check in 2.4.
4. Change the `license` fields in every `Cargo.toml` to `MIT OR Apache-2.0`; replace `LICENSE` with
   `LICENSE-MIT` and `LICENSE-APACHE`; update the README.
5. Add `cargo deny` with a licence allow-list (MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, Zlib,
   Unicode-3.0, Unicode-DFS-2016, CC0-1.0, MPL-2.0 only if file-level obligations are accepted) and a GPL ban.
6. Add the Acknowledgements screen (Settings, About) listing dependency licences, generated at build time.
7. Have counsel review, then submit to the App Store.

Older commits stay available under GPL-3.0-or-later; new versions are MIT OR Apache-2.0.
