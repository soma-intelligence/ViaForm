# Humanoid hand: component notes

Checked 2026-11-04, revised 2026-11-05 after review (5 V alternates, sheaths, bearings, tendon, wiring, fuses, force budget). Source of truth is `hand.json` in this folder. This file explains the choices and lists what is not confirmed.

## Architecture

24 DOF, 24 motors, one motor per DOF. Every finger, thumb and palm joint is driven by a ROBOTIS XC330-T288-T in a forearm bank, through a pull-pull tendon pair in compressionless steel Bowden housings (Jagwire LEX-SL 4 mm, metal end caps at both ends). The wrist has two XM430-W350-T driving a 2-axis gimbal directly.

Hands I looked at:

- LEAP Hand (CMU): 16 XC330 servos in the hand, direct drive. Cheap and robust, but 16 DOF, no DIP and no wrist, and the hand is larger than a human hand because the motors sit in the fingers.
- Shadow Dexterous Hand: 24 joints, 20 actuated. DIP is coupled to PIP, motors and tendons sit in the forearm. This is the layout used here, with the DIP coupling removed and a motor added for each DIP.
- ILDA (Nature Comms 2021): 15 DOF through linkages, all actuators in the palm. Too few DOF for this brief.
- InMoov and DexHand: 5 to 6 tendon servos in the forearm, heavily underactuated.

A human-size hand can't hold 22 motors, so the Shadow-style forearm bank is the only way to give each DOF its own actuator. LEAP's motor family keeps it buyable and on one bus.

## DOF map (24)

| Group | Joints | Motors |
|---|---|---|
| Index, middle, ring, little (x4) | MCP abduction, MCP flexion, PIP, DIP | 16 x XC330 |
| Thumb | CMC flexion, CMC abduction, MCP flexion, MCP abduction, IP | 5 x XC330 |
| Palm | ring/little CMC arch (cupping) | 1 x XC330 |
| Wrist | flexion/extension, radial/ulnar deviation | 2 x XM430 |

## Tendons and forces

- Each XC330 drives one 6 mm radius spool. The flexor and extensor wind in opposite directions (pull-pull), so no return springs are needed. Pretension comes from turning the spool on its horn before tightening.
- Stall tension: 1.0 Nm / 6 mm = 167 N at 12 V. That is the ceiling, not the working point: the current limits below hold it far lower.
- Tendon (T1): PowerPro 100 lb (445 N), 0.46 mm. The safety factor counts on the terminated strength, not the line rating. A knot keeps 40 to 70 percent (178 to 311 N), which is why v1's 80 lb line (SF 0.9 to 1.5 once knotted) was dropped. Terminate with a screw clamp on the spool and a clamp or splice at the joint, never a knot. Pull-test 3 terminated samples, then set the firmware current limit so tension stays under 0.5 x that measured strength. Until the test is done, assume the 40 percent case: 178 N terminated, so the pulled tendon is capped at 89 N, its 20 N pretension included (safety factor 2). See "Tendon cap and current limit" below for the current this needs (about 0.41 A, not 0.5 A).
- Spectra creeps under sustained load, so pull-pull pretension drops during a held grip. Re-tension after the first hours, or move to a low-creep braid (Vectran, Dyneema SK99/DM20), which is not sourced at 0.5 mm.
- Sheaths (T2): bare PTFE tube cannot take the compression. A 1 x 2 mm PTFE tube at 167 N sees 167 / (pi x (1.0^2 - 0.5^2)) = 71 MPa, still about 38 MPa at 90 N, against the 10 to 15 MPa where PTFE creeps and yields. The sheath shortens, the slack and the pull-pull pretension go, and the joint angle can no longer be read from the servo encoder. The sheath is now a compressionless 4 mm housing (linear steel strands, low-friction liner) with alloy end caps (T3) seated in metal or printed stops at both ends. A 2 mm OD stainless coil with a 0.6 mm ID PTFE liner would be smaller but is a custom part, not sourced.
- Joint pulley radius 6 mm: joint torque equals spool torque before Bowden friction (expect 30 to 50 percent loss). Tendon speed 71 rpm x 2 pi x 6 mm = 45 mm/s, about 420 deg/s at a 1:1 joint.
- Tendons that cross proximal joints couple joints, as in the Shadow hand. Route them through the joint axes where possible and decouple the rest in software.
- No joint encoders: joint angle is estimated from the servo encoder minus tendon stretch. If closed-loop joint angles are needed, add on-joint magnetic angle sensors (not sourced).

