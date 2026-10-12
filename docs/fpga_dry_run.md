# FPGA dry run

The dry run puts the whole bridge on an FPGA and talks to it through real pins:
the RP2 firmware in `firmware/` is the UART host, the SPI host and the UART
device. It is the only test before silicon that uses real pins, real pull-ups
and real UART and SPI hardware instead of simulation models.

What is already known before you start:

- The firmware's commands and the whole checklist pass against the RTL in
  simulation (`python test/run.py -k firmware`).
- The design builds for the Tiny Tapeout FPGA breakout (iCE40UP5K): 520 of
  5,280 logic cells, maximum clock 28.1 MHz, so 25 MHz is met.
- Not tried on hardware yet: the board layer of the firmware (`boards.py`) and
  `dry_run.py`.

Two set-ups are described. Use A if you have the Tiny Tapeout demo board with the
FPGA breakout, because it is the same RP2, pins and commands as the silicon
bring-up. Use B with any other FPGA board and a Raspberry Pi Pico.

## What you need

| Item | A: TT demo board | B: other FPGA board |
| --- | --- | --- |
| FPGA | TT FPGA breakout (iCE40UP5K "ASIC simulator") on the demo board | Any board with 3.3 V I/O, a 25, 50 or 100 MHz clock and about 600 free LUTs |
| Host | The demo board's RP2 (MicroPython SDK v3 already installed) | Raspberry Pi Pico with MicroPython |
| On the PC | Python, `pip install mpremote` | The same, plus the FPGA vendor tools |
| Optional | 3.3 V I2C sensor module at 0x48 (LM75A, TMP102, TMP1075 or similar); SPI flash Pmod; logic analyser | The same |

The checklist passes with nothing plugged in. A sensor adds a read with real
data in modes 001 and 011; a flash adds the JEDEC ID in mode 000.

## A. Tiny Tapeout demo board with the FPGA breakout

### 1. Get the bitstream

On GitHub open **Actions → fpga → Run workflow** (branch `main`). When it has
finished, download the artifact `fpga_bitstream` and take
`build/tt_um_mpbridge.bin` from it. The file is about 100 kB.

### 2. Copy the files to the RP2

Connect the demo board by USB.

```bash
mpremote fs mkdir :bitstreams
```

```bash
mpremote fs cp tt_um_mpbridge.bin :bitstreams/tt_um_mpbridge.bin
```

```bash
mpremote fs cp -r firmware/mpbridge :
```

```bash
mpremote reset
```

(`mkdir` reports an error if the folder already exists; that is fine.)

### 3. Run the checklist

```bash
mpremote run firmware/dry_run.py
```

The script loads the bitstream (`tt.shuttle.tt_um_mpbridge.enable()`), starts
the 25 MHz clock and runs the checklist. Or do the same by hand in the REPL
(`mpremote`), where the SDK's `tt` object already exists:

```python
tt.shuttle.tt_um_mpbridge.enable()
from mpbridge import boards, bringup
board = boards.TTDemoBoard(tt)
report = bringup.run_all(board)
```

### 4. Add an I2C sensor (optional)

Plug a 3.3 V sensor module into the bottom-row `uio` Pmod pins: `uio[6]` = SCL,
`uio[7]` = SDA, plus 3V3 and GND. Run the checklist again; steps 3 and 6 now
read two bytes from register 0 of the device at 0x48. For another address, or
for 367.6 kHz (the sensor board must have pull-ups of 4.7 kOhm or less):

```python
bringup.run_all(board, sensor=0x4A)
bringup.run_all(board, i2c_fast=True)
```

To see what is on the bus:

```python
from mpbridge.bridge import Bridge, M_UART_I2C
bringup.enter(board, M_UART_I2C)
[hex(a) for a in Bridge(board, M_UART_I2C).scan()]
```

### 5. Add an SPI flash (optional)

Plug an SPI flash Pmod into the top-row `uio` pins (`uio[0]` CS, `uio[1]` MOSI,
`uio[2]` MISO, `uio[3]` SCK) and run:

```python
bringup.run_all(board, flash=True)
```

Step 4 then reads the JEDEC ID (for a Winbond W25Q: `EF 40`). The flash shares
the four pins the RP2 uses as SPI host in steps 5 and 6: it sees those frames
too and may answer on MISO at the same time as the bridge. So use the flash for
step 4 only: run once with `flash=True` and look at step 4, then unplug the
flash and run the full checklist.

