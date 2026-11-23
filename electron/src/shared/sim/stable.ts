// Written by scripts/train-stabilize.mjs: do not edit. Held-out cost on the realistic plant, half
// tracking and half disturbance rejection (lower is better): default PID 14.955,
// first training 6.030, retuned PID 4.122, retuned INDI 2.833.

import type { Gains } from "./control";

export const STABLE_PID: Gains = {"posP":3.62516,"velP":8.92652,"velI":1.09006,"velD":0.06778,"attP":36.19457,"yawP":4.02529,"rateP":78.78748,"rateI":36.39823,"rateD":0.00971,"yawRateP":9.09003};

export const STABLE_INDI: Gains = {"posP":2.37747,"velP":11.45894,"velI":3.9345,"velD":0.03859,"attP":16.91819,"yawP":2.21109,"rateP":43.77473,"rateI":15.22445,"rateD":0.00864,"yawRateP":9.65438};

export const STABLE_SCORE = {"defaultPid":14.95496,"trainedPid":6.02965,"stablePid":4.12191,"stableIndi":2.83311};
