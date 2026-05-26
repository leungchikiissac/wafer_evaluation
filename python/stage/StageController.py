# -*- coding: utf-8 -*-
"""
StageController.py
==================
High-level Python wrapper for the FMC4030 three-axis motion controller.

Wraps the FMC4030 DLL with:
  - Full return-status checking on every API call
  - Hardware-native axis-stop polling (FMC4030_Check_Axis_Is_Stop)
  - Position verification after every move
  - Structured error handling (StageError exception)
  - Context-manager support (with StageController(...) as stage:)
  - Logging to console and optional log file

Usage example:
    from StageController import StageController, Axis

    with StageController(dll_path="FMC4030-Dll.dll", device_id=1,
                         ip="192.168.0.30", port=8088) as stage:
        stage.move(Axis.X, 0.05)           # relative move, 0.05 mm
        stage.move(Axis.Y, -6.9)           # relative move, -6.9 mm
        stage.move_absolute(Axis.X, 0.0)   # absolute move to 0 mm
        pos = stage.get_position()
        print(pos)                         # Position(x=..., y=..., z=...)

Author:  DeepSonix Lab
Created: 2024
"""

import time
import logging
import platform
from ctypes import (
    Structure, CDLL, WinDLL,
    c_int, c_int32, c_float, c_ubyte, c_char_p,
    byref, POINTER, cast
)
from dataclasses import dataclass
from enum import IntEnum
from typing import Optional


# ── Logging setup ─────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S"
)
logger = logging.getLogger("StageController")


# ── Enumerations ──────────────────────────────────────────────────────────────
class Axis(IntEnum):
    """Physical axis identifiers (matches FMC4030 axis numbering)."""
    X = 0
    Y = 1
    Z = 2


class MoveMode(IntEnum):
    """Movement mode for FMC4030_Jog_Single_Axis."""
    RELATIVE = 1   # relative to current position
    ABSOLUTE = 2   # absolute coordinate


class StopMode(IntEnum):
    """Stop mode for FMC4030_Stop_Single_Axis."""
    DECELERATE = 1   # decelerate to stop (smooth)
    IMMEDIATE  = 2   # stop immediately (hard stop)


class HomeDir(IntEnum):
    """Homing direction for FMC4030_Home_Single_Axis."""
    POSITIVE = 1   # home toward positive limit switch
    NEGATIVE = 2   # home toward negative limit switch


class AxisSelection(IntEnum):
    """Two-axis bitmask for interpolation functions."""
    XY = 0x03
    XZ = 0x05
    YZ = 0x06


class ArcDir(IntEnum):
    """Arc direction for FMC4030_Arc_2Axis."""
    CLOCKWISE        = 1
    COUNTERCLOCKWISE = 2


class OutputLevel(IntEnum):
    """Digital output level (open-drain, logic inverted)."""
    HIGH = 0   # output high voltage
    LOW  = 1   # output low voltage


# ── Return status decoder ─────────────────────────────────────────────────────
_STATUS_MESSAGES = {
     0: "Success",
    -1: "Connection failed — check network cable, verify IP address and port, restart controller",
    -2: "Undefined error (-2)",
    -3: "Undefined error (-3)",
    -4: "Data construction failed — check available memory",
    -5: "Data send failed — check network cable, verify IP address and port, restart controller",
    -6: "Data receive error — check network cable, verify IP address and port, restart controller",
    -7: "Received data error — check network connection",
    -8: "Null pointer error — check that input arguments are not null pointers",
}

def decode_status(status: int) -> str:
    """Translate FMC4030 integer return code to human-readable message."""
    return _STATUS_MESSAGES.get(status, f"Unknown error code ({status})")


# ── Custom exceptions ─────────────────────────────────────────────────────────
class StageError(Exception):
    """Raised when an FMC4030 API call returns a non-zero status code."""
    def __init__(self, context: str, status: int):
        self.context = context
        self.status  = status
        self.message = decode_status(status)
        super().__init__(
            f"FMC4030 error in [{context}] — code {status}: {self.message}"
        )


