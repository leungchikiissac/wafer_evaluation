# WaferEvalAPI Specification

High-level Python API for controlling the Vantage NXT ultrasound system and FMC4030 motion stage to perform automated wafer evaluation scans.

---

## Data Types

```python
@dataclass
class ScanDimension:
    x_extent_mm: float   # total scan length in X
    y_extent_mm: float   # total scan width in Y (number of lanes × lane spacing)
    x_step_mm:   float   # step size along X (sweep resolution)
    y_step_mm:   float   # lane spacing in Y (reposition increment)

@dataclass
class ScanResult:
    image:     np.ndarray   # 2D C-scan image (x positions × depth samples)
    save_path: str          # full path to saved .npy file
    metadata:  dict         # position, timestamp, dimension, acquisition params
```

---

## Class: `WaferEvalAPI`

Wraps `StageController`, `VantageClient`, and `ScanOrchestrator` into a single interface.

### Constructor

```python
WaferEvalAPI(stage_config: dict, acq_config: dict)
```

| Parameter | Description |
|-----------|-------------|
| `stage_config` | FMC4030 connection settings (IP, port, DLL path) |
| `acq_config`   | Vantage acquisition parameters (angles, channels, depth, speed of sound) |

---

### Methods

#### `connect() -> None`
Check that the Vantage NXT system is ready for acquisition and that the motion stage is connected. Raises `WaferEvalError` if either subsystem fails.

#### `disconnect() -> None`
Gracefully disconnect the stage and shut down the Vantage acquisition system.

#### `move_probe(x=None, y=None, z=None) -> Position`
Absolute move to the given coordinates in mm. Any axis can be omitted — omitted axes are not moved. Returns the resulting `Position` after the move completes.

#### `get_position() -> Position`
Return the current stage position without moving.

#### `b_mode() -> np.ndarray`
Acquire a single frame and return it as a 2D array for the operator to visually confirm the wafer is in view. Use this before `scan_region` to verify alignment.

#### `scan_region(dimension: ScanDimension, save_dir: str) -> ScanResult`
Scan the rectangular region defined by `dimension`, starting from the current stage position as the scan origin.

- Executes multiple sweeps in X, repositioning in Y between sweeps.
- Saves `cscan_<timestamp>.npy` (raw data) and `cscan_<timestamp>.png` (preview image) to `save_dir`.
- Returns a `ScanResult` containing the image, save path, and metadata.

| Parameter | Description |
|-----------|-------------|
| `dimension` | Region size and step sizes |
| `save_dir`  | Directory to write output files into |

---

## Error Hierarchy

```
WaferEvalError
├── StageError        motion fault, connection lost, position out of range
├── VantageError      acquisition failed, system not initialized
└── AlignmentError    requested position outside safe travel limits
```

---

## Workflow Examples

### Single wafer

```python
api = WaferEvalAPI(stage_config, acq_config)
api.connect()

api.move_probe(x=10.0, y=5.0)
frame = api.b_mode()            # operator confirms wafer is in view

result = api.scan_region(
    dimension=ScanDimension(x_extent_mm=60, y_extent_mm=41.4,
                            x_step_mm=0.05, y_step_mm=6.9),
    save_dir="data/wafer1"
)

api.disconnect()
```

### Multiple wafers

```python
api = WaferEvalAPI(stage_config, acq_config)
api.connect()

for i, origin in enumerate(wafer_origins):
    api.move_probe(x=origin.x, y=origin.y)
    frame = api.b_mode()        # operator confirms each wafer before scanning
    result = api.scan_region(dim, save_dir=f"data/wafer{i+1}")

api.disconnect()
```

### Reposition if wafer not in view

```python
frame = api.b_mode()
# operator inspects frame — if wafer not visible, adjust and retry
api.move_probe(x=api.get_position().x + 2.0)
frame = api.b_mode()
# once satisfied, proceed
result = api.scan_region(dim, save_dir="data/wafer1")
```

---

## Notes

- `scan_region` uses the current stage position as the scan origin — always call `move_probe` and confirm with `b_mode` before scanning.
- Output filenames are auto-generated as `cscan_<timestamp>.npy` / `.png` to avoid collisions across multi-wafer sessions. The exact path is returned in `ScanResult.save_path`.
- The motion step sizes in `ScanDimension` must match the hardware limits: `x_step_mm` ≥ 0.05 mm, sweep length 2–80 mm.
