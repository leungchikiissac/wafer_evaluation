# python/tests/test_stage.py
# Unit tests for StageController — no hardware or DLL required.
# Tests validate exception types and state-machine behaviour via mocking.

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest
from unittest.mock import MagicMock, patch, PropertyMock
from stage.StageController import (
    StageController, Axis, MoveMode, StopMode,
    StageError, StageTimeoutError, StagePositionError, Position,
)


def make_stage(dll_mock):
    """Create a StageController with a pre-loaded mock DLL."""
    with patch("stage.StageController.WinDLL", return_value=dll_mock), \
         patch("stage.StageController.CDLL",   return_value=dll_mock), \
         patch("platform.system", return_value="Linux"):
        sc = StageController(dll_path="fake.so", device_id=1)
    sc._connected = True
    return sc


def test_connect_success():
    dll = MagicMock()
    dll.FMC4030_Open_Device.return_value = 0
    dll.FMC4030_Get_Axis_Current_Pos.return_value = 0

    with patch("stage.StageController.CDLL", return_value=dll), \
         patch("platform.system", return_value="Linux"):
        sc = StageController(dll_path="fake.so")
    sc.connect()
    assert sc._connected is True


def test_connect_failure_raises():
    dll = MagicMock()
    dll.FMC4030_Open_Device.return_value = -1

    with patch("stage.StageController.CDLL", return_value=dll), \
         patch("platform.system", return_value="Linux"):
        sc = StageController(dll_path="fake.so")

    with pytest.raises(StageError):
        sc.connect()


def test_move_sends_jog_and_returns_position():
    dll = MagicMock()
    dll.FMC4030_Jog_Single_Axis.return_value = 0
    dll.FMC4030_Check_Axis_Is_Stop.return_value = 1  # immediately stopped
    dll.FMC4030_Get_Axis_Current_Pos.return_value = 0

    sc = make_stage(dll)

    with patch("time.sleep"):
        pos = sc.move(Axis.X, 0.05)

    dll.FMC4030_Jog_Single_Axis.assert_called_once()
    assert isinstance(pos, Position)


def test_move_raises_on_jog_failure():
    dll = MagicMock()
    dll.FMC4030_Jog_Single_Axis.return_value = -5

    sc = make_stage(dll)

    with pytest.raises(StageError), patch("time.sleep"):
        sc.move(Axis.X, 0.05)


def test_move_raises_timeout():
    dll = MagicMock()
    dll.FMC4030_Jog_Single_Axis.return_value = 0
    dll.FMC4030_Check_Axis_Is_Stop.return_value = 0  # never stops
    dll.FMC4030_Get_Axis_Current_Pos.return_value = 0

    sc = make_stage(dll)
    sc._move_timeout = 0.0  # expire immediately

    with pytest.raises(StageTimeoutError), patch("time.sleep"):
        sc.move(Axis.X, 0.05)


def test_position_error_on_absolute_move():
    dll = MagicMock()
    dll.FMC4030_Jog_Single_Axis.return_value = 0
    dll.FMC4030_Check_Axis_Is_Stop.return_value = 1

    pos_val = MagicMock()
    pos_val.value = 5.0   # actual position

    from ctypes import c_float
    dll.FMC4030_Get_Axis_Current_Pos.side_effect = lambda dev, ax, ptr: setattr(ptr, "value", 5.0) or 0

    sc = make_stage(dll)
    sc._pos_tolerance = 0.01

    # Target 0.0 but actual is 5.0 → should raise
    with pytest.raises(StagePositionError), patch("time.sleep"):
        sc.move_absolute(Axis.X, 0.0)


def test_not_connected_raises():
    dll = MagicMock()
    sc = make_stage(dll)
    sc._connected = False

    with pytest.raises(RuntimeError):
        sc.move(Axis.X, 0.05)


def test_disconnect_calls_close():
    dll = MagicMock()
    dll.FMC4030_Close_Device.return_value = 0

    sc = make_stage(dll)
    sc.disconnect()

    dll.FMC4030_Close_Device.assert_called_once_with(sc._device_id)
    assert sc._connected is False
