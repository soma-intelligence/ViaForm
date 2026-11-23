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

## 4. Authorship audit (2026-11-22)

Task P0.5-1, second pass. Scope: every branch of the repository, the working tree (committed and
uncommitted files), outside the `engines/` submodules. Engineering audit, not legal advice.

### 4.1 Contributors

`git shortlog -sne --all` over `fusion-layout`, `main`, `origin/main`, `origin/engine-sync` and
`origin/fusion-layout` (29 commits):

| Identity | Commits | Branches | What |
|---|---|---|---|
| Quentin Caron `<quentin.caron0@icloud.com>` | 26 | all | All code, specs and assets |
| Quentin Caron `<quentincaron1999@live.fr>` | 1 | all | The initial commit (made in the GitHub web UI, committer `GitHub`) |
| Soma Labs `<opensource@somalabs.me>` | 1 | `origin/main` only | `78fb6cc`: README hub, guides, `llms.txt`, `AGENTS.md`, `CITATION.cff` (docs only) |
| viaform-bot `<viaform-bot@users.noreply.github.com>` | 1 | `origin/engine-sync` only | `b65431e`: engine submodule pointer and version bump in `electron/package*.json`, made by this repo's own workflow |

No `Co-authored-by` trailers. No commit from anyone outside the owner, the owner's company and the
owner's bot. Uncommitted work in the tree today (`core/src/asm/`, `fluid/`, `docs/fluid/`,
`bridge/tests/`, edits in `core/src/flow/`) is written by the owner's own coding sessions.

Two copyright holders appear: Quentin Caron (commits) and Soma Labs (one commit, and
`electron/electron-builder.yml` says "Copyright 2026 Soma Labs"). Pick one holder before
relicensing, or record that Quentin Caron assigns his rights in ViaForm to Soma Labs (or the
reverse).

### 4.2 Third-party code and data inside the repository

Searched every tracked and untracked file outside `engines/` for licence headers, copyright
lines, SPDX tags, "ported from", "adapted from", "line for line" and similar, and for vendored
crates, fonts, KiCad library files and 3D models.

| Item | Finding | Status |
|---|---|---|
| Vendored crates or copied source trees | None. All Rust code is in the workspace crates; all third-party crates come from crates.io | Clear |
| Fonts | None in the repo (the apps use system fonts) | Clear |
| KiCad symbols, footprints, 3D models | None tracked (no `.kicad_sym`, `.kicad_mod`, `.pretty`, `.step` from KiCad). `library/src/kicad.rs` reads the user's own KiCad install at run time | Clear |
| `samples/` (`drone.step`, `drone.viaform`, `flight-controller.kicad_pcb`) | Git-ignored; written by our own `npm run sample:drone` | Clear |
| `LICENSE` | GPL-3.0 text (FSF) | Replace at relicensing |
| `generative/src/solid/mma.rs` | MMA optimiser that follows Svanberg's `mmasub` and `subsolv` closely (same structure, parameter names and defaults). Ships in the app | **Confirm provenance**: written from Svanberg's papers and public notes, not translated from his MATLAB code. Record the terms of that code either way |
| `generative/examples/validate.rs` (`top3d_oc`) | Described in its own comments as a line-for-line port of `top3d.m` (Liu and Tovar 2014) | **Blocker for this file**: confirm `top3d.m`'s terms allow it, or rewrite from the paper, or drop the comparison. Example only, not shipped |
| `generative/examples/validate.rs`, `docs/generative/ENGINE.md` | Default parameters taken from `TopOpt_in_PETSc` (`TopOpt.cc`, `LinearElasticity.cc`) | Numbers only, not code. Confirm nothing else was translated |
| `generative/src/solid/mg.rs` | Multigrid "after" Amir, Aage and Lazarov (2014) and Aage et al. (2015) | Method from papers. Clear |
| `sim/` | Ported from our own TypeScript in `electron/src/shared/sim` | Own code. Clear |
| `apple/Resources/ToolIcons`, `scripts/icons/raw` | Generated by `scripts/icons/gen.py` with an Azure image model; the prompt names Autodesk Fusion and Shapr3D as style references | No third-party pixels. Style resemblance goes to the R-6 legal review, not a licence issue |
| `docs/design-proposals/`, `docs/specs/visuals/` | AI concept images and HTML mockups, some imitating the Fusion layout (`v2/fusion-faithful`) | Docs only. Never ship them in the app bundle |
| SF Symbols in the Apple apps | Apple licence, Apple platforms only | Clear |

