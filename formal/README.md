# Formal proofs (Track A)

SymbiYosys proves five safety properties of the bridge for every input sequence.
The property files are included by the RTL under `` `ifdef FORMAL ``; simulation,
lint and the hardening flow never define `FORMAL`, so they see the same RTL as
before.

| Property | What is proved | Where |
| --- | --- | --- |
| P1 | The FIFO count stays in 0..2; a push while full is dropped, a pop while empty is ignored; the FIFO matches a 2-entry reference queue, so bytes come out in order and an empty FIFO reads 0x00 | `fifo2x8_props.vh` |
| P2 | `cmd_ctrl` only moves along IDLE, HEADER, WRITE, EXEC, RESPOND and has a way back to IDLE: an early frame end drops a partial command, a UART response ends in IDLE after its last byte, a framed response ends with its read-out frame | `cmd_ctrl_props.vh` |
| P3 | MODE, BAUD_SEL and I2C_FAST are latched only while the controller and every engine are idle | `project_props.vh` |
| P4 | Pin safety: I2C pads never driven high, spare pads never driven, safe-idle modes drive nothing, SPI master pins only in mode 000, MISO only while selected, I2C pads only with an I2C device | `project_props.vh` |
| P5 | I2C controller: legal states, both lines released when idle, an abort ends in STOP without `d_done`, and phases B and C of START and STOP last two ticks (the half-period START/STOP timing) | `i2c_engine_props.vh` |

## Running

```bash
.venv/Scripts/pip install -r formal/requirements.txt
```

```bash
.venv/Scripts/python formal/run.py
```

```bash
.venv/Scripts/python formal/run.py --selftest
```

The first run proves every property and runs a cover task per file (8 tasks,
about 20 s). The self-test copies the sources, breaks the RTL in seven places
and checks that the matching proof no longer passes. Work files go to
`formal/build/`.

## Limits

The proofs are about the RTL with ideal synchronous inputs. `uart_trx` and
`spi_ms` have no properties of their own; they are checked by the cocotb suites.
P2 is a safety property: it shows that each way back to IDLE works when its
condition occurs, not that a host will ever send the bytes a waiting command
needs (there are no timeouts in Track A).
