# ViaForm robot link protocol

Version 0.1, 2026-11-07. Task P7-2 of `VIAFORM-SPEC.md`. Implemented by the Rust crate `robot/`
(`viaform-robot`), bridge `vf_robot_*`. Servos: Feetech STS3215 (RUST-ENGINES E-17).

**Every register address and value in section 3 must be checked against the Feetech STS3215
datasheet and memory table before implementation.** They are written from public open-source driver
tables and may differ between firmware versions.

## 1. Two link modes

| Mode | Path | Platforms | Watchdog | Use |
|---|---|---|---|---|
| A. Direct bus | Mac USB, then a USB to half-duplex TTL bus adapter, then the servo bus | macOS only (iPadOS has no generic USB serial) | Host only | First arm, bench work |
| B. Bridge | Mac or iPad, then USB CDC or Wi-Fi, then ESP32-S3 running ViaForm bridge firmware, then the servo bus | macOS, iPadOS | Firmware, 200 ms | iPad, wireless, all later robots (drone: section 9) |

### Safety consequence of mode A (read this)

In mode A nothing on the robot side notices if the Mac app crashes or the cable is pulled: the servos
hold their last goal with torque on. Therefore mode A **requires a physical emergency stop switch that
cuts servo power** (latching mushroom button on the servo supply line), and the app refuses to enable
torque until the user has ticked "Physical e-stop installed" for this device profile. Mode B adds a
firmware watchdog that removes torque within 200 ms of silence, but the physical switch stays
recommended.

## 2. Layers

```
App (Swift)  ->  vf_robot_call(json)      high level: connect, read, command, estop, record, run_policy
robot crate  ->  Device trait             one per link mode
             ->  Safety layer             limits, fence, torque cap, rate limit, watchdog (host side)
             ->  Transport                Mode A: Feetech packet protocol over serial
                                          Mode B: ViaForm frame protocol (section 4) over CDC or UDP
```

The safety layer sits below the API: no call path can send a goal without passing through it.

## 3. Mode A: Feetech STS bus (half duplex, 1 Mbaud default)

### 3.1 Packet format

```
Instruction:  0xFF 0xFF  ID  LEN  INSTR  PARAM...  CHECKSUM
Status:       0xFF 0xFF  ID  LEN  ERROR  PARAM...  CHECKSUM
LEN      = number of PARAM bytes + 2
CHECKSUM = ~(ID + LEN + INSTR/ERROR + sum(PARAM)) & 0xFF
ID 0xFE  = broadcast (no status reply)
```

Instructions used: `PING 0x01`, `READ 0x02`, `WRITE 0x03`, `SYNC_READ 0x82`, `SYNC_WRITE 0x83`.
Multi-byte values are little-endian in the STS series (verify; the older SCS series is big-endian).

### 3.2 Registers used (verify against the datasheet)

| Name | Address | Size | Access | Notes |
|---|---|---|---|---|
| ID | 5 | 1 | EEPROM | Set once during setup, lock off first |
| Baud rate | 6 | 1 | EEPROM | Keep default (1 Mbaud) |
| Min angle limit | 9 | 2 | EEPROM | Written from Assemble joint limits plus calibration |
| Max angle limit | 11 | 2 | EEPROM | Same |
| Max torque limit | 16 | 2 | EEPROM | Safety cap, scaled 0 to 1000 |
| P, D, I coefficients | 21, 22, 23 | 1 each | EEPROM | Defaults unless system identification says otherwise |
| Homing offset | 31 | 2 | EEPROM | From calibration |
| Torque enable | 40 | 1 | RAM | 0 off, 1 on |
| Acceleration | 41 | 1 | RAM | Profile acceleration |
| Goal position | 42 | 2 | RAM | 0 to 4095 over 360 degrees |
| Goal time | 44 | 2 | RAM | Not used (0) |
| Goal speed | 46 | 2 | RAM | Speed cap |
| Lock | 55 | 1 | RAM | 0 to write EEPROM, 1 to protect |
| Present position | 56 | 2 | RO | |
| Present speed | 58 | 2 | RO | Sign bit encoding, verify |
| Present load | 60 | 2 | RO | |
| Present voltage | 62 | 1 | RO | 0.1 V units |
| Present temperature | 63 | 1 | RO | Degrees C |
| Moving | 66 | 1 | RO | |
| Present current | 69 | 2 | RO | Units per datasheet |

