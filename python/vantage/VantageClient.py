# python/vantage/VantageClient.py
# Python wrapper for VantageInterface C core library via ctypes.

import platform
import pathlib
import json
import numpy as np
import logging
from ctypes import CDLL, WinDLL, Structure, c_int, c_int16, c_float, byref, POINTER
from dataclasses import dataclass
from typing import Optional

logger = logging.getLogger("VantageClient")


class VantageError(Exception):
    def __init__(self, context: str, code: int, msg: str = ""):
        self.context = context
        self.code = code
        super().__init__(f"VantageInterface error in [{context}]: code {code} {msg}")


@dataclass
class AcqParams:
    num_angles: int = 1
    num_channels: int = 128
    samples_per_acq: int = 4096
    start_depth_wvl: float = 5.0
    end_depth_wvl: float = 128.0
    speed_of_sound: float = 1540.0
    num_frames: int = 10


class _CAcqParams(Structure):
    _fields_ = [
        ("num_angles",       c_int),
        ("num_channels",     c_int),
        ("samples_per_acq",  c_int),
        ("start_depth_wvl",  c_float),
        ("end_depth_wvl",    c_float),
        ("speed_of_sound",   c_float),
        ("num_frames",       c_int),
    ]


class _CRcvBuffer(Structure):
    _fields_ = [
        ("data",        POINTER(c_int16)),
        ("rows",        c_int),
        ("cols",        c_int),
        ("num_frames",  c_int),
        ("frame_index", c_int),
    ]


@dataclass
class RcvBuffer:
    data: np.ndarray   # shape (num_frames, rows, cols)
    rows: int
    cols: int
    num_frames: int
    frame_index: int


class VantageClient:
    """
    Python wrapper for the VantageInterface C shared library.

    Parameters
    ----------
    lib_path   : Path to libVantageInterface.dll / .so
    params     : AcqParams or path to config/scan_params.json
    """

    def __init__(self, lib_path: str, params: Optional[AcqParams] = None,
                 config_path: Optional[str] = None):
        if platform.system() == "Windows":
            self._lib = WinDLL(lib_path)
        else:
            self._lib = CDLL(lib_path)

        if config_path:
            cfg = json.loads(pathlib.Path(config_path).read_text())
            v = cfg["vantage"]
            self._params = AcqParams(
                num_angles       = v["num_angles"],
                num_channels     = v["num_channels"],
                samples_per_acq  = v["samples_per_acq"],
                start_depth_wvl  = v["start_depth_wvl"],
                end_depth_wvl    = v["end_depth_wvl"],
                speed_of_sound   = v["speed_of_sound_mps"],
                num_frames       = v["num_frames_realtime"],
            )
        else:
            self._params = params or AcqParams()

        self._initialized = False

    def initialize(self):
        cp = _CAcqParams(
            self._params.num_angles,
            self._params.num_channels,
            self._params.samples_per_acq,
            self._params.start_depth_wvl,
            self._params.end_depth_wvl,
            self._params.speed_of_sound,
            self._params.num_frames,
        )
        r = self._lib.Vantage_Initialize(byref(cp))
        self._check(r, "Vantage_Initialize")
        self._initialized = True
        logger.info("VantageClient initialized: %d ch x %d samples",
                    self._params.num_channels, self._params.samples_per_acq)

    def shutdown(self):
        if not self._initialized:
            return
        r = self._lib.Vantage_Shutdown()
        self._initialized = False
        self._check(r, "Vantage_Shutdown")

    def soft_trigger(self):
        self._check(self._lib.Vantage_SoftTrigger(), "Vantage_SoftTrigger")

    def wait_for_acquisition(self, timeout_s: float = 5.0):
        self._check(self._lib.Vantage_WaitForAcquisition(c_float(timeout_s)),
                    "Vantage_WaitForAcquisition")

    def copy_buffers(self):
        self._check(self._lib.Vantage_CopyBuffers(), "Vantage_CopyBuffers")

    def get_rcv_buffer(self, buf_index: int = 0) -> RcvBuffer:
        cb = _CRcvBuffer()
        self._check(self._lib.Vantage_GetRcvBuffer(c_int(buf_index), byref(cb)),
                    "Vantage_GetRcvBuffer")
        total = cb.rows * cb.cols * cb.num_frames
        arr = np.ctypeslib.as_array(cb.data, shape=(total,)).copy()
        arr = arr.reshape(cb.num_frames, cb.rows, cb.cols)
        return RcvBuffer(arr, cb.rows, cb.cols, cb.num_frames, cb.frame_index)

    def is_frozen(self) -> bool:
        return self._lib.Vantage_IsFrozen() == 1

    def __enter__(self):
        self.initialize()
        return self

    def __exit__(self, *_):
        self.shutdown()

    def _check(self, code: int, ctx: str):
        if code != 0:
            msg_fn = getattr(self._lib, "Vantage_GetErrorString", None)
            msg = msg_fn(code).decode() if msg_fn else ""
            raise VantageError(ctx, code, msg)
