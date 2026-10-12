![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Track A — Multi-mode UART / SPI / I²C bridge

One Tiny Tapeout tile (sky130A, 25 MHz) that acts as any of four host → device
bridges between UART, SPI and I²C (000 UART→SPI, 001 UART→I²C, 010 SPI→UART,
011 SPI→I²C) plus a UART loopback, selected by `ui_in[2:0]`. The planned six
modes, a 4-byte FIFO and timeouts did not fit one tile; see Area below.
Course: EC373TA VLSI Physical Design. Track B (the I3C bridge) lives in its own repo.

- Datasheet: [docs/info.md](docs/info.md)
- Engine contract and rates: [docs/architecture.md](docs/architecture.md)
- Formal proofs of P1–P5: [formal/README.md](formal/README.md)
- RP2 firmware and bring-up checklist: [firmware/README.md](firmware/README.md)
- FPGA dry run, step by step: [docs/fpga_dry_run.md](docs/fpga_dry_run.md)
- Full plan: `Track_A_Multi-Mode_Bridge_Plan.pdf` (team folder)

## Status

| Week | Milestone | State |
| --- | --- | --- |
| 1 | Repo, pin map, header format, test setup, I²C bus models | Done |
| 2 | `cmd_ctrl`, `fifo4x8` (now `fifo2x8`), `sync2_edge`, `clkdiv` with unit tests | Done |
| 2 | Timeout (`timeout20`), limits per mode and baud rate | Done; removed in week 7 for area |
| 3 | Push to GitHub, skeleton hardened in CI | Done (26 Sep) |
| 4–5 | `uart_trx` (M1), `spi_ms` master/slave (M2) | Done early (27 Sep) |
| 6 | `i2c_engine` controller/target (M2), mode 110 loopback | Done early (27 Sep); target later cut for area |
| 7–8 | Full RTL hardened (area, timing), mode matrix | Done (29 Sep): 1x1 tile, timing and DRC/LVS clean, gate-level pass |
| 8 | I²C START / STOP timing per UM10204 at 99.2 kHz | Done (12 Oct): half-period hold and set-up times, 74% placement |
| 8 | Formal properties P1–P5 | Done (12 Oct): all five proved, CI job `formal` |
| 8–9 | RP2 firmware and bring-up checklist | Done (12 Oct): MicroPython, checked against the RTL in simulation; not yet run on hardware |
| 9 | FPGA dry run | Files ready ([docs/fpga_dry_run.md](docs/fpga_dry_run.md)); to be run on hardware |
| 10–12 | Gate-level sim, sign-off, datasheet, submit | Gate-level sim and sign-off pass in CI; submission to do |

Test results today: 67/67 passing (top level 14, cmd_ctrl 18, uart_trx 6, spi_ms 5,
i2c_engine 7, fifo2x8 5, clkdiv 3, sync2_edge 3, I²C model 3, firmware 3).
The top level runs the four bridge modes × {write, read, write-then-read,
status}, the mode 110 echo, error flags, safe idle in 100 / 101 / 111 and the
idle-only mode latch; `i2c_engine` measures the START / STOP timing against
UM10204; the firmware suite runs the RP2 code and its bring-up checklist
against the RTL.

**Area:** the complete design needed 121% of a 1x1 tile. Four zero-loss
optimisations took it to 100%; then the timeouts, half the FIFO (4 → 2 bytes)
and the I²C-host modes 100 / 101 were cut. It now places at 74% and passes full
sign-off. Numbers per step: "Area and sign-off" in
[docs/architecture.md](docs/architecture.md); what the missing timeouts mean in
use: "No timeouts" there.

## Layout

```
src/        project.v (tt_um_mpbridge), cmd_ctrl.v, fifo2x8.v, sync2_edge.v, clkdiv.v,
            uart_trx.v, spi_ms.v, i2c_engine.v
test/       tb.v + test.py (top level, run by the TT CI through make, RTL and gate level)
test/unit/  unit tests per module + the I²C model check
test/models UART peer, SPI host and SPI device, I²C target (sensor) and bit-banged I²C controller
test/run.py runs everything without make (Windows friendly)
formal/     SymbiYosys proofs of P1–P5 (run.py, one .sby and one _props.vh per module)
firmware/   MicroPython bridge client and bring-up checklist for the demo board's RP2
fpga/       wrapper to put the design on any FPGA board
```

## Running the tests

Needs Icarus Verilog 12 and Python 3.11+.

```bash
python -m venv .venv
.venv/Scripts/pip install -r test/requirements.txt   # Linux/macOS: .venv/bin/pip
.venv/Scripts/python test/run.py                     # everything
.venv/Scripts/python test/run.py --unit -k cmd_ctrl  # one suite
```

On Linux the TT flow also works: `cd test && make`.

Formal proofs (about 20 seconds):

```bash
.venv/Scripts/pip install -r formal/requirements.txt
.venv/Scripts/python formal/run.py
```

## Before submission

- Run the FPGA dry run ([docs/fpga_dry_run.md](docs/fpga_dry_run.md)) and keep its transcript.
- Check the `author` line in `info.yaml`: every author, then the guide and the college.
- The top module stays `tt_um_mpbridge`: no other project on the shuttle uses the name.
- Import the repository into the department's GitHub account, set its description and
  Pages source there, and submit that URL to the shuttle.

## Tiny Tapeout resources

- [FAQ](https://tinytapeout.com/faq/) · [Recommended pinouts](https://tinytapeout.com/specs/pinouts/) · [Local hardening](https://www.tinytapeout.com/guides/local-hardening/)
