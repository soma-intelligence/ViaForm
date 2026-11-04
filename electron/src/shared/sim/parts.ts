// The parts of the 3-inch drone, all sold on amazon.com, with the figures the simulation uses.
// Listings were found through search results limited to amazon.com (Amazon blocks automated page
// reads), so check price, stock and the exact variant (KV, shaft, pack count) before ordering.

export type Part = {
  role: string;
  name: string;
  qty: number;
  massG: number; // each
  url: string;
  specs: string;
  /** Where the figure comes from: "listing", "datasheet", "measured" (by a reviewer) or "estimate". */
  source: string;
};

export const PARTS: Part[] = [
  { role: "Flight controller + 4-in-1 ESC", name: "SpeedyBee F405 Mini stack (BLS 35A)", qty: 1, massG: 15, url: "https://www.amazon.com/dp/B0FC6F388B", specs: "20×20 mm, 3–6S, 35 A per motor, F405, baro; UART1/2/3/6 free (ELRS, MSP to the ESP32)", source: "measured (Oscar Liang)" },
  { role: "Motors", name: "T-Motor F1404 4600KV", qty: 4, massG: 9.34, url: "https://www.amazon.com/dp/B0GJZ4MFV7", specs: "9×9 M2 mount, 1.5 mm shaft; 344.7 g at 4S on GF3016 (maker table), ≈180 g at 3S (V² scaling)", source: "datasheet + estimate for 3S" },
  { role: "Propellers", name: "Gemfan 3016 tri-blade (16 pcs)", qty: 4, massG: 1.18, url: "https://www.amazon.com/dp/B09PTK8XT1", specs: "3 in, 1.6 in pitch, 1.5 mm hole", source: "listing" },
  { role: "Battery", name: "GAONENG GNB 650 mAh 3S 80C XT30", qty: 1, massG: 60, url: "https://www.amazon.com/dp/B097SJVQXX", specs: "11.1 V, 80C continuous; 55×30×17 mm class", source: "listing" },
  { role: "Receiver", name: "RadioMaster RP1 ELRS 2.4 GHz", qty: 1, massG: 1, url: "https://www.amazon.com/dp/B0BZY2M4BS", specs: "CRSF, T antenna", source: "estimate" },
  { role: "Companion computer", name: "Seeed Studio XIAO ESP32S3", qty: 1, massG: 3, url: "https://www.amazon.com/dp/B0BYSB66S5", specs: "21×17.5 mm, dual core 240 MHz; runs the planner and the obstacle detection, talks MSP to the FC", source: "estimate" },
  { role: "Distance sensors", name: "VL53L1X time-of-flight (3-packs)", qty: 6, massG: 1.5, url: "https://www.amazon.com/dp/B0D4S3YG26", specs: "4 cm–4 m indoors, 27° field, 50 Hz, I2C 0x29; one XSHUT GPIO each to set addresses at boot", source: "listing" },
  { role: "Frame", name: "ViaForm generative frame (3 mm carbon plate, cut to the DXF)", qty: 1, massG: 0, url: "", specs: "designed by generative.ts; mass from the CAD", source: "CAD" },
  { role: "Wiring, screws, standoffs, strap, XT30, companion PCB", name: "Assorted hardware", qty: 1, massG: 12, url: "", specs: "", source: "estimate" },
];

/** 3S thrust of one motor at full throttle (N): 180 g, from the 4S table scaled by (11.1/15.6)². */
export const MOTOR_THRUST_3S_N = 0.18 * 9.81;

export const partsMassKg = (frameG: number) => PARTS.reduce((s, p) => s + p.qty * (p.role === "Frame" ? frameG : p.massG), 0) / 1000;
