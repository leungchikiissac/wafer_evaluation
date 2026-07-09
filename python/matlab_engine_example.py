"""
matlab_engine_example.py

Demonstrates connecting to MATLAB from Python using the MATLAB Engine API.

Installation (run once from MATLAB's Python engine directory):
    cd "C:\Program Files\MATLAB\R20XXx\extern\engines\python"
    python setup.py install

Or with pip (MATLAB R2022b+):
    pip install matlabengine
"""

import matlab.engine


# ── Option A: start a new MATLAB session ────────────────────────────────────
def start_new_session():
    print("Starting new MATLAB session...")
    eng = matlab.engine.start_matlab()
    print("MATLAB started.\n")
    return eng


# ── Option B: connect to an already-running shared session ───────────────────
# In MATLAB, first call:  matlab.engine.shareEngine
def connect_existing_session():
    sessions = matlab.engine.find_matlab()
    if not sessions:
        raise RuntimeError(
            "No shared MATLAB session found. "
            "In MATLAB run: matlab.engine.shareEngine"
        )
    print(f"Connecting to session: {sessions[0]}")
    eng = matlab.engine.connect_matlab(sessions[0])
    print("Connected.\n")
    return eng


# ── Simple examples ──────────────────────────────────────────────────────────
def run_examples(eng):
    # 1. Print from MATLAB
    print("--- eval: disp ---")
    eng.eval("disp('Hello from MATLAB')", nargout=0)

    # 2. Arithmetic result back to Python
    print("\n--- eval: arithmetic ---")
    result = eng.eval("1 + 1", nargout=1)
    print(f"1 + 1 = {result}")

    # 3. Pass a variable into MATLAB workspace, compute, read back
    print("\n--- workspace round-trip ---")
    eng.workspace["x"] = 42.0
    eng.eval("y = x * 2;", nargout=0)
    y = eng.workspace["y"]
    print(f"x=42 → y = x*2 = {y}")

    # 4. Call a built-in MATLAB function directly
    print("\n--- direct function call ---")
    val = eng.sqrt(16.0, nargout=1)
    print(f"sqrt(16) = {val}")

    # 5. Project-specific: check that the processing path exists on the MATLAB side
    print("\n--- project path check ---")
    eng.eval(
        "p = 'E:\\issac\\chip_scan'; "
        "if exist(p,'dir'), disp(['Path OK: ' p]); "
        "else, disp(['Path MISSING: ' p]); end",
        nargout=0,
    )

    # 6. Run a .m script (must be on MATLAB path or use full path)
    #    Uncomment and adjust the path to run a real script:
    # eng.eval("run('C:/Users/issac/Projects/wafer_evaluation/matlab/processing/repair_bf_missing_ei.m')", nargout=0)


# ── Main ─────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import sys

    # Use "--connect" flag to attach to an existing shared session instead of
    # launching a new one:  python matlab_engine_example.py --connect
    use_connect = "--connect" in sys.argv

    try:
        eng = connect_existing_session() if use_connect else start_new_session()
    except Exception as exc:
        print(f"Failed to get MATLAB engine: {exc}")
        sys.exit(1)

    try:
        run_examples(eng)
    finally:
        eng.quit()
        print("\nMATLAB session closed.")
