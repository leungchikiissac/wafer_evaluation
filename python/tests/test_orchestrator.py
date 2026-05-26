# python/tests/test_orchestrator.py
# Unit tests for ScanOrchestrator — uses mock stage and vantage.

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import numpy as np
import pytest
from unittest.mock import MagicMock, patch
from orchestration.ScanOrchestrator import ScanOrchestrator


def make_orchestrator(step_mm=0.05, range_mm=0.15):
    """Create orchestrator with 3 steps using mock stage + vantage."""
    stage   = MagicMock()
    vantage = MagicMock()

    # Simulate get_rcv_buffer returning a frame with the right shape
    fake_buf       = MagicMock()
    fake_buf.frame_index = 0
    fake_buf.data  = np.zeros((1, 100, 128), dtype=np.int16)
    vantage.get_rcv_buffer.return_value = fake_buf

    orc = ScanOrchestrator(stage, vantage)
    orc._step_mm    = step_mm
    orc._range_mm   = range_mm
    orc._num_steps  = int(round(range_mm / step_mm))
    orc._base_dir   = None
    return orc, stage, vantage


def test_run_calls_stage_and_vantage_correct_times():
    orc, stage, vantage = make_orchestrator(step_mm=0.05, range_mm=0.15)
    assert orc.num_steps == 3

    with patch.object(orc, "_save"):
        data = orc.run()

    assert stage.move.call_count == 3
    assert vantage.soft_trigger.call_count == 3
    assert vantage.wait_for_acquisition.call_count == 3
    assert vantage.copy_buffers.call_count == 3


def test_run_returns_correct_shape():
    orc, stage, vantage = make_orchestrator(step_mm=0.05, range_mm=0.10)

    with patch.object(orc, "_save"):
        data = orc.run()

    assert data.shape[0] == 2  # 2 steps
    assert data.dtype == np.int16


def test_stage_error_propagates():
    orc, stage, vantage = make_orchestrator()
    stage.move.side_effect = RuntimeError("stage error")

    with patch.object(orc, "_save"), pytest.raises(RuntimeError):
        orc.run()
