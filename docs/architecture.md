# Track A architecture and engine contract

This is the internal contract between `cmd_ctrl` and the three protocol engines
`uart_trx`, `spi_ms` and `i2c_engine`, plus notes on how each engine works.

## Blocks and status

| Module | Owner | Status | Notes |
| --- | --- | --- | --- |
| `sync2_edge` | M2 | Done, unit-tested | 7 inputs; SCL/SDA have the 2-sample glitch filter |
| `fifo2x8` | M1 | Done, unit-tested | 2 bytes (was 4, cut for area); first-word fall-through; reads 0x00 when empty |
| `clkdiv` | M2 | Done, unit-tested | Shared by the SPI master and the I2C controller |
| `cmd_ctrl` | M1 | Done, unit-tested | Header parser + FSM + FIFO + status flags (timeouts removed for area) |
| `uart_trx` | M1 | Done, unit-tested | 8N1, one shared baud prescaler; host, device and loopback roles |
| `spi_ms` | M2 | Done, unit-tested | Mode 0 master and slave on one shift register |
| `i2c_engine` | M2 | Done, unit-tested | Controller only (the target role was cut for area); START / STOP timing per UM10204 |
| `project.v` | M1 | Done | Mode latch, engine wiring, pin directions; mode matrix passes; 1x1 sign-off clean |

## Clock and signal rules

- One clock, 25 MHz. Every pin goes through `sync2_edge` first; engines only
  use the synchronised level `q` and the one-cycle `rise` / `fall` pulses.
- Every `*_valid`, `*_take`, `*_push`, `*_pop`, `d_start`, `d_done` and
  `d_nack` is a **one-cycle pulse**. Data travels in the same cycle as its pulse.
- A byte is MSB first on SPI and I2C. UART is LSB first, as every UART sends.
- Every pin the design drives comes straight from a flip-flop (UART_TX, SCK,
  CS_N, MISO, and the I2C pull-downs), so a decode glitch can never look like a
  clock edge or a START on a bus.

## Host engine <-> cmd_ctrl

The host engine is the one the external master talks to: a UART peer or an
SPI slave. (An I2C target used this interface too, in modes 100 / 101, until
it was cut for area; `h_frame_rd`, `can_read` and `can_write` are kept in
`cmd_ctrl` for it but are unused now.)

| Signal | Dir | Meaning |
| --- | --- | --- |
| `h_rx_data[7:0]`, `h_rx_valid` | engine -> ctrl | One byte received from the host |
| `h_frame_start` | engine -> ctrl | SPI: CS fell |
| `h_frame_rd` | engine -> ctrl | With `h_frame_start`. SPI: always 1 |
| `h_frame_end` | engine -> ctrl | SPI: CS rose. UART hosts never pulse it |
| `h_tx_data[7:0]`, `h_tx_valid` | ctrl -> engine | Next response byte; `h_tx_valid` = bytes remain. Reads 0x00 when used up |
| `h_tx_take` | engine -> ctrl | The engine has taken `h_tx_data` (UART: started sending it; SPI: loaded it into the shift register) |

Per host type:

- **UART host (000, 001, 110):** pulse `h_rx_valid` per received byte. When
  `h_tx_valid` is 1 and the transmitter is idle, start sending `h_tx_data` and
  pulse `h_tx_take`.
- **SPI slave host (010, 011):** pulse `h_frame_start` (with `h_frame_rd` = 1)
  on CS fall and `h_frame_end` on CS rise. Pulse `h_rx_valid` after every 8
  SCK bits. At the start of every byte, load `h_tx_data` into the MISO shift
  register and pulse `h_tx_take`. The controller ignores MOSI bytes during a
  read-out frame and ignores `h_tx_take` outside RESPOND.

For an SPI host, `cmd_ctrl` counts `h_tx_take` only inside a read-out frame (or
in the cycle that opens one). The SPI slave loads a byte at the end of
every frame, including the command frame, and that load must not use up the response.

## Device engine <-> cmd_ctrl

The device engine is the one that drives the peripheral.

