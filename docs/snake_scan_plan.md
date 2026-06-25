# Snake (Boustrophedon) Scan Implementation Plan

## Core idea
A single base-workspace variable `sweepDir` (+1 or -1) is set before each VSX launch and read by all moving parts. Reposition between lanes becomes a lateral-only Y step (6.9 mm) — no X return.

---

## Step 1 — Publish `sweepDir` to base workspace (`ScanControlPanel.m`)

In `onLaunchVSX()`, alongside the existing `sweepLateralY_mm` assignment, add:

```matlab
sweepDir = 1 - 2*mod(sweepsDone, 2);  % lane 1→+1, lane 2→-1, lane 3→+1 ...
assignin('base', 'sweepDir', sweepDir);
```

This is the single source of truth — everything else reads from here.

---

## Step 2 — Apply direction in the per-step X motion (`move3dstage.m`) ← main change

The sweep direction lives here, not in the SetUp script's Event loop. Change the hardcoded `stage.moveX(0.05)` to:

```matlab
try
    sweepDir = evalin('base', 'sweepDir');
catch
    sweepDir = 1;   % default forward for manual/legacy launches
end
stage.moveX(sweepDir * 0.05);
```

No change needed to the batch Event generation in the SetUp scripts — `loc_num` and the number of acquisitions are identical in both directions.

---

## Step 3 — Lateral-only reposition (`repositionProbe.m`)

Remove the `stage.moveX(-60)` block entirely. Keep only the `stage.moveY(-6.9)` lateral step:

```matlab
fprintf('Advancing Y-axis: -6.9 mm (lateral step, snake pattern)\n');
stage.moveY(-6.9);
stage.printPosition();
```

After a forward lane the probe sits at X=60; after a reverse lane at X=0 — both are correct starting positions for the next sweep.

---

## Step 4 — Tag RF filenames with direction (`saveRF_wafer_txt.m`)

Add `_fwd` / `_rev` to the filename so downstream C-scan processing can determine orientation without re-deriving parity.

```matlab
try
    sweepDir = evalin('base', 'sweepDir');
catch
    sweepDir = 1;
end
dirTag = 'fwd'; if sweepDir < 0, dirTag = 'rev'; end
% Insert dirTag into RFfilename after lateralTag
```

---

## Step 5 — Orient reverse-lane RF data consistently (`cscan_surface_guided.m`)

Reverse lanes arrive spatially mirrored (acquired 60→0mm). After `reshape`, flip the scan-position dimension for `_rev` files:

```matlab
if contains(txt_file, '_rev')
    RFdata = flip(RFdata, 3);   % dim 3 = n_acq = scan position; restore 0→60 order
end
```

This keeps all per-lane C-scans in canonical orientation for future lane stitching.

---

## Step 6 — Tests / mock (`SetUpMock.m`, `TestMockGui.m`)

The `try/catch` defaults in Steps 2–4 cover mock runs automatically. Add assertions:
- `sweepDir` alternates +1, -1, +1, ... across successive VSX launches
- X position is unchanged after `onReposition` (only Y moved)

---

## Implementation order

Steps 1 → 2, 3, 4 (parallel) → 5 → 6

---

## Unknowns to verify on hardware before implementing

1. **X soft limits** — confirm the stage can *start* a sweep at X=60 mm (previously every lane always started at X=0).

2. **Cumulative X drift** — the old `moveX(-60)` coarse return corrected accumulated drift from 1200 small steps. With the snake pattern X is never re-homed by a large move. Verify drift over a full forward+reverse cycle stays within tolerance, or add periodic absolute re-homing.

3. **Off-by-one at sweep end** — reconcile that `ele_dis = 0:0.05:59.95` (1200 steps) lands the probe at exactly X=60 so forward/reverse endpoints align correctly.

---

## Reference

- Animation (raster): `docs/scan_animation.html`
- Animation (snake): `docs/scan_animation_snake.html`
