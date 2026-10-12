# SPDX-License-Identifier: Apache-2.0
"""Bring-up checklist for the bridge: FPGA dry run now, silicon later.

run_all() walks every mode and prints one PASS / FAIL line per check. It needs
a board (boards.py). The simulation runs the same function against the RTL
(test/unit/test_firmware.py), so a FAIL on hardware points at the hardware
set-up or the chip, not at this script.

Nothing has to be plugged in: the RP2 is the UART host, the SPI host and the
UART device. With an I2C sensor on the bottom uio row (default address 0x48)
steps 3 and 6 also read two bytes from its register 0; with flash=True step 4
reads the JEDEC ID of an SPI flash on the top uio row.
"""
from .bridge import (BAUDS, BUSY, ERR, IRQ, M_LOOP, M_OFF, M_RSVD_100, M_RSVD_101, M_SPI_I2C, M_SPI_UART,
                     M_UART_I2C, M_UART_SPI, NACK, OP_WRITE, OP_WRRD, OVF, S_IDLE, SPI_HOST, STATE, UART_TX,
                     Bridge, BridgeError, cmd, status_text, ui_value)

EMPTY = 0x7E  # reserved I2C address: no device answers it


class Report:
    def __init__(self, out=print):
        self.out = out
        self.results = []  # (name, ok, detail)

    def check(self, name, ok, detail=""):
        self.results.append((name, bool(ok), detail))
        self.out("[%s] %s%s" % ("PASS" if ok else "FAIL", name, (" - " + detail) if detail else ""))
        return bool(ok)

    def info(self, text):
        self.out("       " + text)

    def step(self, title):
        self.out("")
        self.out("== " + title)

    @property
    def failed(self):
        return [r for r in self.results if not r[1]]


class _Pins:
    """uo_out checks; skipped (and counted as passed) when the board cannot read uo_out."""

    def __init__(self, board, report):
        self.board = board
        self.r = report

    def check(self, name, mask, value):
        v = self.board.uo()
        if v is None:
            self.r.info(name + ": uo_out not wired, not checked")
            return True
        return self.r.check(name, (v & mask) == value, "uo_out = 0x%02X" % v)


def _hex(data):
    return " ".join("%02X" % b for b in data)


def enter(board, mode, baud=115200, i2c_fast=False):
    """Put the bridge in a mode. The RP2 lets go of the SPI pins first and takes
    them back only in the SPI-host modes, so the two never drive the same pin."""
    board.spi_claim(False)
    board.set_ui(ui_value(mode, baud, i2c_fast))
    board.uart_baud(baud)
    if mode in SPI_HOST:
        board.spi_claim(True)
    board.wait_ms(1)
    board.uart_flush()  # UART_TX is low in the safe-idle modes: drop what that looked like


def _i2c_checks(r, pins, br, sensor, expect):
    """Steps 3 and 6: the same checks through a UART host and an SPI host."""
    st = br.status()
    r.check("status returns 0x00", st == 0x00, status_text(st))
    data = br.read(EMPTY, 1)
    st = br.status()
    r.check("a read from an empty address returns 0x00 and sets NACK", data == [0x00] and st == NACK,
            "data %s, status %s" % (_hex(data), status_text(st)))
    pins.check("ERR is high", ERR, ERR)
    st = br.write(EMPTY, [0xAA])
    r.check("a NACKed write reports NACK and the unsent byte", st == (NACK | 1), status_text(st))

    data = br.write_read(sensor, 0x00, 2)
    st = br.status()
    if st & NACK:
        r.info("no device answered at 0x%02X (fine without a sensor)" % sensor)
    else:
        r.check("read of 2 bytes from register 0 of the device at 0x%02X" % sensor,
                expect is None or data == list(expect), "data " + _hex(data))
        raw = (data[0] << 8) | data[1]
        r.info("as a 16-bit temperature register (LM75 / TMP102 style): %.2f C" %
               ((raw - 65536 if raw & 0x8000 else raw) / 256.0))
        pins.check("ERR is low after a good transfer", ERR, 0)
        st = br.write(sensor, [0x00])  # sets the register pointer: harmless
        r.check("write is acknowledged", st == 0x00, status_text(st))
        again = br.read(sensor, 2)
        r.check("plain read returns the same register", expect is None or again == list(expect),
                "data " + _hex(again))
    pins.check("the bridge is idle again", STATE | BUSY, S_IDLE)


