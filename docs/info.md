<!---
This file is used to generate the project datasheet.
-->

## How it works

One tile acts as any of four protocol bridges between UART, SPI and I2C, plus a
UART loopback self-test. The `MODE` pins pick which protocol the host uses and
which one the bridge drives; the mode is latched only while the bridge is idle.
Transactions are half-duplex: the request goes out, the response comes back.

| MODE | Host side (bridge acts as) | Device side (bridge acts as) |
| --- | --- | --- |
| 000 | UART peer | SPI master |
| 001 | UART peer | I2C controller |
| 010 | SPI slave | UART peer |
| 011 | SPI slave | I2C controller |
| 100, 101 | Reserved (were I2C target modes): safe idle, like 111 | - |
| 110 | Loopback self-test (UART echo) | - |
| 111 | Safe idle: all outputs low, nothing driven | - |

Bus settings: UART 8N1 at 9600-115200 baud (`BAUD_SEL`); SPI mode 0, as master
at 391 kHz-3.125 MHz (chosen per command) or as slave up to 2 MHz SCK; I2C
controller in standard or fast mode (99.2 or 367.6 kHz, `I2C_FAST`).

Every transaction starts with a 2-byte header:

- **CMD:** bits 7:6 = op (00 write, 01 read, 10 write 1 byte then read, 11 status);
  bits 3:2 = SPI clock divider (SCK = 25 MHz / 8, 16, 32 or 64); bit 0 = length - 1
  (1 or 2 bytes); bits 5:4 and 1 are reserved, write 0.
- **ADDR:** 7-bit I2C device address (ignored for SPI and UART devices).
- Then the write payload (up to 2 bytes).

Reads return the data bytes. Writes and status return one status byte:
bit 7 I2C NACK, bit 6 UART framing error, bit 5 FIFO overflow, bits 4:2 reserved (0),
bits 1:0 FIFO count (0-2).

There are no timeouts: a UART host must send whole commands, a stalled I2C
device keeps `BUSY` high until reset, and a UART device must answer a
write-then-read with exactly LEN bytes. An SPI host drops a partial command by
ending the frame.

Example (mode 001): send `81 48 00` over UART to read 2 bytes from register 0x00
of an I2C sensor at 0x48; the bridge answers with the 2 bytes.

An SPI host sends the command in one CS-low frame, waits for `IRQ`, then clocks
the response out in a second frame (MOSI ignored). A UART host just keeps
listening: the response follows on TX.

## How to test

Set the clock to 25 MHz and choose a mode on `ui_in[2:0]`.

1. Mode 110: open a serial terminal on the demo board's USB-UART (115200 8N1,
   `BAUD_SEL` = 11); typed characters are echoed.
2. Mode 001: plug an I2C temperature-sensor Pmod into the bottom `uio` row and
   send `81 <addr> 00` to read its temperature register.
3. Mode 000: plug an SPI flash Pmod into the top `uio` row and send `81 00 9F`
   to read the first two bytes of its JEDEC ID (manufacturer and memory type).
4. Modes 010 and 011: the demo board's RP2040 acts as the SPI host.

`uo_out[3:0]` shows the controller state (0 idle, 1 header, 2 write, 3 exec,
4 respond); `IRQ`, `BUSY` and `ERR` show the rest.

## External hardware

- I2C temperature-sensor Pmod (Tiny Tapeout bottom-row I2C pinout), with pull-ups
- SPI flash Pmod (Tiny Tapeout top-row SPI pinout)
- USB-UART through the demo board's RP2040
