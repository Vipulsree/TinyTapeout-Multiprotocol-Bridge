# Track A architecture and engine contract

This is the internal contract between `cmd_ctrl` and the three protocol engines.
Build `uart_trx`, `spi_ms` and `i2c_engine` against it so they plug into
`project.v` without changes to the controller.

## Blocks and status

| Module | Owner | Status | Notes |
| --- | --- | --- | --- |
| `sync2_edge` | M2 | Done, unit-tested | 7 inputs; SCL/SDA have the 2-sample glitch filter |
| `fifo4x8` | M1 | Done, unit-tested | First-word fall-through; reads 0x00 when empty |
| `clkdiv` | M2 | Done, unit-tested | Not wired yet; `spi_ms` and `i2c_engine` use it |
| `cmd_ctrl` | M1 | Done, unit-tested | Header parser + FSM + FIFO + status flags + timeouts |
| `timeout20` | M1 | Done, unit-tested | 20-bit inactivity timer (max 41.9 ms), used by `cmd_ctrl` |
| `project.v` | M1 | Skeleton | Mode latch, pin directions, engines tied off |
| `uart_trx` | M1 | Weeks 4-5 | 8N1, divisor from BAUD_SEL |
| `spi_ms` | M2 | Weeks 4-5 | Mode 0 master and slave on one shift register |
| `i2c_engine` | M2 | Week 6 | Controller and target on one shift register |

## Clock and signal rules

- One clock, 25 MHz. Every pin goes through `sync2_edge` first; engines only
  use the synchronised level `q` and the one-cycle `rise` / `fall` pulses.
- Every `*_valid`, `*_take`, `*_push`, `*_pop`, `d_start`, `d_done` and
  `d_nack` is a **one-cycle pulse**. Data travels in the same cycle as its pulse.
- A byte is MSB first on every bus.

## Host engine <-> cmd_ctrl

The host engine is the one the external master talks to (UART peer, SPI slave
or I2C target, depending on the mode).

| Signal | Dir | Meaning |
| --- | --- | --- |
| `h_rx_data[7:0]`, `h_rx_valid` | engine -> ctrl | One byte received from the host |
| `h_frame_start` | engine -> ctrl | SPI: CS fell. I2C: own address matched (after the ACK) |
| `h_frame_rd` | engine -> ctrl | With `h_frame_start`. SPI: always 1. I2C: the R/W bit |
| `h_frame_end` | engine -> ctrl | SPI: CS rose. I2C: STOP. UART hosts never pulse it |
| `h_tx_data[7:0]`, `h_tx_valid` | ctrl -> engine | Next response byte; `h_tx_valid` = bytes remain. Reads 0x00 when used up |
| `h_tx_take` | engine -> ctrl | The engine has taken `h_tx_data` (UART: started sending it; SPI/I2C: loaded it into the shift register) |
| `can_read` | ctrl -> engine | I2C target ACKs its address for a read only when 1 |
| `can_write` | ctrl -> engine | I2C target ACKs its address for a write only when 1 |

Per host type:

- **UART host (000, 001, 110):** pulse `h_rx_valid` per received byte. When
  `h_tx_valid` is 1 and the transmitter is idle, start sending `h_tx_data` and
  pulse `h_tx_take`.
- **SPI slave host (010, 011):** pulse `h_frame_start` (with `h_frame_rd` = 1)
  on CS fall and `h_frame_end` on CS rise. Pulse `h_rx_valid` after every 8
  SCK bits. At the start of every byte, load `h_tx_data` into the MISO shift
  register and pulse `h_tx_take`. The controller ignores MOSI bytes during a
  read-out frame and ignores `h_tx_take` outside RESPOND.
- **I2C target host (100, 101):** address 7'b010110x, LSB from `ui_in[6]`.
  ACK a write only if `can_write`, a read only if `can_read`; otherwise NACK.
  After an ACK, pulse `h_frame_start` with `h_frame_rd` = R/W. Pulse
  `h_rx_valid` per written byte, `h_tx_take` per byte sent, `h_frame_end` on STOP.

## Device engine <-> cmd_ctrl

The device engine is the one that drives the peripheral.

| Signal | Dir | Meaning |
| --- | --- | --- |
| `d_start` | ctrl -> engine | Run one transaction with the fields below |
| `d_op[1:0]` | ctrl -> engine | 0 write, 1 read, 2 write 1 byte then read (3 never reaches the engine) |
| `d_len[2:0]` | ctrl -> engine | 1-4 bytes |
| `d_addr[6:0]` | ctrl -> engine | I2C device address |
| `d_spi_div[1:0]` | ctrl -> engine | SPI: SCK half-period = 4 << d_spi_div clocks |
| `d_wr_data[7:0]`, `d_wr_avail` | ctrl -> engine | Next byte to send (FIFO head) |
| `d_wr_pop` | engine -> ctrl | Consumed `d_wr_data` |
| `d_rd_data[7:0]`, `d_rd_push` | engine -> ctrl | A byte read from the device (or a UART RX byte) |
| `d_nack` | engine -> ctrl | I2C NACK: pulse together with `d_done` |
| `d_done` | engine -> ctrl | Transaction finished |
| `d_abort` | ctrl -> engine | Timeout: stop now, release the bus (I2C: send STOP if the bus allows), do not pulse `d_done` |
| `frame_err` | engine -> ctrl | UART stop bit was 0 (either role) |