| Signal | Dir | Meaning |
| --- | --- | --- |
| `d_start` | ctrl -> engine | Run one transaction with the fields below |
| `d_op[1:0]` | ctrl -> engine | 0 write, 1 read, 2 write 1 byte then read (3 never reaches the engine) |
| `d_len[2:0]` | ctrl -> engine | 1-2 bytes now (CMD[0] + 1; the FIFO holds 2); the engines accept 1-4 |
| `d_addr[6:0]` | ctrl -> engine | I2C device address |
| `d_spi_div[1:0]` | ctrl -> engine | SPI: SCK half-period = 4 << d_spi_div clocks |
| `d_wr_data[7:0]`, `d_wr_avail` | ctrl -> engine | Next byte to send (FIFO head) |
| `d_wr_pop` | engine -> ctrl | Consumed `d_wr_data` |
| `d_rd_data[7:0]`, `d_rd_push` | engine -> ctrl | A byte read from the device (or a UART RX byte) |
| `d_nack` | engine -> ctrl | I2C NACK: pulse together with `d_done` |
| `d_done` | engine -> ctrl | Transaction finished |
| `d_abort` | ctrl -> engine | Stop now, release the bus (I2C: send STOP if the bus allows), do not pulse `d_done`. Tied to 0 in `project.v` since the timeouts were removed; the engines keep the input |
| `frame_err` | engine -> ctrl | UART stop bit was 0 (either role) |

Sequences the engine must produce:

| Device | Write (op 0) | Read (op 1) | Write-then-read (op 2) |
| --- | --- | --- | --- |
| SPI master | CS low, pop and send `d_len` bytes, CS high | CS low, send `d_len` x 0x00, push each MISO byte, CS high | CS low, pop and send 1 byte, then `d_len` x 0x00 pushing MISO, CS high |
| I2C controller | S, addr+W, pop and send `d_len` bytes, P | S, addr+R, push `d_len` bytes (ACK all but the last), P | S, addr+W, pop and send 1 byte, Sr, addr+R, push `d_len` bytes, P |
| UART peer | Pop and transmit `d_len` bytes | Never started: the controller answers from the RX buffer | Pop and transmit 1 byte, push each RX byte, `d_done` after `d_len` bytes (no reply window any more: a shorter reply waits) |

A NACK at any point: send STOP, pulse `d_nack` and `d_done` together.
While idle, a UART device engine pushes every received byte with `d_rd_push`;
the controller buffers it (IRQ goes high) or drops it when not allowed.

## No timeouts

The timeouts (a 21-bit inactivity timer in `cmd_ctrl` with per-mode,
per-baud limits) were removed to fit the 1x1 tile: they cost about 1,500 um2.
Status bit 4 now reads 0. What that means in use:

| Situation | Behaviour now |
| --- | --- |
| UART host sends part of a command, then stops | The bridge keeps waiting for the rest; a host that lost a byte must send filler bytes (or reset the bridge) to resynchronise |
| SPI host ends its frame mid-command | Unchanged: the partial command is dropped |
| I2C device stretches SCL forever | The bridge stays in EXEC (`BUSY` high) until reset |
| UART device answers a write-then-read with fewer than LEN bytes | The bridge waits for the missing bytes (no reply window) |
| SPI host never reads the response | Unchanged: the response waits as long as needed |

## Rates (25 MHz clock)

| Interface | Setting | Rate |
| --- | --- | --- |
| UART | 7 prescaler ticks per bit, a tick every 31 x 1 / 2 / 6 / 12 clocks (BAUD_SEL 11 / 10 / 01 / 00) | 115,207 / 57,604 / 19,201 / 9,600.6 baud |
| I2C controller | `clkdiv` quarter-period, `div_m1` = 62 or 16 | 99.2 kHz or 367.6 kHz |
| SPI master | `clkdiv` half-period, `div_m1` = (4 << d_spi_div) - 1 | 3.125 MHz ... 391 kHz |
| SPI slave | synchronised SCK | <= 2 MHz guaranteed |

## Pin directions (`uio_oe`)

| Mode | uio_oe | Driven pins |
| --- | --- | --- |
| 000 (SPI master) | 0x0B | CS_N, MOSI, SCK |
| 010, 011 (SPI slave) | 0x04 while CS_N is low, else 0x00 | MISO |
| 001, 011 (I2C controller) | bit 6 / 7 set only to pull SCL / SDA low | open-drain; `uio_out[7:6]` is always 0 |
| 100, 101, 111 | 0x00, and `uo_out` = 0x00 | none |

## Engine notes

**uart_trx.** One free-running prescaler ticks 7 times per bit and serves both
directions; each side counts ticks with a 3-bit phase counter (this replaced two
12-bit bit timers and saved about 1,300 um2). The receiver starts on a falling
edge of the synchronised RX line and samples each bit within 1/7 of a bit of its
middle; a 0 stop bit pulses `frame_err` and drops the byte. The first start bit
the transmitter sends may be up to 1/7 of a bit short. The transmitter accepts the next
byte during the stop bit of the current one and starts it straight after, so
responses stream back to back and the mode 110 echo keeps up with a host that
sends back to back. In mode 110 every received byte is echoed and `cmd_ctrl` sees nothing.

