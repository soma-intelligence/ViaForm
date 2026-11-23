//! Reference models shipped with the crate (`kin/models/*.json`).

use crate::model::Model;

/// JSON of the SO-101 class 6-axis desk arm (approximate dimensions, see its `note`).
pub const SO101_ARM_JSON: &str = include_str!("../models/so101_class_arm.json");
/// JSON of the five-finger reference hand (motors, a linkage and tendons).
pub const HAND5_JSON: &str = include_str!("../models/hand5.json");

/// The SO-101 class 6-axis arm with a spherical wrist; tool frame 0 is `gripper_tip`.
pub fn so101_arm() -> Model {
    Model::from_json(SO101_ARM_JSON).expect("reference arm model")
}

/// The five-finger hand; tool frames are `thumb_tip`, `index_tip`, `middle_tip`, `ring_tip`,
/// `pinky_tip`.
pub fn hand5() -> Model {
    Model::from_json(HAND5_JSON).expect("reference hand model")
}

/// A built-in model by name (`so101_arm`, `hand5`).
pub fn builtin(name: &str) -> Option<Model> {
    match name {
        "so101_arm" | "so101" | "arm" => Some(so101_arm()),
        "hand5" | "hand" => Some(hand5()),
        _ => None,
    }
}
