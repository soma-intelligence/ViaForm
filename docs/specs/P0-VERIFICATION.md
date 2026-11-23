# P0 verification (UI-UX-AUDIT, claimed fixes)

Date: 2026-11-22, about 20:00 to 20:20. Independent check of the P0 items the audit Status marks fixed. P0-8, P0-11 and P0-14 were skipped (other agents own them). No source file was changed.

## Method and limits

- macOS app built twice with `-derivedDataPath /private/tmp/vf-verify-mac` (19:58 and again 20:12, both BUILD SUCCEEDED). iOS simulator app built with `/private/tmp/vf-verify-ios` (BUILD SUCCEEDED), run on a cloned iPad mini simulator that was deleted afterwards.
- Driving: menus through System Events (AX), window captures with `screencapture -l` and a CGWindowList helper. Screenshots in `docs/specs/screens/uiux/verify/`.
- The desktop was shared: the user's full screen Claude window, and other agents running their own ViaForm builds and sending input. Twice a dialog or the open project changed without any action from me (a Hand study started running, a "Do you want to save" alert was answered Don't Save). I stopped mouse and keyboard injection after that and kept to AX menu clicks plus code reading. Every "GUI" verdict below is limited to what was observed cleanly.
- The tree kept moving during the check (`RobotStage.swift`, `InspectorPanel.swift`, `ProjectWindow.swift` were rewritten at 20:02 to 20:06). Line numbers are as read at about 20:10.

## Verdicts

| P0 | Verdict | One line |
|---|---|---|
| P0-1 Undo target | PARTIAL | Routing is right and greys out per stage; Design and Electronics never name the step; text field Undo can stay greyed |
| P0-2 Unsaved changes | PARTIAL | Alert works; BOM and pipeline edits are not counted as edits; menu actions silently do nothing when the window is not key |
| P0-3 Per-window models | CONFIRMED (code) | Each window owns its models; but File > New Window is gone, so a second window is hard to reach |
| P0-4 Save failure | PARTIAL | Failure is detected and an alert shows; no Try Again, only Save As and Cancel |
| P0-5 Touch export | CONFIRMED (code) | |
| P0-6 Two-finger undo | CONFIRMED (code) | |
| P0-7 Stop freezes training | CONFIRMED (code), with a residual | |
| P0-9 Simulate replaces study | CONFIRMED (code), with a residual | |
| P0-10 Deletes | CONFIRMED (code), one gap | KiCad folder removal is undoable but not confirmed (acceptable) |
| P0-12 E-stop contrast and caps | NOT FIXED on Mac (regression), CONFIRMED on iPad | Mac Robot stage no longer shows the safety bar at all |
| P0-13 Re-enable hold | PARTIAL | HoldButton exists; Space on it latches the e-stop again; unreachable on Mac (see P0-12) |
| P0-15 Esc twice from a field | CONFIRMED (code) | Not driven by keys (shared desktop) |
| P0-16 Touch Return | CONFIRMED (code) | |
| P0-17 Generate thumbnails | CONFIRMED (code) | |
| P0-18 Run pane picker | CONFIRMED (GUI + code) | |

## Details

### P0-1 PARTIAL

Code: `Desk/DeskCommands.swift:89-101` replaces `.undoRedo` with `desk?.undo`, `Desk/ProjectWindow.swift:345-366` picks the target (BOM when edited last, Assemble, Generate, Electronics board, design for Design/Assemble-inactive/Render/Make, `.none` for Simulate/Train/Robot). Palette uses the same target (`ProjectWindow.swift:497-498, 521-522`).

GUI (drone sample, AX reading of the Edit menu after switching stage through the Workspace menu): Simulate, Train, Robot: "Undo" disabled. Generate before any change: disabled; after opening a study: "Undo Open Study" enabled. Assemble (drone, assembly active, no history): disabled, while Design had undo history: so Assemble no longer undoes the design. Render, Make, Design: "Undo" enabled.

Gaps:
1. The design target (`ProjectWindow.swift:361-362`) and the Electronics target (`:358-359`) pass no `undoName`, so the menu reads plain "Undo" in the stages used most. The audit asked for "Undo Extrude". The toast after the undo names it, the menu does not.
2. Text fields: the `disabled` and title read `textFieldEditing` (`DeskCommands.swift:61-64`), a plain computed property on `NSApp.keyWindow?.firstResponder`. SwiftUI only re-evaluates the Commands body when the focused `DeskFocus` changes, not when first responder changes. If the stage has nothing to undo (for example Simulate, or a fresh design) and the user types in a field, the Undo item can stay disabled, and a disabled menu item swallows Cmd-Z, so the field gets no text undo. Not verified by keystrokes (shared desktop); flag for a hand test.

### P0-2 PARTIAL