**spi_ms.** Master: CS_N falls, then half an SCK period later the first rising
edge. MOSI changes on falling edges. MISO is sampled late, at the falling edge,
through the synchroniser, which leaves nearly the whole SCK period for the
peripheral's output delay; half an SCK period after the last falling edge CS_N rises.
Slave: MOSI is sampled on the synchronised SCK rise and MISO changes about three
clocks after SCK falls. `h_rx_valid` fires on the 8th rising edge; the next
response byte is loaded on the 8th falling edge.

**i2c_engine.** Controller only. Every START, STOP and bit is a symbol of four
`clkdiv` quarter periods (A: SCL low, SDA changes; B: SCL released, held while a
device stretches it; C: SCL high; D: SCL low). SDA is sampled at the B-to-C tick.
`d_abort` finishes with a STOP symbol that no longer waits for a stretched clock.
In START and STOP symbols phases B and C last two ticks each, so the START hold,
repeated-START set-up and STOP set-up times are half an SCL period. Measured by
`test_ctl_start_stop_timing` in simulation:

| Time | 99.2 kHz | UM10204 standard mode | 367.6 kHz | UM10204 fast mode |
| --- | --- | --- | --- | --- |
| tHD;STA (START hold) | 5.04 us | 4.0 us | 1.36 us | 0.6 us |
| tSU;STA (repeated START set-up) | 5.24 us | 4.7 us | 1.56 us | 0.6 us |
| tSU;STO (STOP set-up) | 5.24 us | 4.0 us | 1.56 us | 0.6 us |
| tLOW | 5.04 us | 4.7 us | 1.36 us | 1.3 us |
| tHIGH | 5.24 us | 4.0 us | 1.56 us | 0.6 us |
| tBUF (STOP to next START) | 15.8 us | 4.7 us | 5.08 us | 1.3 us |

Until 12 Oct 2026 the three START / STOP times were one tick (2.5 us at
99.2 kHz), short of the standard-mode minimums. The fix cost one flip-flop and
17 cells.

## Formal proofs

`formal/` proves five properties with SymbiYosys and Z3 (`python formal/run.py`,
also the CI job `formal`): FIFO bounds and ordering (P1), the controller's way
back to IDLE (P2), the idle-only mode latch (P3), pin safety in every mode (P4)
and the I2C controller including the two-tick START / STOP phases (P5). Details
and limits: [formal/README.md](../formal/README.md).

## RP2 firmware

`firmware/` holds a MicroPython bridge client and bring-up checklist for the
demo board's RP2, which acts as UART host, SPI host and UART device. The same
files run against the RTL in `test/unit/test_firmware.py`. See
[firmware/README.md](../firmware/README.md) and
[fpga_dry_run.md](fpga_dry_run.md).

## Area and sign-off

The complete RTL needed 121% of the 1x1 core. It was cut down one measured step
at a time (CI synthesis; placement adds about 14% over the synthesised area):

| Step | Cell area | Placement utilisation |
| --- | --- | --- |
| Complete RTL | 16,845 um2 | 121% |
| Shared UART prescaler | 15,544 um2 | 111% |
| Power-of-two timeouts | 15,151 um2 | 108% |
| No reset on data registers | 14,370 um2 | 102% |
| One TX byte bus for both engines | 14,097 um2 | 100% |
| (One RX byte bus: made CI worse, reverted) | 14,217 um2 | 101% |
| Timeouts removed | 12,608 um2 | 89%, detailed placement fails |
| FIFO 4 -> 2 bytes | 11,711 um2 | 83%, detailed placement fails |
| I2C target removed (modes 100 / 101) | 10,290 um2 | 73.1%: full sign-off clean |
| **I2C START / STOP held half a period** | **10,474 um2** | **74.4%: full sign-off clean** |

Sign-off of commit a68793c (CI run 38236365385; later commits do not change the RTL):

| Metric | Value |
| --- | --- |
| Synthesised cell area | 10,474 um2, 849 cells, 180 flip-flops |
| Placement utilisation | 74.4% |
| Final utilisation (with clock tree, hold and repair buffers) | 84.7% |
| Setup slack at 25 MHz, worst corner (ss 100C 1.60 V) | +22.8 ns |
| Hold slack, worst corner (ff -40C 1.95 V) | +0.11 ns, no violations |
| Routing DRC / Magic DRC / LVS / antenna | 0 / 0 / 0 / 0 |
| Gate-level simulation (cocotb suite) | pass |
| Power, typical corner (tt 25C 1.80 V) | 0.63 mW (0.74 mW in the fast corner, ff -40C 1.95 V) |

Features given up for the tile: timeouts, the 4-byte FIFO (now 2), and the
I2C-host modes 100 / 101. If a feature is added back, check area first; the next
cheapest cuts would be I2C 400 kHz only (about 280 um2) and dropping loopback
(about 230 um2).
