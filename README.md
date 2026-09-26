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
| 3 | Push to GitHub, skeleton hardened in CI, first area numbers | Next |
| 4–5 | `uart_trx` (M1), `spi_ms` master/slave (M2) | To do |
| 6 | `i2c_engine` controller/target (M2) | To do |

Test results today: 46/46 passing (top 4, fifo4x8 5, clkdiv 3, sync2_edge 3,
timeout20 5, cmd_ctrl 22, limits 1, I²C model 3).

Timeout limits live at the top of `src/project.v`; see the Timeouts section of
[docs/architecture.md](docs/architecture.md) for the formulas and how to change them.

## Layout

```
src/        project.v (tt_um_mpbridge), cmd_ctrl.v, fifo4x8.v, timeout20.v, sync2_edge.v, clkdiv.v
test/       tb.v + test.py (top level, run by the TT CI through make)
test/unit/  unit tests per module + the I²C model check
test/models I²C target (sensor) and bit-banged I²C controller models
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
- Enable GitHub Pages for the `gds` viewer job ([TT FAQ](https://tinytapeout.com/faq/#my-github-action-is-failing-on-the-pages-part)).

## Tiny Tapeout resources

- [FAQ](https://tinytapeout.com/faq/) · [Recommended pinouts](https://tinytapeout.com/specs/pinouts/) · [Local hardening](https://www.tinytapeout.com/guides/local-hardening/)
