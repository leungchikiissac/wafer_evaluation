# Beamform Resume-Reset Bug: Root Cause & Recovery Plan

## What happened

The parallel beamform script (`beamform_fgcf_nsi_fast_parallel.m`) has a bug
that corrupts output files when a job is interrupted and resumed.

### Bug sequence

1. Job runs, checkpoints every 14 ei (CHECKPOINT_ROUNDS=2 × ROUND_SIZE=7).
2. Job is interrupted (power loss, crash, manual stop).
3. On resume, the script scans checkpoint files and **correctly reconstructs**
   ei 1..N into the output arrays in memory.
4. The xi loop then **unconditionally zeroes all output arrays** (line ~201)
   before starting work from ei N+1.
5. The final save writes ei 1..N as zeros and ei N+1..1200 as valid data.
6. Checkpoints are deleted — the only surviving copy of ei 1..N is gone.

### Fix (applied in commit `7ad7100`)

Guard the reset so it skips on the resumed xi:

```matlab
% Before fix:
for v = VAR_NAMES, eval([v{1} '(:) = 0;']); end

% After fix:
if ~(xi == last_xi && last_ei > 0)
    for v = VAR_NAMES, eval([v{1} '(:) = 0;']); end
end
```

---

## Affected files (this scan)

Diagnosed with the Step-0 check (per-ei energy in the BF output):

| xi | xloc (mm) | Zero prefix (ei) | Sweep range (mm) | Est. repair time |
|----|-----------|-----------------|------------------|-----------------|
| 3  | 13.8      | 1 – 110         | 0.00 – 5.50      | ~38 min (GPU)   |
| 5  | 27.6      | 1 – 710         | 0.00 – 35.50     | ~4.1 h (GPU)    |

xi = 4, 6, 7 are clean (ran in uninterrupted passes).

---

## Verification command

Run at the MATLAB prompt to confirm which ei are zero before and after repair:

```matlab
BF_DIR = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026\beamform';
xloc   = 0:6.9:41.4;
bfname = @(xi) fullfile(BF_DIR, ['RFBFbatch_multi_fgcf_nsi_single_step0.05mm_x', ...
          num2str(xloc(xi)), 'mm_angle1_0619_dc_both_ele_1_745_newinterp_lat2ax1_tukey.mat']);
for xi = [3 5]
    m = matfile(bfname(xi));
    blk = m.ps_data_ds(900:1100, :, :);
    e   = squeeze(sum(sum(abs(blk),1),2));
    f   = find(e > 0, 1, 'first');
    fprintf('xi=%d: first non-zero ei=%d (%.2f mm)  zero-prefix=%d ei\n', ...
            xi, f, (f-1)*0.05, f-1);
end
```

**Before repair:** `xi=3: first non-zero ei=111` / `xi=5: first non-zero ei=711`  
**After repair:**  both should show `first non-zero ei=1`

---

## Recovery steps

### Step 1 — Run the repair script

Open MATLAB, `cd` to the processing directory, then:

```matlab
repair_bf_missing_ei
```

The script (`matlab/processing/repair_bf_missing_ei.m`) will:

1. Load workspace and precompute bf_params.
2. Warm up the GPU persistent cache.
3. For each corrupted lane:
   - Load the raw RF `.txt` file.
   - Beamform only the missing ei using the GPU path.
   - Write each computed slice directly into the existing `.mat` via
     `matfile` partial HDF5 write — the valid tail ei are never loaded
     or overwritten.
4. Print progress every 10 ei with elapsed time and ETA.

Expected output:

```
GPU warmup...
GPU ready.

=== Repairing xi=3  ei=1..110 (110 ei) ===
  Raw RF loaded.
  ei=10/110  (210.3 s elapsed | 0.048 ei/s | ETA 35 min)
  ...
  xi=3 repair done in 38.2 min.

=== Repairing xi=5  ei=1..710 (710 ei) ===
  ...
  xi=5 repair done in 247.6 min.

=== Repair complete ===
Run the Step-0 diagnostic again to verify zero prefix is gone.
```

### Step 2 — Verify

Re-run the verification command above. Both xi should report
`first non-zero ei=1`.

### Step 3 — Re-run display

```matlab
display_cscan_beamformed
```

The black patches at xi=3 (0–5.5 mm) and xi=5 (0–35.5 mm) should be gone.

---

## Prevention

The code fix is already committed. Future interrupted jobs will resume
correctly with no zeroed prefix.

As an additional safeguard, consider delaying checkpoint deletion until
the final `.mat` has been verified non-zero — then a bad save is
still recoverable from checkpoints.
