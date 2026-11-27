# ViaForm specs

Build-ready specifications for ViaForm, written for the owner and for Claude Code agents. Start with
the product spec, then read the spec for the layer you are building.

## Files

| File | What it covers | Read when |
|---|---|---|
| [VIAFORM-SPEC.md](VIAFORM-SPEC.md) | Product spec: rules R-1 to R-10, users, current state, core model (flow graph, artifacts, revisions), app shell and workspace dropdown, the nine stages (workspaces), engine interactions, agents, end-to-end flows, Azure platform, cloud API, build plan, NFRs, testing, decisions D-1 to D-29, glossary | Always first |
| [RUST-ENGINES.md](RUST-ENGINES.md) | All Rust engines: generative design G0 to G10, clean-room PCB, kinematics and IK, motion planning, physics, learning, GPU kernels, bridge interfaces, engine build plan, decisions E-1 to E-20 | Working on any crate under the Rust workspace |
| [FRONTEND-SPEC.md](FRONTEND-SPEC.md) | SwiftUI and Metal front end: architecture layers, ProjectModel, CommandBus and undo, rendering layers, component library, engine wiring per feature, agent manager, collaboration, store and accounts, UX rules, performance budgets, tasks FE-0 to FE-28 | Working on the Apple apps |
| [robot-protocol.md](robot-protocol.md) | Robot link: Feetech STS3215 bus (direct mode), ESP32-S3 bridge frames, safety layer, device profile, recording format, drone MAVLink link and failsafes | Working on the `robot` crate, firmware, or the Robot workspace |
| [LICENSING.md](LICENSING.md) | Licence audit and relicensing plan to MIT OR Apache-2.0 (PCBCraft removal, dependency licences, assets) | Before adding a dependency, before relicensing, before App Store submission |

## Visuals

Mockups in [visuals/](visuals/) were generated with an Azure image model for design direction. They
are not pixel specs: where a mockup and the text disagree, the text wins. Regenerate with
`python3 visuals/gen.py <name>...` (see the prompt list in `gen.py`). Files ending in `.try1.png` are
earlier versions kept for comparison.

| Image | Screen | Spec section |
|---|---|---|
| [01](visuals/01-mechanics.png) | Assemble (mechanics) workspace | VIAFORM-SPEC 7.3 |
| [02](visuals/02-training-cloud.png) | Training in the cloud | VIAFORM-SPEC 7.6 |
| [03](visuals/03-render.png) | Render | VIAFORM-SPEC 7.7 |
| [04](visuals/04-manufacture.png) | Manufacture (Make) | VIAFORM-SPEC 7.8 |
| [05](visuals/05-parts-bom.png) | Parts and BOM | VIAFORM-SPEC 8.2 |
| [06](visuals/06-robot.png) | Robot workspace | VIAFORM-SPEC 7.9 |
| [07](visuals/07-agent.png) | Agent panel | VIAFORM-SPEC 8.3 |
| [08](visuals/08-cloud-run-sheet.png) | Cloud run sheet | VIAFORM-SPEC 9.3 |
| [09](visuals/09-project-start.png) | Project start | VIAFORM-SPEC 7.0 |
| [10](visuals/10-ipad-robot.png) | iPad robot view | VIAFORM-SPEC 7.9 |
| [11](visuals/11-workspace-dropdown.png) | Workspace dropdown | VIAFORM-SPEC 6.0 |
| [12](visuals/12-generate-setup.png) | Generative setup | VIAFORM-SPEC 7.10.1 |
| [13](visuals/13-generate-outcomes.png) | Generative outcomes | VIAFORM-SPEC 7.10.3 |
| [14](visuals/14-loads-from-sim.png) | Loads from simulation | VIAFORM-SPEC 7.10.2 |
| [15](visuals/15-ik-drag.png) | IK drag | VIAFORM-SPEC 7.10.4 |
| [16](visuals/16-hand-grasp.png) | Hand grasp editor | VIAFORM-SPEC 7.10.5 |
| [17](visuals/17-path-planner.png) | Path planner | VIAFORM-SPEC 7.10.6 |
| [18](visuals/18-mobile-base.png) | Mobile base | VIAFORM-SPEC 7.10.7 |
| [19](visuals/19-carbon-plate.png) | Carbon plate | VIAFORM-SPEC 7.10.8 |
| [20](visuals/20-agent-manager.png) | Agent manager layout | VIAFORM-SPEC 8.3 (wiring: FRONTEND-SPEC 6.9) |
| [21](visuals/21-coediting.png) | Co-editing | VIAFORM-SPEC 10.7 (wiring: FRONTEND-SPEC 6.12) |

## Conventions for these docs

- English, plain Markdown, no em dashes.
- Decisions are numbered (D-n product, E-n engines) and never renumbered; superseded ones are marked, not deleted.
- Task IDs (P-n, FE-n, engine rows) are what agents pick up; each task names its files and its done check.
- When code and spec disagree, fix one of them in the same change.
