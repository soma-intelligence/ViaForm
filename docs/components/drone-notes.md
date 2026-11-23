# Drone components: notes

Checked 2026-11-04. Source of truth: `drone.json` (20 rows, schema v1). Cost rule matches `hand.json`: `ceil(qty/moq) * moq * unit_price` of the first offer, frame excluded.

## Build

3-inch quad (~130 mm wheelbase), 4S.

| Subsystem | Part | Why |
|---|---|---|
| Motors | T-Motor F1404 KV4600 (x4) | same as the sim; rated 3-4S; maker table up to 344.7 g on GF3016 at 4S |
| Props | Gemfan Hurricane 3016-3, 1.5 mm hub | same as the sim, and the prop the motor was tested with |
| FC + ESC | SpeedyBee F405 Mini BLS 35A 20x20 stack | same as the sim; 35 A per channel against a 17.5 A peak motor draw |
| Battery | GNB 4S 650 mAh 80C XT30, 79 g | owner asked 4S or 6S; motor tops out at 4S |
| Link | RadioMaster RP1 V2 (ELRS) | sim used RP1 V1 |
| Video | RushFPV Tank Mini 800 mW (20x20, MMCX) + Caddx Ant + Foxeer Lollipop V4 Plus MMCX | not in the sim |
| Companion | XIAO ESP32S3 + 6x Pololu 3415 VL53L1X | from the sim |
| Hardware | M2 throughout: motor and plate screws M2x6, stack bolts M2x25 + nylock, 4x M2x20 standoffs, 8 gummies, strap, 470 uF 35 V cap, XT30U pigtail | |

Numbers: about 170 g without the frame. Add about 25 g for the frame and the total is about 195 g. Peak static thrust is 1379 g, so thrust to weight is about 7. Total parts cost is $476.86. The six Pololu ToF boards are $126.66 of that, and the build without the companion stack is about $340.

## Sim mismatches (sim/src/parts.rs, read only)

- **Battery voltage.** The sim flies 3S (GNB 3S 650, 60 g, `MOTOR_THRUST_3S_N` = 180 g, a V^2 estimate). This list is 4S: 79 g pack, 344.73 g per motor from the maker table at 15.64 V. The sim's thrust and mass constants need the 4S values.
- **Stack mass.** The sim uses 15.0 g. The maker page says 13.5 g for the stack, but its own board masses add up to 16.8 g (9.6 + 7.2), so the maker page contradicts itself. The maker page also marks the stack **discontinued**. NextFPV and WREKD still list it, and RDQ is out of stock.
- **Receiver.** The sim has RP1 at a 1.0 g estimate. The current RP1 V2 is 2.2 g with its antenna.
- **ToF sensors.** The sim uses a generic Amazon VL53L1X 3-pack at an estimated 1.5 g each, with no MPN. Pololu 3415 is 0.5 g with a datasheet, at $21.11 each.
- **Hardware lump.** The sim uses a 12 g estimate. Here it is split into rows (screws, standoffs, gummies, strap, cap, XT30). Wire, heatshrink, solder, the battery pad and the companion PCB are still not listed.
- **Missing parts.** The sim has no VTX, camera or video antenna. Those add about 9 g.

## Unconfirmed (measure or recheck before freezing the frame)

1. **F1404 shaft.** Resellers (KiwiQuads, Pyrodrone, Progressive RC) say 1.5 mm. The T-Motor/ligpower spec table says 2 mm. The prop hub (P1) depends on this.
2. **F1404 mount pattern.** 9x9 mm M2 comes from the sim and was not found on any maker page. The motor holes in the generative frame must wait for a measured sample.
3. **Motor screw length.** M2x6 assumes a 3 mm arm and about 3 mm of thread in the motor base. Too long a screw shorts the windings.
4. **Prop retention.** KiwiQuads calls the motor "T-mount". Whether the 3016 1.5 mm prop needs screws (and what size) or presses on was not confirmed, so no prop screws are listed.
5. **Battery dimensions.** 59x28x26 mm belongs to the RDQ-series 4S 650 80C. No dimensions were found for the GNB SKU.
6. **Caddx Ant** body depth and side screw thread. The camera input max is listed as 18 V by one source and 25 V by another, so power it from 5 V.
7. **Lollipop MMCX mass.** 2.8 g is the U.FL figure.
8. **RDQ M2 280-piece kit** length mix (M2x25 assumed).
9. **Strap width** (10 mm assumed), and the masses of the standoffs, nuts, gummies, cap and pigtail (estimates).
10. **Prices.** RaceDayQuads, Pyrodrone, WREKD, NextFPV and Lumenier pages hit rate limits (HTTP 429) or blocks (GetFPV 403) during this check. Their prices come from search-indexed copies of the retailer pages. Prices read live: RDQ stack $110.99 out of stock, Pyrodrone motor out of stock, the RMRC screws, Pololu, and the SpeedyBee maker page. Each offer's `stock_note` says which kind it is.
11. **Caddx Ant side holes, position.** The generated cage puts the two M2x3 screws (SCR3) at the body's middle, 7 mm behind the lens face (x 23.5 in the frame). That keeps their heads 3.25 mm from the front props' disks. Measure the camera before printing; a hole nearer the lens moves the screws into the 3 mm prop clearance.
12. **ToF mounting.** The up board sits on the tray's tail behind the battery, 0.4 mm up on two screw bosses that are not drawn. The down board lies on the plate under a hood of the cage, over the plate's window, with no screws. The side, front and rear boards sit on pads outside the cage walls. The wire holes from the boards into the cage are not drawn. Each one must stay 3.2 mm or under.
13. **Cage material against the boards.** The cage keeps 0.5 mm of air round the ESC, FC, VTX, receiver, XIAO and camera (the spec asks 1.0 mm; 0.5 is what fits between the props). PA12-CF conducts a little. Whether the boards need tape on the cage's inside is not checked.
14. **XT30 lead.** It leaves the rear bay through a slot 3.0 mm wide and 6 mm tall in the back wall. That assumes the two wires lie one above the other. Check the pigtail's wire size.

## Ordering notes

- Buy 2 or more prop packs, 2 motor screw packs plus 1 more (RMRC had only 2 left), and the gummy spares.
- C1 and GUM1 duplicate parts already in the STK1 box. They are listed so each part has a buyable SKU.
- If the build goes to 6S later, the motor (3-4S), the cap (35 V) and the camera supply all change. The stack and VTX already take 6S.
