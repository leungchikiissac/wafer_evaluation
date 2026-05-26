# python/orchestration/ScanOrchestrator.py
# Coordinates the motion stage and Vantage ultrasound system for wafer scanning.

import json
import pathlib
import logging
import datetime
import numpy as np
from typing import Optional

logger = logging.getLogger("ScanOrchestrator")


class ScanOrchestrator:
    """
    Coordinates a step-and-shoot wafer scan:
      1. Move stage one step (X-axis, relative)
      2. Trigger Vantage acquisition
      3. Wait for acquisition to complete
      4. Copy buffers and store frame

    Parameters
    ----------
    stage      : StageController instance (already connected)
    vantage    : VantageClient instance (already initialized)
    config_path: path to config/scan_params.json
    """

    def __init__(self, stage, vantage, config_path: Optional[str] = None):
        self._stage   = stage
        self._vantage = vantage

        if config_path:
            cfg = json.loads(pathlib.Path(config_path).read_text())
            sc  = cfg["scan"]
            sv  = cfg["save"]
            self._step_mm    = float(sc["step_mm"])
            self._range_mm   = float(sc["range_mm"])
            self._base_dir   = pathlib.Path(sv["base_dir"])
            self._prefix     = sv["filename_prefix"]
        else:
            self._step_mm  = 0.05
            self._range_mm = 60.0
            self._base_dir = pathlib.Path(".")
            self._prefix   = "RFbatch"

        self._num_steps = int(round(self._range_mm / self._step_mm))

    @property
    def num_steps(self) -> int:
        return self._num_steps

    def run(self) -> np.ndarray:
        """
        Execute full scan, return collected RF data array.

        Returns
        -------
        np.ndarray : shape (num_steps, rows, cols) int16 RF data
        """
        from stage import Axis

        logger.info("Starting scan: %d steps x %.3f mm = %.1f mm total",
                    self._num_steps, self._step_mm, self._range_mm)

        frames = []

        for step in range(self._num_steps):
            logger.info("Step %d / %d", step + 1, self._num_steps)

            # 1. Move stage
            self._stage.move(Axis.X, self._step_mm)

            # 2. Trigger acquisition
            self._vantage.soft_trigger()
            self._vantage.wait_for_acquisition(timeout_s=2.0)
            self._vantage.copy_buffers()

            # 3. Retrieve latest frame from batch buffer (index 1)
            buf = self._vantage.get_rcv_buffer(buf_index=1)
            frames.append(buf.data[buf.frame_index].copy())

        data = np.stack(frames, axis=0)
        logger.info("Scan complete: data shape %s", data.shape)
        self._save(data)
        return data

    def _save(self, data: np.ndarray):
        today = datetime.date.today().strftime("%d-%B-%Y")
        out_dir = self._base_dir / today
        out_dir.mkdir(parents=True, exist_ok=True)

        stem = f"{self._prefix}_{today}"
        txt_path  = out_dir / f"{stem}.txt"
        size_path = out_dir / f"{stem}_size.npy"

        data.tofile(str(txt_path))
        np.save(str(size_path), np.array(data.shape))
        logger.info("Saved RF data -> %s", txt_path)
        logger.info("Saved size    -> %s", size_path)