## B. Any FPGA board with a Raspberry Pi Pico

### 1. Build the FPGA project

Add every file in `src/` (the `.v` files) and `fpga/mpbridge_fpga.v`. The top
module is `mpbridge_fpga`.

| Port | Connect to |
| --- | --- |
| `clk_board` | The board oscillator. Set parameter `CLK_DIV` to 1 for 25 MHz, 2 for 50 MHz, 4 for 100 MHz. Any other clock breaks the UART baud rates |
| `rst_n` | A push button (low = reset) or a Pico GPIO |
| `mode[2:0]`, `baud_sel[1:0]`, `i2c_fast` | Pico GPIOs (the checklist changes them) |
| `uart_rx` | A Pico UART TX pin, for example GP4 |
| `status[7:0]` | Pico GPIOs. `status[4]` (UART_TX) must be the RX pin of the same UART, for example GP5 |
| `spi_cs_n`, `spi_mosi`, `spi_miso`, `spi_sck` | Pico GPIOs |
| `i2c_scl`, `i2c_sda` | Pico GPIOs or a sensor, with pull-ups (pad pull-ups or 4.7 kOhm) |

All pins must be 3.3 V. Constrain the internal clock to 25 MHz (40 ns).

### 2. Wire and run

Connect the Pico's GND to the FPGA board's GND. Copy the firmware
(`mpremote fs cp -r firmware/mpbridge :`), then in the REPL, with the GPIO
numbers you wired:

```python
from mpbridge import boards, bringup
board = boards.PicoBoard(
    ui=[6, 7, 8, 4, 9, 10, None, 11],        # ui_in[0..7]; ui_in[3] = GP4 (UART1 TX)
    uo=[12, 13, 14, 15, 5, 16, 17, 18],      # uo_out[0..7]; uo_out[4] = GP5 (UART1 RX)
    uio=[19, 20, 21, 22, None, None, 26, 27],
    rst_n=3)
report = bringup.run_all(board)
```

Leave out `rst_n` to be asked to press the reset button. On a Pico, UART TX
pins are GP0, 4, 8, 12, 16 and the RX pin is the next one up.

## What a pass looks like

This is the transcript from simulation with nothing plugged in. On hardware it
should match line for line.

```
== 1. Reset and the modes that drive nothing
[PASS] mode 111 after reset: every output is low - uo_out = 0x00
[PASS] mode 100 (reserved): every output is low - uo_out = 0x00
[PASS] mode 101 (reserved): every output is low - uo_out = 0x00
[PASS] mode 110: UART_TX idles high, state IDLE, no flags - uo_out = 0x10

== 2. Mode 110, UART loopback at the four baud rates
[PASS] echo at 9600 baud - sent 55 A5, got 55 A5
[PASS] echo at 19200 baud - sent 55 A5, got 55 A5
[PASS] echo at 57600 baud - sent 55 00 FF A5, got 55 00 FF A5
[PASS] echo at 115200 baud - sent 55 00 FF A5, got 55 00 FF A5
[PASS] IRQ, BUSY and ERR stay low in loopback - uo_out = 0x10

== 3. Mode 001, UART host to I2C device (99.2 kHz)
[PASS] status returns 0x00 - 0x00 (ok, FIFO count 0)
[PASS] a read from an empty address returns 0x00 and sets NACK - data 00, status 0x80 (NACK, FIFO count 0)
[PASS] ERR is high - uo_out = 0x90
[PASS] a NACKed write reports NACK and the unsent byte - 0x81 (NACK, FIFO count 1)
       no device answered at 0x48 (fine without a sensor)
[PASS] the bridge is idle again - uo_out = 0x90

== 4. Mode 000, UART host to SPI device
[PASS] idle: UART_TX high, state IDLE - uo_out = 0x90
[PASS] a 2-byte write is answered with status 0x00 at each of the four SCK rates - status 00 00 00 00
[PASS] status returns 0x00: a new command clears an old error flag - 0x00 (ok, FIFO count 0)
[PASS] read with MISO pulled high returns FF FF - data FF FF
[PASS] read with MISO pulled low returns 00 00 - data 00 00
[PASS] the bridge is idle again and ERR is low - uo_out = 0x10

== 5. Mode 010, SPI host to UART device (the RP2 is both)
[PASS] status over SPI returns 0x00 - 0x00 (ok, FIFO count 0)
[PASS] write: status 0x00 and both bytes come out of UART_TX - status 0x00 (ok, FIFO count 0), UART got 05 60
[PASS] IRQ is high while received bytes wait - uo_out = 0x30
[PASS] read returns the two buffered bytes - data 11 22
[PASS] write-then-read: 0x42 goes out, the 2-byte reply comes back - UART got 42, data 43 44
[PASS] a third unrequested byte sets the overflow flag - 0x22 (OVERFLOW, FIFO count 2)
[PASS] ERR is high - uo_out = 0xB0
[PASS] the read returns the first two bytes and clears the flag - data 01 02, status 0x00 (ok, FIFO count 0)
[PASS] a command cut short by CS is dropped (state IDLE) - uo_out = 0x10
[PASS] and the next command works - 0x00 (ok, FIFO count 0)

== 6. Mode 011, SPI host to I2C device
[PASS] status returns 0x00 - 0x00 (ok, FIFO count 0)
[PASS] a read from an empty address returns 0x00 and sets NACK - data 00, status 0x80 (NACK, FIFO count 0)
[PASS] ERR is high - uo_out = 0x90
[PASS] a NACKed write reports NACK and the unsent byte - 0x81 (NACK, FIFO count 1)
       no device answered at 0x48 (fine without a sensor)
[PASS] the bridge is idle again - uo_out = 0x90

== 7. Back to mode 111
[PASS] every output is low again - uo_out = 0x00

36 checks, 0 failed
```

