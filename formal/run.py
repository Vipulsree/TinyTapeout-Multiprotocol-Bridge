#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run the formal proofs (SymbiYosys) and print one line per task.

  python formal/run.py              # every .sby file, every task
  python formal/run.py -k i2c       # only files whose name contains "i2c"
  python formal/run.py --selftest   # break the RTL on purpose: every proof must then fail

Tools: `sby` with Yosys and Z3 on the PATH (OSS CAD Suite), or the pip packages
in formal/requirements.txt (yowasp-yosys provides sby, z3-solver provides z3).
Work directories go to formal/build/.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

FORMAL = Path(__file__).resolve().parent
REPO = FORMAL.parent
BUILD = FORMAL / "build"

# (name, .sby file, task, source file, text to find, replacement): each change
# breaks one property, so the named task has to fail.
MUTATIONS = [
    ("P1 FIFO accepts a 3rd byte", "fifo2x8.sby", "prove", "src/fifo2x8.v",
     "push & ((cnt != 2'd2) | do_pop)", "push"),
    ("P2 early frame end keeps the command", "cmd_ctrl.sby", "prove", "src/cmd_ctrl.v",
     "        if (h_frame_end) st <= S_IDLE;  // frame ended before the payload was complete\n        else if (h_rx_valid) begin",
     "        if (h_rx_valid) begin"),
    ("P3 mode latched while busy", "project.sby", "prove", "src/project.v",
     "    end else if (all_idle) begin", "    end else begin"),
    ("P4 I2C pad driven high", "project.sby", "prove", "src/project.v",
     "assign uio_out = {4'b0000, spi_sck_o", "assign uio_out = {i2c_sda_low, 3'b000, spi_sck_o"),
    ("P4 MISO driven while not selected", "project.sby", "prove", "src/project.v",
     "wire spi_selected = host_spi & ~spi_cs_n_in;", "wire spi_selected = host_spi;"),
    ("P5 START/STOP phases one tick again", "i2c_engine.sby", "prove", "src/i2c_engine.v",
     "        if (!c_slow) ph <= ph + 2'd1;", "        ph <= ph + 2'd1;"),
    ("P5 abort raises d_done", "i2c_engine.sby", "prove", "src/i2c_engine.v",
     "              if (!c_abort) begin\n                d_done <= 1'b1;", "              begin\n                d_done <= 1'b1;"),
]


def tools():
    """Command prefix for sby: native if present, else the YoWASP build."""
    for d in ("bin", "Scripts"):  # pip puts z3 and the yowasp tools here; not always on the PATH
        os.environ["PATH"] = str(Path(sys.prefix) / d) + os.pathsep + os.environ["PATH"]
    if not shutil.which("z3"):
        sys.exit("z3 not found: pip install -r formal/requirements.txt")
    if shutil.which("sby"):
        return ["sby"]
    if shutil.which("yowasp-sby"):
        return ["yowasp-sby", "--yosys", "yowasp-yosys", "--smtbmc", "yowasp-yosys-smtbmc"]
    sys.exit("sby not found: pip install -r formal/requirements.txt")


def warm_up(cmd):
    """YoWASP compiles Yosys on its first use and caches the result. sby runs the
    tasks of a file side by side, and two first uses at once can collide, so run
    Yosys once on its own first."""
    if cmd[0] == "yowasp-sby":
        subprocess.run(["yowasp-yosys", "-V"], capture_output=True, text=True)


def run_sby(cmd, sby_file, task=None, cwd=FORMAL, prefix=None):
    """Run one .sby file; return {task: status} from the DONE lines."""
    prefix = prefix or BUILD / sby_file.stem
    prefix.parent.mkdir(parents=True, exist_ok=True)
    args = cmd + ["-f", "--prefix", str(prefix), sby_file.name] + ([task] if task else [])
    out = subprocess.run(args, cwd=cwd, capture_output=True, text=True).stdout
    (prefix.parent / (prefix.name + ".log")).write_text(out, encoding="utf-8")
    return dict(re.findall(r"_([a-z]+)\] DONE \((\w+)", out)), out


def selftest(cmd):
    work = BUILD / "selftest"
    bad = 0
    for name, sby, task, src, old, new in MUTATIONS:
        shutil.rmtree(work, ignore_errors=True)
        shutil.copytree(REPO / "src", work / "src")
        (work / "formal").mkdir()
        for f in list(FORMAL.glob("*.sby")) + list(FORMAL.glob("*.vh")):
            shutil.copy(f, work / "formal")
        path = work / src
        text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
        if text.count(old) != 1:
            print(f"  {name:<40} ERROR: source text not found in {src}")
            bad += 1
            continue
        path.write_text(text.replace(old, new), encoding="utf-8")
        res, _ = run_sby(cmd, work / "formal" / sby, task, cwd=work / "formal", prefix=work / "run" / Path(sby).stem)
        status = res.get(task, "ERROR")
        caught = status in ("FAIL", "UNKNOWN")  # UNKNOWN = the induction step failed
        bad += not caught
        print(f"  {name:<40} {sby:<14} {status:<8} {'caught' if caught else 'NOT CAUGHT'}")
    shutil.rmtree(work, ignore_errors=True)
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-k", default="", help="only .sby files whose name contains this text")
    ap.add_argument("--selftest", action="store_true", help="check that broken RTL makes the proofs fail")
    args = ap.parse_args()
    cmd = tools()
    warm_up(cmd)

    if args.selftest:
        print("Self-test: each line breaks the RTL in one place; the proof must fail.")
        sys.exit(1 if selftest(cmd) else 0)

    rows = []
    for sby_file in sorted(FORMAL.glob("*.sby")):
        if args.k not in sby_file.stem:
            continue
        t0 = time.time()
        res, out = run_sby(cmd, sby_file)
        if not res or "ERROR" in res.values():  # a tool error, not a failed proof: show it, try once more
            print(out[-2000:])
            res, out = run_sby(cmd, sby_file)
        if not res:
            res = {"?": "ERROR"}
            print(out[-2000:])
        for task, status in res.items():
            rows.append((sby_file.stem, task, status, time.time() - t0))

    print("\n" + "=" * 44)
    for name, task, status, secs in rows:
        print(f"  {name:<12} {task:<7} {status:<6} {secs:6.0f} s")
    print("=" * 44)
    sys.exit(0 if rows and all(s == "PASS" for _, _, s, _ in rows) else 1)


if __name__ == "__main__":
    main()
