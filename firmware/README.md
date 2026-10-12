# RP2 firmware: bridge client and bring-up checklist

MicroPython for the RP2 on the Tiny Tapeout demo board (RP2350 on the current
board, RP2040 on older ones) or a bare Raspberry Pi Pico. The RP2 plays every
part the bridge needs: the UART host, the SPI host, and the UART device in mode
010. Nothing has to be compiled.

Step-by-step instructions for the FPGA dry run are in
[docs/fpga_dry_run.md](../docs/fpga_dry_run.md).

## Files

| File | What it does | Checked how |
| --- | --- | --- |
| `mpbridge/bridge.py` | The command protocol over a UART host or an SPI host: write, read, write-then-read, status, I2C scan | Against the RTL in simulation |
| `mpbridge/bringup.py` | The bring-up checklist: every mode, the error flags, the mode changes | Against the RTL in simulation |
| `mpbridge/boards.py` | Reset, `ui_in`, `uo_out`, clock, the hardware UART and the SPI host on the demo board (TT SDK) or a bare Pico | Not run on hardware yet |
| `dry_run.py` | Runs the checklist on the demo board | Not run on hardware yet |

"Against the RTL in simulation" means `test/unit/test_firmware.py`: the same
Python files drive the Verilog design in the simulator, with a simulated board
in place of the GPIOs. It runs the whole checklist on a bare board and with an
I2C sensor and an SPI flash. Run it with:

```bash
.venv/Scripts/python test/run.py -k firmware
```

So if the checklist fails on hardware, look first at the two files that could
not be simulated (pins, pull-ups, clock, the SDK calls), then at the chip.

## What the RP2 does in each mode

| Mode | RP2 as host | RP2 as device | Needs plugging in |
| --- | --- | --- | --- |
| 110 loopback | UART on `ui_in[3]` / `uo_out[4]` | - | Nothing |
| 001 UART to I2C | UART | - | Nothing (an empty address must NACK); an I2C sensor for real data |
| 000 UART to SPI | UART | Pulls MISO high, then low | Nothing; an SPI flash for real data (`flash=True`) |
| 010 SPI to UART | SPI on `uio[0..3]` | The same UART, now as the device | Nothing |
| 011 SPI to I2C | SPI | - | Nothing; an I2C sensor for real data |

The UART is the RP2's hardware UART: on the demo board `ui_in[3]` and
`uo_out[4]` are a UART TX / RX pin pair. The SPI host is `machine.SoftSPI` at
100 kHz, so it works on any pins. The RP2 drives CS_N, MOSI and SCK only in the
SPI-host modes and lets go of them before any mode change, because in mode 000
the bridge drives those three pins itself.

## Using it from the REPL

On the demo board the SDK's `tt` object already exists:

```python
tt.shuttle.tt_um_mpbridge.enable()        # the ASIC project, or on the FPGA breakout
                                          # the bitstream /bitstreams/tt_um_mpbridge.bin
from mpbridge import boards, bringup
from mpbridge.bridge import Bridge, M_UART_I2C, M_SPI_I2C, M_UART_SPI

board = boards.TTDemoBoard(tt)            # 25 MHz clock, RP2 drives ui_in and reset
bringup.run_all(board)                    # the whole checklist

# or by hand
bringup.enter(board, M_UART_I2C)          # mode 001, 115200 baud, 99.2 kHz I2C
board.reset()
br = Bridge(board, M_UART_I2C)
br.status()                               # 0
br.scan()                                 # I2C addresses that answer, e.g. [72]
br.write_read(0x48, 0x00, 2)              # 2 bytes from register 0 of the device at 0x48

bringup.enter(board, M_UART_SPI)          # mode 000
br = Bridge(board, M_UART_SPI)
br.write_read(0, 0x9F, 2)                 # JEDEC ID of an SPI flash: manufacturer, memory type
```

## Notes

- The demo board SDK gives the RP2 pins a pull-down by default. `TTDemoBoard`
  turns on pull-ups for the I2C lines (`uio[6]`, `uio[7]`). This matters more
  here than on most designs: the bridge has no timeouts, so with SCL held low it
  takes that for a stretched clock and stays busy until reset.
- The RP2's pull-ups are weak (tens of kOhm). They are enough for 99.2 kHz with
  nothing connected. For 367.6 kHz (`i2c_fast=True`) fit 2.2 to 4.7 kOhm, or use
  a sensor board that has its own.
- An error flag stays set until the next command that is not a status command,
  also across a mode change. The checklist expects that (step 4).
- A UART host that loses a byte leaves the bridge waiting for the rest of the
  command. `board.reset()` gets it back.