With a sensor at 0x48, steps 3 and 6 replace the "no device answered" line with
four checks each, and the run ends with `44 checks, 0 failed`:

```
[PASS] read of 2 bytes from register 0 of the device at 0x48 - data 19 80
       as a 16-bit temperature register (LM75 / TMP102 style): 25.50 C
[PASS] ERR is low after a good transfer - uo_out = 0x10
[PASS] write is acknowledged - 0x00 (ok, FIFO count 0)
[PASS] plain read returns the same register - data 19 80
```

With `flash=True` step 4 has one JEDEC check in place of the two MISO checks.

## If something fails

| Symptom | Likely cause |
| --- | --- |
| Step 1 fails with `uo_out = 0xFF` or random values | Bitstream not loaded, or the `uo` GPIO list is in a different order (set-up B) |
| Every echo in step 2 fails | No clock (on the demo board check `tt.auto_clocking_freq`), reset held low, or the UART is on the wrong pins |
| Echo works at 9600 but not at 115200 | The clock is not 25 MHz. The baud rates are counted in clock cycles and a UART tolerates about 2% |
| `BridgeError: no answer on UART` in step 3, and BUSY (bit 6 of `uo_out`) stays high | The I2C lines are low: no pull-ups on `uio[6]` / `uio[7]`. The bridge has no timeout and waits for SCL to rise. Reset it |
| Step 3 passes at 99.2 kHz but a NACK is missed with `i2c_fast=True` | The RP2's weak pull-ups are too slow for 367.6 kHz: fit 2.2 to 4.7 kOhm |
| "read with MISO pulled high" fails | Something else drives `uio[2]` (a flash Pmod is plugged in: use `flash=True`) |
| `BridgeError: IRQ never rose` in steps 5 or 6 | The SPI frame did not reach the bridge: check `uio[0]`, `uio[1]`, `uio[3]`, and that the RP2 has let go of them in mode 000 |
| Random failures on the FPGA only | Timing of the FPGA build: check its report. The clock cannot be lowered here, because the UART needs 25 MHz |
| `uo_out` checks fail but the data checks pass | The `uo` GPIO list is wired in a different order (set-up B) |

## What to keep for the report

- The full transcript, with and without a sensor.
- The clock frequency used and the FPGA tool's maximum frequency.
- A logic-analyser capture of one I2C read in standard mode, to measure the
  START hold and STOP set-up times (5.0 and 5.2 us in simulation), if a logic
  analyser is available (channels: UART_RX, UART_TX, SCL, SDA, IRQ).
- Anything that had to be changed in `boards.py` or `dry_run.py` to make it run,
  so the files can be corrected.