## Tendon cap and current limit

The cap is on the pulled tendon, pretension included: 89 N = 20 N pretension + 69 N from the spool. On the 6 mm spool that is 69 N x 6 mm = 414 N mm, 41 percent of the 1.0 N m stall.

The current that gives 0.414 N m, from this file's own torque and current points (1.0 N m at 0.88 A, 0.78 N m at 0.7 A, 0.53 N m at 0.5 A): the slope between the two lower points is (0.78 - 0.53) / 0.2 = 1.25 N m per A, so 0.5 - (0.53 - 0.414) / 1.25 = 0.41 A. The earlier "about 0.5 A" was wrong: 0.5 A gives 0.53 N m, 88 N from the spool, 108 N on the tendon with the pretension, a safety factor of 1.65 on 178 N.

- Set every XC330-T288-T to about 0.41 A (Current Limit, address 38). The register value and its unit are UNCONFIRMED (not read from the ROBOTIS control table): set and check the cap on a load cell, tendon terminated as built, before first use.
- The extrapolation below 0.5 A is linear and the torque to current curve is not known there: UNCONFIRMED until the load cell test.
- The generative structure (generative/examples/hand.rs) now takes this cap in every tendon load case: links, palm, ulnar palm, forearm bank and sheath stops (89 N on the pulled tendon, 20 N on its antagonist, 109 N per tendon pair on a stop). The uncapped figures (167 N + 20 N = 187 N, safety factor 0.95 on 178 N) are kept in docs/generative/hand/hand.json for the record. The two XM430s drive the wrist directly with no tendon, so the wrist parts are still checked at their full 4.1 N m stall.
- With the cap lower than the hub budget (0.7 A on bus A, 0.5 A on bus B), the cap is the binding limit on every XC330: bus A 13 x 0.41 = 5.3 A, bus B 9 x 0.41 + 2 x 2 A = 7.7 A, both under 10 A.

## Fingertip force: the human grip requirement is not met

1.0 Nm is the stall torque at 12 V with 0.88 A. The tendon cap above (89 N on the pulled tendon, about 0.41 A) is now the binding limit on every XC330, on both buses, until a pull test proves a stronger termination. The spool gives 0.414 Nm. After 30 to 50 percent Bowden friction:

| | Joint torque | Index tip, MCP-limited (about 92 mm lever) |
|---|---|---|
| Every XC330 (index, middle, ring, little, thumb, arch), about 0.41 A | 0.21 to 0.29 Nm | 2.3 to 3.1 N |

Whole-hand grip comes out around 25 to 35 N (the earlier 40 to 60 N scaled by the lower torque). The earlier table (0.7 A on bus A: 4 to 6 N, 0.5 A on bus B: 3 to 4 N) broke the tendon cap. A human hand gives 40 to 70 N at one fingertip and 300 to 500 N of power grip. **This hand does not meet a human grip-force requirement.** It is a dexterity hand, not a strength hand. The v1 note's 5 to 10 N ignored the current limits.