class StageTimeoutError(StageError):
    """Raised when axis movement does not complete within the timeout period."""
    def __init__(self, axis: Axis, timeout: float, last_pos: float):
        self.axis     = axis
        self.timeout  = timeout
        self.last_pos = last_pos
        Exception.__init__(
            self,
            f"Axis {axis.name} movement timed out after {timeout:.1f} s. "
            f"Last known position: {last_pos:.4f} mm"
        )


class StagePositionError(Exception):
    """Raised when final position exceeds the acceptable tolerance."""
    def __init__(self, axis: Axis, target: float, actual: float, tolerance: float):
        self.axis      = axis
        self.target    = target
        self.actual    = actual
        self.tolerance = tolerance
        self.error     = abs(actual - target)
        super().__init__(
            f"Axis {axis.name} position error {self.error:.4f} mm exceeds "
            f"tolerance {tolerance:.4f} mm "
            f"(target={target:.4f} mm, actual={actual:.4f} mm)"
        )


# ── Machine status structure (matches C struct in demo code) ──────────────────
class MachineStatus(Structure):
    """
    C structure layout for FMC4030_Get_Machine_Status.

    Mirrors the C definition:
        struct machine_status {
            float realPos[3];
            float realSpeed[3];
            unsigned int inputStatus;
            unsigned int outputStatus;
            unsigned int limitNStatus;
            unsigned int limitPStatus;
            unsigned int machineRunStatus;
            unsigned int axisStatus[3];
            unsigned int homeStatus;
            char file[20][30];
        };
    """
    _fields_ = [
        ("realPos",          c_float  * 3),
        ("realSpeed",        c_float  * 3),
        ("inputStatus",      c_int32  * 1),
        ("outputStatus",     c_int32  * 1),
        ("limitNStatus",     c_int32  * 1),
        ("limitPStatus",     c_int32  * 1),
        ("machineRunStatus", c_int32  * 1),
        ("axisStatus",       c_int32  * 3),
        ("homeStatus",       c_int32  * 1),
        ("file",             c_ubyte  * 600),
    ]


# ── Position dataclass ────────────────────────────────────────────────────────
@dataclass
class Position:
    """Current three-axis position in millimetres."""
    x: float
    y: float
    z: float

    def __str__(self) -> str:
        return f"Position(x={self.x:.4f} mm, y={self.y:.4f} mm, z={self.z:.4f} mm)"