### 3.3 Control loop (50 Hz default, 100 Hz max)

Each tick:
1. `SYNC_READ` present position, speed, load, current for all IDs (one transaction).
2. Every 10th tick: `SYNC_READ` voltage and temperature.
3. Safety layer checks the new goals (section 5).
4. `SYNC_WRITE` goal position (and goal speed when it changed) for all IDs.
5. Timestamp and push telemetry to the app's `LatestBuffer`.

Budget per tick at 1 Mbaud with 6 servos: about 1.5 ms of bus time. Retries: one retry on checksum or
timeout (3 ms), then mark the servo "no reply"; two consecutive misses on any servo trigger a soft
stop (hold position, then torque off after 500 ms if still missing).

### 3.4 Setup and calibration

1. **Assign IDs:** connect one servo at a time, PING broadcast, write ID 1 to 6 (lock off, write, lock on).
2. **Calibrate:** user moves the arm by hand (torque off) to the reference pose shown in the twin, then
   to each joint's limits; the app records raw positions, computes homing offsets and directions,
   and writes angle limits with a 2 degree margin inside the Assemble limits.
3. Calibration stored in `robot/device.json` in the project (section 6).

## 4. Mode B: ViaForm bridge frames

Transport: USB CDC serial on macOS, or UDP over Wi-Fi on macOS and iPadOS with the device on the
same network (mDNS name `viaform-<serial>.local`). iPadOS has no generic USB serial access, so the
iPad always uses Wi-Fi. Pairing: a 6-digit code shown on the
device's serial log or LED pattern, exchanged for a per-device key (stored in Keychain), then every
frame is authenticated with HMAC-SHA256 truncated to 16 bytes.

```
Frame: MAGIC(0x56 0x46) VER(1) TYPE(1) SEQ(u16) LEN(u16) PAYLOAD(LEN) MAC(16) CRC16
```

| Type | Direction | Payload |
|---|---|---|
| `HELLO` 0x01 | both | firmware version, servo count, capabilities |
| `ARM` 0x02 | host to device | enable torque, torque cap per joint, fence limits |
| `GOALS` 0x03 | host to device | timestamp, n x (joint id u8, goal i16 in 0.1 degree, speed cap u16) |
| `STATE` 0x10 | device to host | timestamp, n x (position, speed, load, current), voltage, temperature max, flags |
| `ESTOP` 0x20 | host to device | none; device sets torque off on all servos, latches, replies `STATE` with flag |
| `CLEAR` 0x21 | host to device | clears a latched e-stop (needs `ARM` again) |
| `FAULT` 0x30 | device to host | code (overheat, overload, voltage, no reply, watchdog), joint |
| `PING` 0x40 | both | keepalive at 10 Hz when idle |

Firmware rules: watchdog 200 ms without a valid `GOALS` or `PING` sets torque off and latches;
goals outside the armed fence are clamped and reported; e-stop is handled in the receive interrupt path,
not the main loop.

## 5. Safety layer (host side, both modes)

| Check | Action |
|---|---|
| Joint limits (Assemble limits minus margin) | Clamp goal, flag |
| Cartesian fence (box in `device.json`) | FK of the goal; if outside, hold last valid goal, flag |
| Speed cap (session, default 30 percent) | Limit goal step per tick |
| Torque cap (default 60 percent) | Written to max torque limit on arm, re-checked each session |
| Temperature over 65 degrees C on any servo | Slow to 10 percent, warn; over 70 degrees C soft stop |
| Voltage outside supply range | Soft stop |
| No telemetry for 100 ms | Soft stop (host watchdog) |
| Policy output | Same checks; plus a jump limit (no goal more than 10 degrees from present position) |
| E-stop (button, Space, double Esc) | Mode A: broadcast `WRITE torque enable = 0` immediately, repeat 3 times; Mode B: `ESTOP` frame, repeated until acknowledged. Target under 20 ms to torque off |

All checks and all triggered actions are logged with timestamps in the session record.

## 6. Device profile (`robot/device.json`, `viaform-robot` v1)

