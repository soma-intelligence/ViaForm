//! The parts of the 3-inch drone, all sold on amazon.com, with the figures the simulation uses.
//! Listings were found through search results limited to amazon.com (Amazon blocks automated page
//! reads), so check price, stock and the exact variant (KV, shaft, pack count) before ordering.

#[derive(Clone, Copy, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Part {
    pub role: &'static str,
    pub name: &'static str,
    pub qty: u32,
    pub mass_g: f64, // each
    pub url: &'static str,
    pub specs: &'static str,
    /// Where the figure comes from: "listing", "datasheet", "measured" (by a reviewer) or "estimate".
    pub source: &'static str,
}

pub const PARTS: [Part; 9] = [
    Part { role: "Flight controller + 4-in-1 ESC", name: "SpeedyBee F405 Mini stack (BLS 35A)", qty: 1, mass_g: 15.0, url: "https://www.amazon.com/dp/B0FC6F388B", specs: "20×20 mm, 3–6S, 35 A per motor, F405, baro; UART1/2/3/6 free (ELRS, MSP to the ESP32)", source: "measured (Oscar Liang)" },
    Part { role: "Motors", name: "T-Motor F1404 4600KV", qty: 4, mass_g: 9.34, url: "https://www.amazon.com/dp/B0GJZ4MFV7", specs: "9×9 M2 mount, 1.5 mm shaft; 344.7 g at 4S on GF3016 (maker table), ≈180 g at 3S (V² scaling)", source: "datasheet + estimate for 3S" },
    Part { role: "Propellers", name: "Gemfan 3016 tri-blade (16 pcs)", qty: 4, mass_g: 1.18, url: "https://www.amazon.com/dp/B09PTK8XT1", specs: "3 in, 1.6 in pitch, 1.5 mm hole", source: "listing" },
    Part { role: "Battery", name: "GAONENG GNB 650 mAh 3S 80C XT30", qty: 1, mass_g: 60.0, url: "https://www.amazon.com/dp/B097SJVQXX", specs: "11.1 V, 80C continuous; 55×30×17 mm class", source: "listing" },
    Part { role: "Receiver", name: "RadioMaster RP1 ELRS 2.4 GHz", qty: 1, mass_g: 1.0, url: "https://www.amazon.com/dp/B0BZY2M4BS", specs: "CRSF, T antenna", source: "estimate" },
    Part { role: "Companion computer", name: "Seeed Studio XIAO ESP32S3", qty: 1, mass_g: 3.0, url: "https://www.amazon.com/dp/B0BYSB66S5", specs: "21×17.5 mm, dual core 240 MHz; runs the planner and the obstacle detection, talks MSP to the FC", source: "estimate" },
    Part { role: "Distance sensors", name: "VL53L1X time-of-flight (3-packs)", qty: 6, mass_g: 1.5, url: "https://www.amazon.com/dp/B0D4S3YG26", specs: "4 cm–4 m indoors, 27° field, 50 Hz, I2C 0x29; one XSHUT GPIO each to set addresses at boot", source: "listing" },
    Part { role: "Frame", name: "ViaForm generative frame (3 mm carbon plate, cut to the DXF)", qty: 1, mass_g: 0.0, url: "", specs: "designed by generative.ts; mass from the CAD", source: "CAD" },
    Part { role: "Wiring, screws, standoffs, strap, XT30, companion PCB", name: "Assorted hardware", qty: 1, mass_g: 12.0, url: "", specs: "", source: "estimate" },
];

/// 3S thrust of one motor at full throttle (N): 180 g, from the 4S table scaled by (11.1/15.6)².
pub const MOTOR_THRUST_3S_N: f64 = 0.18 * 9.81;

pub fn parts_mass_kg(frame_g: f64) -> f64 {
    PARTS.iter().map(|p| p.qty as f64 * if p.role == "Frame" { frame_g } else { p.mass_g }).sum::<f64>() / 1000.0
}