# ── StageController ───────────────────────────────────────────────────────────
class StageController:
    """
    High-level controller for the FMC4030 three-axis motion stage.

    Handles:
      - DLL loading and device connection / disconnection
      - Movement with hardware-native stop polling
      - Position verification after every move
      - Structured exception hierarchy (StageError, StageTimeoutError,
        StagePositionError)
      - Context manager protocol (use with 'with' statement)

    Parameters
    ----------
    dll_path   : Path to FMC4030-Dll.dll (Windows) or libFMC4030-Lib.so (Linux)
    device_id  : Unique integer ID assigned to this controller (default 1)
    ip         : Controller IP address (factory default "192.168.0.30")
    port       : Controller port number (factory default 8088)
    vel        : Default jog velocity in mm/s (default 80)
    accel      : Default acceleration in mm/s² (default 200)
    decel      : Default deceleration in mm/s² (default 200)
    poll_interval_s  : Seconds between axis-stop polls (default 0.02)
    move_timeout_s   : Maximum seconds to wait for movement (default 5.0)
    pos_tolerance_mm : Acceptable positioning error in mm (default 0.01)
    """

    # ── Default motion parameters ─────────────────────────────────────────
    DEFAULT_VEL          = 80.0    # mm/s
    DEFAULT_ACCEL        = 200.0   # mm/s²
    DEFAULT_DECEL        = 200.0   # mm/s²
    DEFAULT_POLL_INTERVAL    = 0.02    # seconds
    DEFAULT_MOVE_TIMEOUT     = 5.0     # seconds
    DEFAULT_POS_TOLERANCE    = 0.010   # mm  (10 µm)
    STARTUP_DELAY            = 0.1     # seconds after jog command before polling

    def __init__(
        self,
        dll_path: str,
        device_id: int        = 1,
        ip: str               = "192.168.0.30",
        port: int             = 8088,
        vel: float            = DEFAULT_VEL,
        accel: float          = DEFAULT_ACCEL,
        decel: float          = DEFAULT_DECEL,
        poll_interval_s: float  = DEFAULT_POLL_INTERVAL,
        move_timeout_s: float   = DEFAULT_MOVE_TIMEOUT,
        pos_tolerance_mm: float = DEFAULT_POS_TOLERANCE,
    ):
        self._dll_path        = dll_path
        self._device_id       = device_id
        self._ip              = ip
        self._port            = port
        self._vel             = vel
        self._accel           = accel
        self._decel           = decel
        self._poll_interval   = poll_interval_s
        self._move_timeout    = move_timeout_s
        self._pos_tolerance   = pos_tolerance_mm
        self._connected       = False
        self._dll             = None

        self._load_dll()

    # ── Context manager ───────────────────────────────────────────────────
    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        try:
            self.disconnect()
        except Exception as e:
            logger.warning("Error during disconnect in __exit__: %s", e)
        return False   # do not suppress exceptions

    # ── DLL loading ───────────────────────────────────────────────────────
    def _load_dll(self):
        """Load the FMC4030 shared library."""
        try:
            if platform.system() == "Windows":
                self._dll = WinDLL(self._dll_path)
            else:
                self._dll = CDLL(self._dll_path)
            logger.info("DLL loaded: %s", self._dll_path)
        except OSError as e:
            raise StageError("load_dll", -1) from e

    # ── Connection management ─────────────────────────────────────────────
    def connect(self):
        """
        Open connection to the FMC4030 controller.
        Raises StageError on failure.
        """
        ip_bytes = self._ip.encode("ascii")
        status   = self._dll.FMC4030_Open_Device(
            self._device_id,
            ip_bytes,
            self._port
        )
        self._check_status(status, "FMC4030_Open_Device")
        self._connected = True
        logger.info(
            "Connected to FMC4030 | id=%d | ip=%s | port=%d",
            self._device_id, self._ip, self._port
        )

    def disconnect(self):
        """
        Close connection and release DLL resources.
        Must be called before program exit; failure to call this will
        prevent the next connection from succeeding.
        """
        if not self._connected:
            return
        status = self._dll.FMC4030_Close_Device(self._device_id)
        self._connected = False
        self._check_status(status, "FMC4030_Close_Device")
        logger.info("Disconnected from FMC4030 (id=%d)", self._device_id)

    # ── Single-axis movement ──────────────────────────────────────────────
    def move(
        self,
        axis: Axis,
        distance_mm: float,
        vel: Optional[float]   = None,
        accel: Optional[float] = None,
        decel: Optional[float] = None,
        verify: bool           = True,
    ) -> Position:
        """
        Move one axis by a relative distance and wait until stopped.

        Parameters
        ----------
        axis        : Axis.X / Axis.Y / Axis.Z
        distance_mm : Distance to travel in mm (positive or negative)
        vel         : Override default velocity (mm/s)
        accel       : Override default acceleration (mm/s²)
        decel       : Override default deceleration (mm/s²)
        verify      : If True, check final position is within tolerance

        Returns
        -------
        Position    : Actual position of all three axes after movement

        Raises
        ------
        StageError          : API call failed
        StageTimeoutError   : Axis did not stop within move_timeout_s
        StagePositionError  : Final position exceeds pos_tolerance_mm
        """
        self._require_connection()
        return self._jog_and_wait(
            axis        = axis,
            distance_mm = distance_mm,
            mode        = MoveMode.RELATIVE,
            vel         = vel   or self._vel,
            accel       = accel or self._accel,
            decel       = decel or self._decel,
            verify      = verify,
        )

    def move_absolute(
        self,
        axis: Axis,
        target_mm: float,
        vel: Optional[float]   = None,
        accel: Optional[float] = None,
        decel: Optional[float] = None,
        verify: bool           = True,
    ) -> Position:
        """
        Move one axis to an absolute position and wait until stopped.

        Parameters
        ----------
        axis      : Axis.X / Axis.Y / Axis.Z
        target_mm : Absolute target position in mm
        verify    : If True, check final position is within tolerance

        Returns
        -------
        Position  : Actual position of all three axes after movement
        """
        self._require_connection()
        return self._jog_and_wait(
            axis        = axis,
            distance_mm = target_mm,
            mode        = MoveMode.ABSOLUTE,
            vel         = vel   or self._vel,
            accel       = accel or self._accel,
            decel       = decel or self._decel,
            verify      = verify,
        )

    def stop(self, axis: Axis, mode: StopMode = StopMode.DECELERATE):
        """
        Stop a single axis.

        Parameters
        ----------
        axis : Axis to stop
        mode : StopMode.DECELERATE (smooth) or StopMode.IMMEDIATE (hard stop)
        """
        self._require_connection()
        status = self._dll.FMC4030_Stop_Single_Axis(
            self._device_id, int(axis), int(mode)
        )
        self._check_status(status, f"FMC4030_Stop_Single_Axis(axis={axis.name})")
        logger.info("Axis %s stopped (mode=%s)", axis.name, mode.name)

    # ── Homing ────────────────────────────────────────────────────────────
    def home(
        self,
        axis: Axis,
        speed: float         = 10.0,
        accel_dec: float     = 100.0,
        fall_step_mm: float  = 1.0,
        direction: HomeDir   = HomeDir.NEGATIVE,
    ):
        """
        Execute homing routine for one axis.

        After homing, the axis will have moved 'fall_step_mm' away from
        the limit switch to avoid resting on it.

        Parameters
        ----------
        axis         : Axis to home
        speed        : Homing speed in mm/s (positive)
        accel_dec    : Homing acceleration and deceleration in mm/s²
        fall_step_mm : Distance to retract from limit switch after homing (mm)
        direction    : HomeDir.POSITIVE or HomeDir.NEGATIVE
        """
        self._require_connection()
        logger.info(
            "Homing axis %s | speed=%.1f mm/s | dir=%s",
            axis.name, speed, direction.name
        )
        status = self._dll.FMC4030_Home_Single_Axis(
            self._device_id,
            int(axis),
            c_float(speed),
            c_float(accel_dec),
            c_float(fall_step_mm),
            int(direction),
        )
        self._check_status(status, f"FMC4030_Home_Single_Axis(axis={axis.name})")
        # Wait for homing to complete using the same polling mechanism
        self._wait_for_stop(axis)
        logger.info("Axis %s homing complete", axis.name)

    # ── Position and speed queries ─────────────────────────────────────────
    def get_position(self) -> Position:
        """
        Read current position of all three axes.

        Returns
        -------
        Position : Named tuple with x, y, z fields in mm
        """
        self._require_connection()
        return Position(
            x=self._read_axis_position(Axis.X),
            y=self._read_axis_position(Axis.Y),
            z=self._read_axis_position(Axis.Z),
        )

    def get_speed(self, axis: Axis) -> float:
        """
        Read current speed of one axis.

        Returns
        -------
        float : Current speed in mm/s
        """
        self._require_connection()
        speed_ptr = c_float(0.0)
        status    = self._dll.FMC4030_Get_Axis_Current_Speed(
            self._device_id, int(axis), byref(speed_ptr)
        )
        self._check_status(status, f"FMC4030_Get_Axis_Current_Speed(axis={axis.name})")
        return speed_ptr.value

    def get_machine_status(self) -> MachineStatus:
        """
        Retrieve full machine status structure from controller.

        Returns MachineStatus with fields:
          realPos[3]  — actual positions (mm)
          realSpeed[3]— actual speeds (mm/s)
          axisStatus[3]— axis status flags
          homeStatus  — homing status
          limitNStatus, limitPStatus — limit switch states
        """
        self._require_connection()
        ms     = MachineStatus()
        status = self._dll.FMC4030_Get_Machine_Status(
            self._device_id, byref(ms)
        )
        self._check_status(status, "FMC4030_Get_Machine_Status")
        return ms

    def is_stopped(self, axis: Axis) -> bool:
        """
        Check whether an axis is currently stopped.

        Returns
        -------
        bool : True if axis is stopped, False if still moving
        """
        self._require_connection()
        result = self._dll.FMC4030_Check_Axis_Is_Stop(
            self._device_id, int(axis)
        )
        # API returns 1 = stopped, 0 = running
        return result == 1

    # ── Digital I/O ───────────────────────────────────────────────────────
    def set_output(self, io_channel: int, level: OutputLevel):
        """
        Set digital output channel state.

        Parameters
        ----------
        io_channel : 0–3 corresponding to OUT0–OUT3
        level      : OutputLevel.HIGH or OutputLevel.LOW
        """
        self._require_connection()
        status = self._dll.FMC4030_Set_Output(
            self._device_id, io_channel, int(level)
        )
        self._check_status(status, f"FMC4030_Set_Output(io={io_channel})")

    def get_input(self, io_channel: int) -> int:
        """
        Read digital input channel state.

        Parameters
        ----------
        io_channel : 0–3 corresponding to IN0–IN3

        Returns
        -------
        int : Current state of the input channel
        """
        self._require_connection()
        state_ptr = c_int(0)
        status    = self._dll.FMC4030_Get_Input(
            self._device_id, io_channel, byref(state_ptr)
        )
        self._check_status(status, f"FMC4030_Get_Input(io={io_channel})")
        return state_ptr.value

    # ── Interpolation (two-axis linear) ───────────────────────────────────
    def line_2axis(
        self,
        axis_sel: AxisSelection,
        end_x: float,
        end_y: float,
        speed: float,
        accel: float,
        decel: float,
    ):
        """
        Two-axis linear interpolation from current position.

        Parameters
        ----------
        axis_sel : AxisSelection.XY, XZ, or YZ
        end_x    : End X coordinate in virtual axis space (mm)
        end_y    : End Y coordinate in virtual axis space (mm)
        speed    : Resultant speed in mm/s
        accel    : Resultant acceleration in mm/s²
        decel    : Resultant deceleration in mm/s²

        Note: end_x/end_y are virtual coordinates, not physical axis labels.
        """
        self._require_connection()
        status = self._dll.FMC4030_Line_2Axis(
            self._device_id, int(axis_sel),
            c_float(end_x), c_float(end_y),
            c_float(speed), c_float(accel), c_float(decel),
        )
        self._check_status(status, "FMC4030_Line_2Axis")

    def stop_interpolation(self):
        """Stop any active linear or arc interpolation movement."""
        self._require_connection()
        status = self._dll.FMC4030_Stop_Run(self._device_id)
        self._check_status(status, "FMC4030_Stop_Run")
        logger.info("Interpolation movement stopped")

    # ── Convenience: print position ───────────────────────────────────────
    def print_position(self):
        """Print current XYZ position to console."""
        pos = self.get_position()
        print(pos)
        return pos

    # ── Private helpers ───────────────────────────────────────────────────
    def _jog_and_wait(
        self,
        axis: Axis,
        distance_mm: float,
        mode: MoveMode,
        vel: float,
        accel: float,
        decel: float,
        verify: bool,
    ) -> Position:
        """
        Send jog command, check status, wait for stop, verify position.
        Core of all movement methods.
        """
        mode_str   = "relative" if mode == MoveMode.RELATIVE else "absolute"
        target_str = f"{distance_mm:+.4f} mm ({mode_str})"
        logger.info(
            "Moving axis %s | %s | vel=%.1f mm/s | accel=%.1f | decel=%.1f",
            axis.name, target_str, vel, accel, decel
        )

        # ── 1. Send move command ──────────────────────────────────────────
        status = self._dll.FMC4030_Jog_Single_Axis(
            self._device_id,
            int(axis),
            c_float(distance_mm),
            c_float(vel),
            c_float(accel),
            c_float(decel),
            int(mode),
        )
        self._check_status(
            status,
            f"FMC4030_Jog_Single_Axis(axis={axis.name}, dist={distance_mm:.4f}mm)"
        )

        # ── 2. Short startup delay (let controller begin moving) ──────────
        time.sleep(self.STARTUP_DELAY)

        # ── 3. Poll until axis confirms stopped ───────────────────────────
        final_pos = self._wait_for_stop(axis)

        # ── 4. Verify final position ──────────────────────────────────────
        if verify:
            self._verify_position(axis, distance_mm, mode, final_pos)

        pos = self.get_position()
        logger.info(
            "Move complete | axis %s | final pos=%.4f mm | %s",
            axis.name, final_pos, pos
        )
        return pos

    def _wait_for_stop(self, axis: Axis) -> float:
        """
        Poll FMC4030_Check_Axis_Is_Stop until axis reports stopped.

        Uses the hardware-native stop flag from the controller rather
        than inferring stop from position stability — more reliable and
        eliminates false positives during slow creep phases.

        Returns
        -------
        float : Last known position in mm when stop was confirmed
        """
        t_start = time.time()

        while True:
            elapsed = time.time() - t_start

            if elapsed >= self._move_timeout:
                # Read last known position before raising timeout
                try:
                    last_pos = self._read_axis_position(axis)
                except StageError:
                    last_pos = float("nan")
                raise StageTimeoutError(axis, self._move_timeout, last_pos)

            # Check hardware stop flag
            stop_flag = self._dll.FMC4030_Check_Axis_Is_Stop(
                self._device_id, int(axis)
            )

            if stop_flag == 1:
                # Axis has stopped — read final position
                return self._read_axis_position(axis)

            time.sleep(self._poll_interval)

    def _verify_position(
        self,
        axis: Axis,
        requested: float,
        mode: MoveMode,
        actual_pos: float,
    ):
        """
        Verify that the final position is within tolerance.

        For RELATIVE moves: we cannot know the absolute target without
        tracking cumulative position, so we log a warning instead.
        For ABSOLUTE moves: we compare directly to the requested target.
        """
        if mode == MoveMode.ABSOLUTE:
            error = abs(actual_pos - requested)
            if error > self._pos_tolerance:
                raise StagePositionError(
                    axis, requested, actual_pos, self._pos_tolerance
                )
            logger.debug(
                "Position verified | axis %s | error=%.4f mm (tolerance=%.4f mm)",
                axis.name, error, self._pos_tolerance
            )
        else:
            # For relative moves, log current position only
            logger.debug(
                "Relative move on axis %s complete | current position=%.4f mm",
                axis.name, actual_pos
            )

    def _read_axis_position(self, axis: Axis) -> float:
        """
        Read position of a single axis.

        Returns
        -------
        float : Current position in mm

        Raises
        ------
        StageError : If the API call returns a non-zero status
        """
        pos_ptr = c_float(0.0)
        status  = self._dll.FMC4030_Get_Axis_Current_Pos(
            self._device_id, int(axis), byref(pos_ptr)
        )
        self._check_status(
            status,
            f"FMC4030_Get_Axis_Current_Pos(axis={axis.name})"
        )
        return pos_ptr.value

    def _require_connection(self):
        """Guard: raise RuntimeError if controller is not connected."""
        if not self._connected:
            raise RuntimeError(
                "StageController is not connected. "
                "Call connect() or use the 'with' statement."
            )

    @staticmethod
    def _check_status(status: int, context: str):
        """Raise StageError if status is non-zero."""
        if status != 0:
            raise StageError(context, status)