Ways to gain force, each with its cost (not applied, owner's call):

1. Bigger servos on the MCP flexors and the thumb only, for example XM430-W350-T (4.1 Nm) or XC430-W240-T. Costs forearm volume and money, and the XM430 draws up to 2.3 A each.
2. A 2:1 joint-to-spool pulley ratio on the MCPs: twice the torque, half the speed (about 210 deg/s). Bearing and tendon loads stay as they are.
3. Three power hubs instead of two, each under its 10 A, so the servos can run at full current. Only useful once the tendon termination and bearings are proven at 167 N.

## Bus and power

- Bus A (index, middle, thumb): 13 x XC330 on U2D2 Power Hub 1.
- Bus B (ring, little, palm, wrist): 9 x XC330 + 2 x XM430 on U2D2 Power Hub 2.
- OpenRB-150 is the embedded controller and carries data only. Its 4 DYNAMIXEL ports share one switched VDD, capped at 3 A for the board. A standard 3-wire Cable-X3P from OpenRB to each hub would put the two hubs' 12 V outputs in parallel through the OpenRB's traces, defeat the 2 x 10 A split, and break ROBOTIS's rule against several power inputs at once. So both OpenRB-to-hub links carry GND + DATA only: JST EHR-03 housings (C2) with SEH-001T-P0.6 contacts (C3) on pins 1 and 3, pin 2 (VDD) left empty. The zero-part option is a Cable-X3P with its pin 2 contact pulled out of both housings and cut back. Use the same 2-wire links when the U2D2 replaces the OpenRB for PC control at up to 4 Mbps.
- Feed OpenRB VIN from the 12 V rail through its own 3 A fuse, jumper on VIN(DXL).
- Power path: mains, then SW1 (rocker) and ES1 (e-stop, NC) on the line conductor, then P1 LRS-350-12. Two 18 AWG runs per polarity, kept short, go from P1's terminals to two WAGO 221-415 (P3, one per polarity, rated 20 A UL / 32 A IEC). From there each branch leaves through its own in-line ATO holder (PF3): 10 A for hub A, 10 A for hub B (PF1), 3 A for the OpenRB (PF2). The simpler equivalent is to wire each branch straight to its own +V/-V terminal pair on the LRS-350-12 and drop P3.
- Worst case at stall: 22 x 0.88 A + 2 x 2.3 A = 24 A, inside the LRS-350-12's 29 A. Each hub is rated 10 A, so set the servo current limits so that no chain can go over 10 A: bus A at about 0.7 A per XC330, bus B at about 0.5 A per XC330 with the wrist at about 2 A. The fuses back this up when firmware fails.
- Fingertip sensing: 5 FSR 400 Short on OpenRB analog A0 to A4, each with a 10 k divider.

## Left to the generative structure

Phalanges and joint pulleys, palm, thumb CMC saddle, the forearm bank frame for 22 servos, the spools, the sheath stops and the wrist gimbal yokes. Sizes they have to fit: XC330 20 x 34 x 26 mm; XM430 28.5 x 46.5 x 34 mm; bearings 693ZZ 3x8x4 (finger and thumb axes, was MR63ZZ 3x6x2.5: clevis and pulley bores must grow), 623ZZ 3x10x4, 688ZZ 8x16x5; pins 3 x 16 and 8 x 20; sheath OD 4 mm with 4 mm alloy end caps (was 2 mm), so the wrist passage has to clear 44 x 4 mm; inserts M2 and M3.

## Cost

USD 3,761 for one hand (was 3,521): sum of pack price x packs from the first offer of each line. Servos are about 77 percent of it (22 x 103.39 + 2 x 310.39). The rise is the 4 mm housing roll (USD 130), the e-stop station (USD 85), fuses and holders.

## Bearings

MR63ZZ (C0 59 to 73 N depending on vendor) was under-rated. The joint reaction is about the active tendon tension plus the antagonist pretension: up to about 187 N at an uncapped stall, 94 N per bearing with 2 per axis, and 109 N, 55 N per bearing, at the tendon cap. MR63ZZ sits at or above C0 even so, so the races would brinell and the joints gain play. B1 is now 693ZZ 3x8x4, C0 179 N (NSK datasheet): static safety factor about 1.9 at an uncapped stall, 3.3 at the tendon cap. 683ZZ 3x7x3 was not taken: C0 129 N (NMB spec sheet), under the 150 N target. iglidur 3 mm plain bushings (about 9 MPa at 84 N on 3 x 3 mm) are a thinner option, not sourced.

## Joint pins (SH1) and their bores

SH1 is a 3 x 16 mm ISO 2338 dowel, h8: 2.986 to 3.000 mm. It is pressed into the parent link's two lugs and the child turns on two bearings round it, so the lug bore sets the fit. The generative model cuts every SH1 bore at the nominal 3.000 mm (the drawing size). Design callout for the printed AlSi10Mg (LPBF) lugs: print the bore 0.2 mm under (2.8 mm), then ream to 3 mm S7, 2.976 to 2.986 mm, which gives 0 to 0.024 mm interference on an h8 pin. This is a fit chosen here from ISO 286 for a press fit on an h8 pin, not a sourced dimension: prove it on a printed coupon (push-in force, pin does not walk out under a 109 N joint load) before the first build. The 8 x 20 mm wrist pins (SH2) stay at their nominal bore; their tolerance grade is not named on the listing (UNCONFIRMED).

## Unverified items

- XC330-T288-T: the robotis.us price was not read (HTTP 429), so RobotShop's USD 103.39 is used. Out of stock at RobotShop, 46 week lead at Mouser. The STEP link in the ROBOTIS Drawings section was not opened.
- XM430-W350-T: price from a search snippet. The STEP link was not opened.
- U2D2 Power Hub (902-0145-001): dimensions and mass estimated, e-manual not opened.
- U2D2 (902-0132-000): dimensions and mass from memory.
- Robot Cable-X3P 180 mm (903-0249-000): possibly obsolete. Fallback is 903-0251-000.
- LRS-350-12: USD price from an aggregator. Dimensions and mass from memory.
- Qualtek 311013-01: USD price estimated from AUD.
- 18 AWG silicone wire (P4): no MPN, placeholder price.
- FSR 400 Short (34-00004): price from Octopart, date unknown. Force range from memory.
- YAGEO MFR-25FBF52-10K: USD price estimated from JPY.
- Adafruit 1881/1877: price not read.
- 3 x 16 mm dowel (Zoro G3404177), M2x6 SHCS (Zoro G006337305), McMaster 94459A120 and 94459A140: prices not read (Zoro 403, McMaster blank). I used assumed prices.
- 8 x 20 mm dowel: the stainless grade isn't named on the Zoro listing.
- McMaster SKUs for M2/M3 socket head screws and dowel pins could not be confirmed. Zoro listings are used for those.
- Not confirmed on the ROBOTIS drawings: whether the XC330 case and horn take M2 screws, and what hardware ships with each servo.
- Most masses and dimensions for small parts are estimates.
- Review fixes 2026-11-05: DigiKey returned 403, so EHR-03, SEH-001T-P0.6 and FHAC0001ZXJ prices are assumed or from aggregators. Holder 01530008Z named in the review could not be found; FHAC0001ZXJ replaces it. 257-series ATO fuses are obsolete, 287 series used.
- XALK178 contact rating against the LRS-350-12 mains current (about 6.8 A at 115 VAC, from memory) and its inrush is not confirmed. If short, the e-stop should drop a mains contactor.
- Jagwire LEX-SL liner ID is not published; GC4FA end cap price not read (AUD listing), OD and length estimated.
- PowerPro 100 lb (21101000150E) price not read, assumed USD 30. Terminated strength must be measured.
- 693ZZ from RCJaz in CAD, converted at about 0.72.
- The generative hand model (generative/examples/hand.rs) sizes B1 as 693ZZ 3x8x4 and B2, B3 from hand.json (it checks them when it runs). Its sheath stops and bundle channels still budget about 1.15 mm2 per sheath (8 sheaths in a 3.4 mm radius channel), far smaller than eight 4 mm housings: not resolved there.
- Joint limits in the generative model (docs/generative/hand/assembly.json limits_deg) are measured from the pose the parts are written in, and were set from swept collision checks, not from a human range of motion: MCP abduction is only a few degrees toward a neighbouring finger (the links are as wide as the knuckle pitch); PIP reaches 105 deg on every finger. With the index fully curled, its abduction must stay at 4 deg or less (at 15 deg its middle link overlaps the middle finger's by 33 mm3): a controller rule, not a joint limit. Thumb opposition brings the thumb pad within 1 mm of the index, middle and ring pads and 2.2 mm of the little pad with no collision, but edge on, not pad square on pad: the thumb chain cannot face the pads squarely.
