# SPDX-License-Identifier: Apache-2.0
"""Run the bring-up checklist on the Tiny Tapeout demo board.

Copy the mpbridge folder to the board first, then run this file on it:

    mpremote fs cp -r firmware/mpbridge :
    mpremote run firmware/dry_run.py

PROJECT is the name of the design in tt.shuttle: the top-module name on the ASIC,
the bitstream file name without ".bin" on the FPGA breakout (the CI's fpga job
names the bitstream after the top module, so both are the same).
"""
from ttboard.boot.demoboard_detect import DemoboardDetect
from ttboard.demoboard import DemoBoard

from mpbridge import bringup
from mpbridge.boards import TTDemoBoard

PROJECT = "tt_um_mpbridge"
SENSOR = 0x48   # I2C device to try on uio[6] / uio[7] (the checklist also passes without one)
FLASH = False   # True: an SPI flash Pmod is on uio[0..3], read its JEDEC ID

DemoboardDetect.probe()
tt = DemoBoard.get()
getattr(tt.shuttle, PROJECT).enable()

board = TTDemoBoard(tt)
report = bringup.run_all(board, sensor=SENSOR, flash=FLASH)
print("DRY RUN PASSED" if not report.failed else "DRY RUN FAILED: %d check(s)" % len(report.failed))