Sequences the engine must produce:

| Device | Write (op 0) | Read (op 1) | Write-then-read (op 2) |
| --- | --- | --- | --- |
| SPI master | CS low, pop and send `d_len` bytes, CS high | CS low, send `d_len` x 0x00, push each MISO byte, CS high | CS low, pop and send 1 byte, then `d_len` x 0x00 pushing MISO, CS high |
| I2C controller | S, addr+W, pop and send `d_len` bytes, P | S, addr+R, push `d_len` bytes (ACK all but the last), P | S, addr+W, pop and send 1 byte, Sr, addr+R, push `d_len` bytes, P |
| UART peer | Pop and transmit `d_len` bytes | Never started: the controller answers from the RX buffer | Pop and transmit 1 byte, push each RX byte, `d_done` after `d_len` bytes. A shorter reply is ended by the controller's reply window (`d_abort`, no error) |

A NACK at any point: send STOP, pulse `d_nack` and `d_done` together.
While idle, a UART device engine pushes every received byte with `d_rd_push`;
the controller buffers it (IRQ goes high) or drops it when not allowed.

## Timeouts

One 20-bit counter in `cmd_ctrl` (module `timeout20`) runs whenever the
controller is waiting on someone. Every handshake pulse restarts it, so a limit
is "this long with no progress", not a limit on the whole transaction.
At 25 MHz the 20 bits reach 1,048,575 clocks = 41.9 ms; a limit of 0 disables it.

| Waiting in | On expiry | Status bit 4 (TIMEOUT) |
| --- | --- | --- |
| HEADER / WRITE (host went silent mid-command) | Drop the partial command, back to IDLE. This also resynchronises a UART host after a lost byte | Set |
| EXEC (device transaction stalled) | Pulse `d_abort`, respond anyway (reads padded with 0x00) | Set |
| EXEC, UART device write-then-read | Reply window closed: pulse `d_abort`, return the bytes received | Not set |
| RESPOND, read-out frame open or UART host sending | Drop the rest of the response, back to IDLE | Set |
| RESPOND before an SPI / I2C host starts reading | Never times out: those hosts may poll IRQ as long as they like | - |

The limits are constants at the top of `src/project.v`; change them there.
UART limits scale with BAUD_SEL, bus limits cover the worst-case transfer time.

| Limit | Formula | 9600 | 19200 | 57600 | 115200 |
| --- | --- | --- | --- | --- | --- |
| Host UART (`TO_HOST_UART_CHARS` = 16) | divisor x 10 bits x 16 | 416,640 (16.7 ms) | 208,320 | 69,440 | 34,720 (1.4 ms) |
| UART device reply window (`TO_DEV_UART_CHARS` = 8) | divisor x 10 bits x 8 | 208,320 (8.3 ms) | 104,160 | 34,720 | 17,360 (0.7 ms) |
| SPI / I2C host, I2C device (`TO_BUS`) | 35 ms, the SMBus tTIMEOUT max; covers I2C clock stretching | 875,000 | | | |
| SPI device (`TO_SPI_DEV`) | worst 5-byte transfer at SCK/64 is 2,560 clocks | 65,535 (2.6 ms) | | | |

Keep `TO_HOST_UART_CHARS` at 40 or less, or the 9600-baud value overflows 20 bits.

## Rates (25 MHz clock)

| Interface | Setting | Rate |
| --- | --- | --- |
| UART | divisor 217 / 434 / 1302 / 2604 (BAUD_SEL 11 / 10 / 01 / 00) | 115,207 / 57,604 / 19,201 / 9,600.6 baud |
| I2C controller | `clkdiv` quarter-period, `div_m1` = 62 or 16 | 99.2 kHz or 367.6 kHz |
| SPI master | `clkdiv` half-period, `div_m1` = (4 << d_spi_div) - 1 | 3.125 MHz ... 391 kHz |
| SPI slave | synchronised SCK | <= 2 MHz guaranteed |

## Pin directions (`uio_oe`)

| Mode | uio_oe | Driven pins |
| --- | --- | --- |
| 000, 101 (SPI master) | 0x0B | CS_N, MOSI, SCK |
| 010, 011 (SPI slave) | 0x04 while CS_N is low, else 0x00 | MISO |
| any I2C role | bit 6 / 7 set only to pull SCL / SDA low | open-drain; `uio_out[7:6]` is always 0 |
| 111 | 0x00, and `uo_out` = 0x00 | none |

## Open items

- Done: a UART host that loses a byte no longer desynchronises the parser; the
  host timeout drops the partial command after 16 idle characters.
- The timer adds roughly 100-150 cells (20 flip-flops, incrementer, comparator,
  limit mux). Check it in the week-3 hardening run; if area is short, lower `W`
  in `timeout20` (for example 18 bits still covers 10 ms) and shrink the limits.
- The mode latch waits for `cmd_ctrl` idle; once the engines exist it should
  also wait for the active host engine to be idle (no SPI frame or I2C
  transfer in progress).