GUI: demo design (`--design-demo=profiles`), close button AXEdited = true. File > New Design shows the alert "Do you want to save the changes to "Untitled"?" with Save, Don't Save (destructive), Cancel: `verify/p0-2-new-design-alert.png`. Close and Quit hooks exist in code (`Desk/FileActions.swift:154-174` `confirmQuit` and `applicationShouldTerminate`; `:176-240` window delegate proxy with `windowShouldClose`) but were not driven (shared desktop). Template start asks first (`ProjectWindow.swift:111-119`).

Gaps:
1. "Edited" only compares the design revision and the PCB revision (`Shared/Flow/ProjectFiles.swift:60-63`). BOM edits, Generate study edits, Assemble edits that live outside the design, and pipeline changes are not counted: New, Open, close and Quit discard them with no question. The audit fix named design, PCB, BOM and flow.
2. When the project window is not key (any other app or window in front), `desk` is nil and New Design, Open, Save are silent no-ops (`DeskCommands.swift:71-87`). Observed: two AX clicks on File > New Design with the window not key did nothing at all. Low impact for a human (menus follow the key window), worth knowing for scripting.
3. A freshly launched sample (`--drone`) is already marked edited, so the user is asked to save a sample they never touched. Minor.
4. `ProjectGuard.ask` builds a `verb` and discards it (`FileActions.swift:146`), so the alert never says what will happen (Open, New Project, Quit).

### P0-3 CONFIRMED (code)

`DeskWindowRoot` holds `@State DesignModel` and `PCBModel` per window (`DeskCommands.swift` DeskWindowRoot), `ProjectWindow.swift:17-25` holds the rest; every DesignModel has its own `CADEngine`; the mesh cache in `Renderer.swift:102` is keyed by a global serial, so no cross-window leak. `ProjectFiles.current` survives but is only written, never read. Not tested with two windows: `CommandGroup(replacing: .newItem)` (`DeskCommands.swift:71`) removes File > New Window, and no other menu item opens one. Effectively single-window, which is safe but should be a decision. `RobotSafety.shared` stays app-wide (intended: one e-stop).

### P0-4 PARTIAL

GUI/CLI: `--project-roundtrip=/private/tmp/vf-ro/x.viaform` into a `chmod 555` folder prints `roundtrip saved=false`: the failure now reaches the caller. Code: `FileActions.report` (`Desk/FileActions.swift:91-107`) shows a warning alert with the engine reason, "Your work is still open", and buttons Save As and Cancel. Export failure shows an alert (`:81-87`). Gap: no Try Again / Retry (the audit fix and the checklist ask for it); a transient failure (disk full, network volume) has to go through Save As. The alert itself was not captured (Save As panel could not be driven safely).

### P0-5 CONFIRMED (code)

`Touch/TouchRootView.swift:1171+` `ExportFlow`: Replace confirmation, progress, Share, `InlineError` with Try Again, Cancel before write and Done after; KiCad export uses it too (`Touch/TouchPCBView.swift:99`).

### P0-6 CONFIRMED (code)

`Touch/TouchTools.swift:477-530`: recognizer on the window but `shouldReceive` only for touches on an `MTKView`, `gestureRecognizerShouldBegin` refuses under a presentation; toast "Undone: name" with Redo (`TouchRootView.swift:480-492`). Note: Generate (SceneKit) and PCB canvases are not MTKView, so two-finger undo does nothing there; acceptable.

### P0-7 CONFIRMED (code), residual

`Shared/Sim/SimModel.swift:376-389` `cancel()` sets `stopping`, calls `job.cancel()` and lets a poll task finish; no sleep on the main actor. `runToEnd` (`:392-397`) still sleeps, called only from `SelfTest.swift:145, 173`. Residual: `vf_train_free` "cancels the job if it still runs, waits for it" (`bridge/src/sim.rs:170-180`), and `SimTrainJob.deinit` calls it (`Shared/Sim/SimEngine.swift:239`). Releasing a running job on the main actor (closing the window during training, or `start()` replacing a running job) still blocks until the iteration ends. Start is disabled while running (`Desk/StageActions.swift:35`), so the common path is safe.

### P0-9 CONFIRMED (code), residual

`HandGraspView.swift:39` now calls `generate.openProjectOnly("hand")`, which keeps the study (`GenerateModel.swift:693-698`); template and sample taps go through `openSample(replaceStudy:)` which keeps an edited study unless confirmed (`GenerateProjectView.swift:38-47`), and loading a study is one undo step ("Undo Open Study" seen in the Edit menu). Residual: `openProjectOnly` still swaps the Generate project (studies list, joints, assembly summary) from the drone to the hand without a word.

### P0-10 CONFIRMED (code)