```json
{
  "format": "viaform-robot", "version": 1,
  "name": "Desk Arm 01", "link": {"mode": "direct", "port_hint": "usbserial", "baud": 1000000},
  "physical_estop_confirmed": true,
  "joints": [
    {"joint": "shoulder_pan", "servo_id": 1, "direction": 1, "offset_raw": 2048,
     "limit_deg": [-110, 110], "torque_cap_pct": 60}
  ],
  "fence": {"min_m": [-0.35, -0.35, 0.0], "max_m": [0.35, 0.35, 0.45]},
  "rates": {"control_hz": 50, "telemetry_hz": 50}
}
```

## 7. Recording format

Demonstrations are LeRobot-compatible datasets (VIAFORM-SPEC D-4) written under
`<Project>.viaform-data/demos/`: per episode, joint states and actions at the control rate, camera
frames as video files, and episode metadata (task, success flag, operator, device profile hash).
Exact dataset version to pin when task P7-5 starts.

## 8. Tests

| Test | Pass |
|---|---|
| Packet encode and decode, checksum | Unit tests with recorded byte strings |
| Simulated bus (mock servos in Rust) | Control loop, retries, soft stop, e-stop timings |
| Safety layer | 100 percent branch coverage (VIAFORM-SPEC 13) |
| Hardware e-stop timing | Logic analyser or firmware timestamps: torque off under 20 ms, 20 trials |
| Mode B watchdog | Pull Wi-Fi: torque off under 250 ms |

## 9. Drone link (decision D-26)

### 9.1 Principle

ViaForm never commands drone motors. An ArduPilot flight controller runs the rate, attitude and
position loops and all failsafes. ViaForm is an offboard companion that sends setpoints and reads
telemetry. A trained drone policy outputs velocity or attitude setpoints, never motor values.

### 9.2 Path

```
Mac or iPad  --UDP, MAVLink 2 signed-->  ESP32-S3 on the drone (MAVLink router)  --UART 921600-->  flight controller
RC transmitter  --------------------------------------------------------------->  RC receiver on the flight controller
```

- Messages used: `HEARTBEAT` (1 Hz both ways), `SET_POSITION_TARGET_LOCAL_NED` (velocity or position
  setpoint, 50 Hz), `SET_ATTITUDE_TARGET` (attitude and thrust, 50 Hz, cage tests only),
  `ATTITUDE`, `LOCAL_POSITION_NED`, `BATTERY_STATUS`, `SYS_STATUS`, `STATUSTEXT`, `COMMAND_LONG`
  (arm, disarm, set mode, land).
- MAVLink 2 message signing on, key exchanged during pairing (same flow as section 4).
- Position source indoors: optical flow plus rangefinder, or an external motion capture feed
  if available. GPS outdoors.

### 9.3 Failsafes (checked by the app on every connect)

The app reads these flight controller parameters and refuses to switch to offboard (GUIDED)
mode if any differs from the device profile:

| Event | Required behaviour |
|---|---|
| Companion link lost 500 ms | Flight controller holds position (brake), then lands after 2 s |
| RC signal lost | Land (RC failsafe) |
| Battery below reserve | Land |
| Geofence breach (cylinder radius and altitude from `device.json`) | Brake, then land |
| RC mode switch to manual or kill switch | Always overrides ViaForm immediately |

### 9.4 Flight rules

1. Bench tests with props off before any flight.
2. First flights in an indoor net cage; the pilot holds the RC transmitter for every flight.
3. Outdoor flights only after registration and local rules are checked (VIAFORM-SPEC open question 4).
4. "Run on drone" needs the confirm sheet of VIAFORM-SPEC 7.9 plus a pre-flight checklist (props,
   battery, geofence, failsafe parameters read back).
5. Every flight writes a log (MAVLink telemetry and setpoints) to `<Project>.viaform-data/flights/`.

### 9.5 Tests

| Test | Pass |
|---|---|
| ArduPilot SITL link loss | Hold then land within the times in 9.3 |
| Parameter check | Wrong failsafe parameter blocks GUIDED mode |
| Setpoint rate | 50 Hz plus or minus 5 percent over 10 minutes on Wi-Fi |
| Signing | Unsigned or wrongly signed messages ignored by the router |
