![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Track A — Six-mode UART / SPI / I²C bridge

One Tiny Tapeout tile (sky130A, 25 MHz) that acts as any of six host → device
bridges between UART, SPI and I²C, selected by `ui_in[2:0]`.
Course: EC373TA VLSI Physical Design. Track B (the I3C bridge) lives in its own repo.

- Datasheet: [docs/info.md](docs/info.md)
- Engine contract and rates: [docs/architecture.md](docs/architecture.md)
- Full plan: `Track_A_Six-Mode_Bridge_Plan.pdf` (team folder)

## Status

| Week | Milestone | State |
| --- | --- | --- |
| 1 | Repo, pin map, header format, test setup, I²C bus models | Done |
| 2 | `cmd_ctrl`, `fifo4x8`, `sync2_edge`, `clkdiv` with unit tests | Done |
| 2 | 20-bit timeout (`timeout20`), limits per mode and baud rate | Done |
| 3 | Push to GitHub, skeleton hardened in CI | Done (26 Sep) |
| 4–5 | `uart_trx` (M1), `spi_ms` master/slave (M2) | Done early (27 Sep) |
| 6 | `i2c_engine` controller/target (M2), mode 110 loopback | Done early (27 Sep) |
| 7–8 | Full RTL hardened (area, timing), mode matrix 24/24 | Matrix passes in simulation; hardening next |
| 8–9 | Formal properties F1–F5, FPGA dry run | To do |
| 10–12 | Gate-level sim, sign-off, datasheet, submit | To do |

Test results today: 82/82 passing (top level 19, cmd_ctrl 23, uart_trx 6, spi_ms 5,
i2c_engine 9, fifo4x8 5, clkdiv 3, sync2_edge 3, timeout20 5, limits 1, I²C model 3).
The top level runs all six modes × {write, read, write-then-read, status}, the
mode 110 echo, error flags, timeouts and the idle-only mode latch.

Timeout limits live at the top of `src/project.v`; see the Timeouts section of
[docs/architecture.md](docs/architecture.md) for the formulas and how to change them.

## Layout

```
src/        project.v (tt_um_mpbridge), cmd_ctrl.v, fifo4x8.v, timeout20.v, sync2_edge.v, clkdiv.v,
            uart_trx.v, spi_ms.v, i2c_engine.v
test/       tb.v + test.py (top level, run by the TT CI through make, RTL and gate level)
test/unit/  unit tests per module + the I²C model check
test/models UART peer, SPI host and SPI device, I²C target (sensor) and bit-banged I²C controller
test/run.py runs everything without make (Windows friendly)
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

## Before submission

- Put all four team members in `info.yaml` (`author`).
- Consider renaming the top module to `tt_um_<github user>_mpbridge` so it is unique on the shuttle.

## Tiny Tapeout resources

- [FAQ](https://tinytapeout.com/faq/) · [Recommended pinouts](https://tinytapeout.com/specs/pinouts/) · [Local hardening](https://www.tinytapeout.com/guides/local-hardening/)