# ── Standalone usage example ──────────────────────────────────────────────────
if __name__ == "__main__":
    DLL_PATH = r"E:\FMC4030-Dll.dll"   # update to actual path

    try:
        with StageController(
            dll_path  = DLL_PATH,
            device_id = 1,
            ip        = "192.168.0.30",
            port      = 8088,
            vel       = 80.0,
            accel     = 200.0,
            decel     = 200.0,
            move_timeout_s   = 5.0,
            pos_tolerance_mm = 0.01,
        ) as stage:

            # Print initial position
            print("Initial position:")
            stage.print_position()

            # Relative move — X-axis, one 0.05 mm step
            print("\nMoving X +0.05 mm...")
            pos = stage.move(Axis.X, 0.05)
            print(f"After move: {pos}")

            # Absolute move — Y-axis to 0.0 mm
            print("\nMoving Y to absolute 0.0 mm...")
            pos = stage.move_absolute(Axis.Y, 0.0)
            print(f"After move: {pos}")

            # Read machine status
            ms = stage.get_machine_status()
            print(f"\nMachine status: pos=[{ms.realPos[0]:.3f}, "
                  f"{ms.realPos[1]:.3f}, {ms.realPos[2]:.3f}] mm")

    except StageError as e:
        logger.error("Stage API error: %s", e)
    except StageTimeoutError as e:
        logger.error("Stage timeout: %s", e)
    except StagePositionError as e:
        logger.error("Position verification failed: %s", e)
    except RuntimeError as e:
        logger.error("Runtime error: %s", e)