def run_all(board, sensor=0x48, expect=None, flash=False, i2c_fast=False, out=print):
    """Run every step. Returns the Report; report.failed is empty when all passed.

    sensor    I2C address to try in steps 3 and 6
    expect    bytes that register 0 of the sensor must return (the simulation sets this)
    flash     True: an SPI flash is on the top uio row, read its JEDEC ID in step 4
    i2c_fast  I2C at 367.6 kHz instead of 99.2 kHz (needs real pull-ups, not the RP2's)
    """
    r = Report(out)
    pins = _Pins(board, r)

    # ------------------------------------------------------------ 1. reset and safe idle
    r.step("1. Reset and the modes that drive nothing")
    enter(board, M_OFF)
    board.reset()
    pins.check("mode 111 after reset: every output is low", 0xFF, 0x00)
    for mode in (M_RSVD_100, M_RSVD_101):
        enter(board, mode)
        pins.check("mode %s (reserved): every output is low" % ("100" if mode == M_RSVD_100 else "101"), 0xFF, 0x00)
    enter(board, M_LOOP)
    pins.check("mode 110: UART_TX idles high, state IDLE, no flags", 0xFF, UART_TX)

    # ------------------------------------------------------------ 2. loopback
    r.step("2. Mode 110, UART loopback at the four baud rates")
    for baud in BAUDS:
        enter(board, M_LOOP, baud)
        data = [0x55, 0x00, 0xFF, 0xA5] if baud >= 57600 else [0x55, 0xA5]
        board.uart_write(data)
        got = list(board.uart_read(len(data), 200))
        r.check("echo at %d baud" % baud, got == data, "sent %s, got %s" % (_hex(data), _hex(got)))
    pins.check("IRQ, BUSY and ERR stay low in loopback", IRQ | BUSY | ERR, 0)

    # ------------------------------------------------------------ 3. UART host, I2C device
    r.step("3. Mode 001, UART host to I2C device (%s)" % ("367.6 kHz" if i2c_fast else "99.2 kHz"))
    try:
        enter(board, M_UART_I2C, i2c_fast=i2c_fast)
        _i2c_checks(r, pins, Bridge(board, M_UART_I2C), sensor, expect)
    except BridgeError as e:
        r.check("mode 001", False, str(e))

    # ------------------------------------------------------------ 4. UART host, SPI device
    r.step("4. Mode 000, UART host to SPI device")
    try:
        enter(board, M_UART_SPI)
        br = Bridge(board, M_UART_SPI)
        pins.check("idle: UART_TX high, state IDLE", 0x7F, UART_TX)  # ERR may still show step 3's NACK
        sts = [br.write(0, [0x9F, 0x00], div) for div in range(4)]
        r.check("a 2-byte write is answered with status 0x00 at each of the four SCK rates",
                sts == [0, 0, 0, 0], "status " + _hex(sts))
        st = br.status()
        r.check("status returns 0x00: a new command clears an old error flag", st == 0x00, status_text(st))
        if flash:
            data = br.write_read(0, 0x9F, 2)
            r.check("JEDEC ID read from the flash (manufacturer, memory type)",
                    data not in ([0x00, 0x00], [0xFF, 0xFF]), "data " + _hex(data))
        else:
            board.miso_pull(1)
            data = br.read(0, 2)
            r.check("read with MISO pulled high returns FF FF", data == [0xFF, 0xFF], "data " + _hex(data))
            board.miso_pull(0)
            data = br.read(0, 2)
            r.check("read with MISO pulled low returns 00 00", data == [0x00, 0x00], "data " + _hex(data))
            board.miso_pull(None)
        pins.check("the bridge is idle again and ERR is low", STATE | BUSY | ERR, S_IDLE)
    except BridgeError as e:
        r.check("mode 000", False, str(e))
    board.miso_pull(None)

    # ------------------------------------------------------------ 5. SPI host, UART device
    r.step("5. Mode 010, SPI host to UART device (the RP2 is both)")
    try:
        enter(board, M_SPI_UART)
        br = Bridge(board, M_SPI_UART)
        st = br.status()
        r.check("status over SPI returns 0x00", st == 0x00, status_text(st))
        st = br.write(0, [0x05, 0x60])
        got = list(board.uart_read(2, 200))
        r.check("write: status 0x00 and both bytes come out of UART_TX", st == 0x00 and got == [0x05, 0x60],
                "status %s, UART got %s" % (status_text(st), _hex(got)))

        board.uart_write([0x11, 0x22])  # the UART device speaks first
        board.wait_ms(2)
        pins.check("IRQ is high while received bytes wait", IRQ, IRQ)
        data = br.read(0, 2)
        r.check("read returns the two buffered bytes", data == [0x11, 0x22], "data " + _hex(data))

        br.send([cmd(OP_WRRD, 2), 0, 0x42])
        asked = list(board.uart_read(1, 200))
        board.uart_write([0x43, 0x44])
        br.wait_irq()
        data = br.fetch(2)
        r.check("write-then-read: 0x42 goes out, the 2-byte reply comes back",
                asked == [0x42] and data == [0x43, 0x44], "UART got %s, data %s" % (_hex(asked), _hex(data)))

        board.uart_write([0x01, 0x02, 0x03])  # one more than the FIFO holds
        board.wait_ms(2)
        st = br.status()
        r.check("a third unrequested byte sets the overflow flag", st == (OVF | 2), status_text(st))
        pins.check("ERR is high", ERR, ERR)
        data = br.read(0, 2)
        st = br.status()
        r.check("the read returns the first two bytes and clears the flag", data == [0x01, 0x02] and st == 0x00,
                "data %s, status %s" % (_hex(data), status_text(st)))

        br.send([cmd(OP_WRITE, 2)])  # CS rises after the CMD byte
        pins.check("a command cut short by CS is dropped (state IDLE)", STATE | BUSY, S_IDLE)
        st = br.status()
        r.check("and the next command works", st == 0x00, status_text(st))
    except BridgeError as e:
        r.check("mode 010", False, str(e))

    # ------------------------------------------------------------ 6. SPI host, I2C device
    r.step("6. Mode 011, SPI host to I2C device")
    try:
        enter(board, M_SPI_I2C, i2c_fast=i2c_fast)
        _i2c_checks(r, pins, Bridge(board, M_SPI_I2C), sensor, expect)
    except BridgeError as e:
        r.check("mode 011", False, str(e))

    # ------------------------------------------------------------ 7. back to safe idle
    r.step("7. Back to mode 111")
    enter(board, M_OFF)
    pins.check("every output is low again", 0xFF, 0x00)

    r.out("")
    r.out("%d checks, %d failed" % (len(r.results), len(r.failed)))
    return r
