#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run the cocotb tests through the Python runner (no make needed, works on Windows).

  python test/run.py           # top-level test + every unit test
  python test/run.py --top     # only test/test.py (what the TT CI runs through make)
  python test/run.py --unit    # only the suites in test/unit
  python test/run.py -k fifo   # only suites whose name contains "fifo"
  python test/run.py --waves   # also dump waveforms (sim_build/<suite>/)
"""
import argparse
import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_results, get_runner

TEST = Path(__file__).resolve().parent
SRC = TEST.parent / "src"
UNIT = TEST / "unit"

TOP_SOURCES = [SRC / f for f in ("project.v", "sync2_edge.v", "cmd_ctrl.v", "fifo4x8.v",
                                  "clkdiv.v", "uart_trx.v", "spi_ms.v", "i2c_engine.v")]

# suite: (hdl toplevel, sources, directory of the test module, test module, parameters)
SUITES = {
    "top": ("tb", TOP_SOURCES + [TEST / "tb.v"], TEST, "test", {}),
    "fifo4x8": ("fifo4x8", [SRC / "fifo4x8.v"], UNIT, "test_fifo4x8", {}),
    "clkdiv": ("clkdiv", [SRC / "clkdiv.v"], UNIT, "test_clkdiv", {}),
    "sync2_edge": ("sync2_edge", [SRC / "sync2_edge.v"], UNIT, "test_sync2_edge",
                   {"N": 2, "INIT": 3, "FILTER": 2}),
    "cmd_ctrl": ("cmd_ctrl", [SRC / "cmd_ctrl.v", SRC / "fifo4x8.v"], UNIT,
                 "test_cmd_ctrl", {}),
    "uart_trx": ("tb_uart_trx", [SRC / "uart_trx.v", SRC / "sync2_edge.v", UNIT / "tb_uart_trx.v"], UNIT,
                 "test_uart_trx", {}),
    "spi_ms": ("tb_spi_ms", [SRC / "spi_ms.v", SRC / "sync2_edge.v", SRC / "clkdiv.v", UNIT / "tb_spi_ms.v"],
               UNIT, "test_spi_ms", {}),
    "i2c_engine": ("tb_i2c_engine", [SRC / "i2c_engine.v", SRC / "sync2_edge.v", SRC / "clkdiv.v",
                                     UNIT / "tb_i2c_engine.v"], UNIT, "test_i2c_engine", {}),
    "i2c_model": ("tb_i2c_model", [UNIT / "tb_i2c_model.v"], UNIT, "test_i2c_model", {}),
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--top", action="store_true", help="only the top-level test")
    ap.add_argument("--unit", action="store_true", help="only the unit tests")
    ap.add_argument("-k", default="", help="only suites whose name contains this text")
    ap.add_argument("--waves", action="store_true", help="dump waveforms")
    args = ap.parse_args()

    names = [n for n in SUITES
             if (not args.top or n == "top") and (not args.unit or n != "top") and args.k in n]
    runner = get_runner("icarus")
    pythonpath = os.pathsep.join([str(TEST), os.environ.get("PYTHONPATH", "")])
    summary = []
    for name in names:
        top, sources, test_dir, module, params = SUITES[name]
        build_dir = TEST / "sim_build" / name
        runner.build(sources=sources, hdl_toplevel=top, build_dir=build_dir, includes=[SRC],
                     parameters=params, timescale=("1ns", "1ps"), waves=args.waves, always=True)
        xml = runner.test(hdl_toplevel=top, test_module=module, test_dir=test_dir, build_dir=build_dir,
                          extra_env={"PYTHONPATH": pythonpath}, waves=args.waves)
        total, failed = get_results(xml)
        summary.append((name, total, failed))

    print("\n" + "=" * 44)
    for name, total, failed in summary:
        print(f"  {name:<14} {total - failed:>3}/{total:<3} {'PASS' if failed == 0 else 'FAIL'}")
    print("=" * 44)
    sys.exit(1 if any(f for _, _, f in summary) else 0)


if __name__ == "__main__":
    main()