BOM: Remove Line, Remove N Lines, Remove origin are undoable snapshot steps with a toast Undo (`Shared/Bom/BomModel.swift:571-611, 661-685`, `BomView.swift:574-575`), `role: .destructive` everywhere. Library: delete part and Forget Keys go through `ConfirmRequest` (`Shared/Library/LibraryView.swift:255-271, 391-427`); KiCad folder removal is undoable via toast (`LibraryModel.swift:414-419`), no confirm. Browser body Delete: destructive role, toast with Undo (`Desk/BrowserSidebar.swift:351-400`). Touch timeline: destructive, toast Undo (`TouchRootView.swift:668-675, 751`). Generate case, region, impact: toast Undo bound to the exact step (`GenerateInspector.swift:243-246, 353-357, 411-414`). Small risk: the browser and timeline toasts call the generic `model.undo()`, so pressing Undo after another edit undoes that edit instead.

### P0-12 NOT FIXED on Mac (regression), CONFIRMED on iPad

Tokens are right: dark `dangerFill #D93025` with white gives 4.77:1, light `#C4261D` gives 5.77:1 (computed), and `ThemeContrastTests.swift:135` checks it. `SafetyBar` reads caps from `RobotSafety` and shows "Not applied, no robot" (`Shared/UI/Components/SafetyBar.swift`, `RobotSafety.swift:135-140`).

But on the Mac the Robot stage now renders with the whole split view oversized: no ribbon, no safety bar, no e-stop, no connection card, no status bar, empty sidebar and inspector. Seen on both builds (19:58 and 20:12 tree), at 1440x900, 1600x1000 and 1700x1040, with an empty project and with `--arm`, on launch and when switching to Robot from Make. Other stages lay out normally. Compare `screens/uiux/before/robot-dark.png` (e-stop visible) with `verify/p0-12-robot-dark-rebuild.png`, `verify/p0-12-robot-arm-dark.png`, `verify/p0-12-robot-from-make.png`, and `verify/other-stages-ok.png`. Cause not isolated; something in the Robot stage (RobotStage, the Robot inspector section or SafetyBar's `ViewThatFits`) reports a height larger than the window. This is the worst finding: the e-stop is not in view where motion would start. Space and Esc twice still latch through the key monitor, but nothing shows it.

iPad (`verify/ipad-robot-dark.png`): real red E-STOP button, caps "Not applied, no robot", link state, connection card. Fine.

### P0-13 PARTIAL

`HoldButton` (`Shared/UI/Components/Controls.swift:93-153`): focusable, 1 s ring, Reduce Motion gives two steps, VoiceOver action asks for confirmation. Gaps: height is `max(VFSize.buttonHeight, 32)`, so 32 pt on the Mac (44 on iPad; the audit asked 44 pt). On the Mac, Space on the focused HoldButton never reaches it: the window key monitor takes Space in the Robot stage as the e-stop (`ProjectWindow.swift:412-413`, `DeskKeys.swift` monitor runs before the view), so "hold Space to re-enable" latches the e-stop again. Return works. And the banner is not visible on the Mac today (P0-12).

### P0-15 CONFIRMED (code)

`DeskKeys.swift` monitor calls `urgent` before the `NSText` check; `ProjectWindow.swift:384-388` handles Esc in Robot through `safety.escape()` (second Esc within 0.6 s latches, `RobotSafety.swift:172-180`). Note: the monitor ignores events whose window is not the project window, so Esc twice inside a sheet or alert does not stop (the comment says it does).

### P0-16 CONFIRMED (code)

`Touch/TouchStages.swift:325-337`: Done has no plain Return shortcut; Cmd-Return runs the stage primary, which is "Finish tool" (`TouchRootView.swift:445`, `TouchChrome.swift:484, 554`); `finish` ends field editing first (`TouchStages.swift:364-375`); Move X/Y/Z fields chain with Return.

### P0-17 CONFIRMED (code)

Thumbnails and camera live in `GenerateModel` (`GenerateModel.swift:125-155`), rendered off the main actor once per `previewsVersion`, triggered by `.task(id:)` (`GenerateView.swift:53`); the render task is unstructured, so a stage switch does not cancel it and a return reuses the images. Minor: a theme change does not re-render them.

### P0-18 CONFIRMED (GUI + code)

`GenerateInspector.swift:11-47`: only Study and Regions lock, with "Locked while the study runs. Stop to edit." and a Stop button; the pane picker stays live. Screenshot during a hand study run: `verify/p0-18-generate-running.png` (tabs live, Project list greyed by its own form).

## Side observation (P0-8, not judged)

During a running Generate study, Workspace > Stop Job clicked through AX stayed enabled and the run went on from iteration 14 to 30. It may have been the over-30 s confirm path (`GenerateModel.swift:525-538`) waiting on a sheet that was not visible in the capture. Worth a look by the P0-8 owner.