### 4.3 Rust dependency licences

`cargo metadata --format-version 1` on the workspace (275 packages, every target platform):

| Licence expression | Packages |
|---|---|
| MIT OR Apache-2.0 (any spelling or order) | 182 |
| MIT | 30 |
| Apache-2.0 | 15 |
| GPL-3.0-or-later | 14 |
| Other permissive (Zlib, ISC, BSD-2/3-Clause, Unlicense, 0BSD, Unicode-3.0 and combinations) | 33 |
| CDLA-Permissive-2.0 (`webpki-roots`, root certificate data) | 1 |

Flagged:

| Package | Licence | Verdict |
|---|---|---|
| `pcbcraft-engine`, `-io`, `-doc`, `-geom`, `-library`, `-rules` | GPL-3.0-or-later | **Blocker**: third party (PCBCraft). Remove with the clean-room `pcb` crate |
| `viaform-core`, `-ffi`, `-node`, `-bom`, `-fluid`, `-generative`, `-library`, `-sim` | GPL-3.0-or-later | Ours. Change to `MIT OR Apache-2.0` after PCBCraft is gone |
| `viaform-kin`, `viaform-pcb`, `viaform-phys` | MIT OR Apache-2.0 | Already on the target licence |
| `r-efi` 5.3.0 and 6.0.0 | MIT OR Apache-2.0 OR LGPL-2.1-or-later | Fine: take it under MIT or Apache-2.0 |
| `webpki-roots` | CDLA-Permissive-2.0 | Fine: permissive data licence, keep its text in the Acknowledgements |
| `ring` (Apache-2.0 AND ISC), `encoding_rs` (adds BSD-3-Clause), `subtle` (BSD-3-Clause) | Permissive with notice | Fine: reproduce notices |

No MPL, LGPL-only, AGPL, unknown or non-commercial licence among the Rust dependencies. The
SolidCraft crates (11 packages) are MIT OR Apache-2.0.

### 4.4 Electron dependencies

`node_modules` is not installed in this checkout, so licences come from `electron/package-lock.json`
(361 packages). The app's own `package.json` says GPL-3.0-or-later (ours, to change).

| Licence | Packages |
|---|---|
| MIT | 286 |
| ISC | 37 |
| BSD-3-Clause | 11 |
| Apache-2.0 | 8 |
| BlueOak-1.0.0 | 8 |
| BSD-2-Clause | 5 |
| Python-2.0 (`argparse`), WTFPL, WTFPL OR ISC, WTFPL OR MIT, MIT OR CC0-1.0, 0BSD | 6 |

Runtime dependencies (`electron-updater` and its 15 transitive packages) are MIT, ISC, Python-2.0
and BlueOak-1.0.0, all permissive. `three` (MIT) is bundled into the renderer. The Electron binary
carries Chromium's and Node's own notices, which `electron-builder` ships. No GPL, LGPL, MPL or
non-commercial licence. Rerun with `license-checker` on an installed tree before an Electron release.

### 4.5 Verdict

**Yes, the owner can relicense ViaForm's own code to MIT OR Apache-2.0 once PCBCraft is removed**,
because every commit on every branch comes from the owner, the owner's company or the owner's
bot, and no dependency other than PCBCraft is copyleft. What blocks it today:

1. **PCBCraft** (6 GPL crates) is still linked by `core`, `bridge`, `node` and `bom` (dev), and
   called by the Apple and Electron apps (section 2.3). Phase 0.5 tasks P0.5-2 and P0.5-3.
2. **`mma.rs` provenance**: confirm it was written from the papers, or replace it.
3. **`top3d` port** in `generative/examples/validate.rs`: confirm the terms, rewrite or remove.
4. **One copyright holder**: settle Quentin Caron versus Soma Labs (assignment or a single name in
   the new `LICENSE-*` files, `CITATION.cff` and `electron-builder.yml`).
5. **Counsel**: confirm that code written by AI coding sessions for the owner is the owner's work
   (section 2.1), then the steps in section 3.

### Owner rulings (2026-11-22)

- `generative/src/solid/mma.rs`: written from Svanberg's papers (1987, 2002) and his public notes,
  not translated from his MATLAB code. No longer a blocker.
- Copyright holder: **Soma Labs**. Quentin Caron's contributions are assigned to Soma Labs; the new
  `LICENSE-*` files, `CITATION.cff` and `electron-builder.yml` name Soma Labs.
- Still open: the `top3d` port in `generative/examples/validate.rs` (item 3) and counsel (item 5).
