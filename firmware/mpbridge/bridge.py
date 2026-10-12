# SPDX-License-Identifier: Apache-2.0
"""Host side of the bridge protocol (docs/info.md).

A command is CMD, ADDR and up to 2 payload bytes. A UART host sends it and the
response follows on the bridge's TX. An SPI host sends it in one CS-low frame,
waits for IRQ and clocks the response out in a second frame.

The board object (boards.py, or the simulator in test/unit/test_firmware.py)
supplies the UART and SPI ports."""

# MODE, ui_in[2:0]
M_UART_SPI, M_UART_I2C, M_SPI_UART, M_SPI_I2C, M_RSVD_100, M_RSVD_101, M_LOOP, M_OFF = range(8)
UART_HOST = (M_UART_SPI, M_UART_I2C)
SPI_HOST = (M_SPI_UART, M_SPI_I2C)

# ui_in
BAUDS = (9600, 19200, 57600, 115200)  # BAUD_SEL, ui_in[5:4]
I2C_FAST = 0x80                       # ui_in[7]: 0 = 99.2 kHz, 1 = 367.6 kHz

# uo_out
STATE, UART_TX, IRQ, BUSY, ERR = 0x07, 0x10, 0x20, 0x40, 0x80
S_IDLE, S_HEADER, S_WRITE, S_EXEC, S_RESPOND = range(5)

OP_WRITE, OP_READ, OP_WRRD, OP_STATUS = range(4)

# Status byte
NACK = 0x80   # the I2C device did not acknowledge
FRAME = 0x40  # UART framing error
OVF = 0x20    # FIFO overflow
COUNT = 0x03  # bytes in the FIFO


def ui_value(mode, baud=115200, i2c_fast=False):
    """ui_in for a mode and settings. Bit 3 is the UART line: the board owns it."""
    return mode | (BAUDS.index(baud) << 4) | (I2C_FAST if i2c_fast else 0)


def cmd(op, length=1, spi_div=0):
    """CMD byte: op in bits 7:6, SPI clock divider in bits 3:2, length - 1 in bit 0."""
    if length not in (1, 2):
        raise ValueError("length must be 1 or 2")
    return (op << 6) | ((spi_div & 3) << 2) | (length - 1)


def status_text(s):
    flags = [n for bit, n in ((NACK, "NACK"), (FRAME, "FRAMING"), (OVF, "OVERFLOW")) if s & bit]
    return "0x%02X (%s, FIFO count %d)" % (s, " ".join(flags) or "ok", s & COUNT)


class BridgeError(Exception):
    pass


class Bridge:
    def __init__(self, board, mode, timeout_ms=200):
        """mode: the MODE value the bridge is in; it decides which port carries the commands."""
        if mode not in UART_HOST and mode not in SPI_HOST:
            raise ValueError("mode %d has no host port" % mode)
        self.board = board
        self.spi = mode in SPI_HOST
        self.timeout_ms = timeout_ms

    # ---------------------------------------------------------------- SPI host, step by step
    def send(self, request):
        """SPI host: the command frame."""
        self.board.spi_transfer(request)

    def wait_irq(self):
        """SPI host: wait until the response is ready. Without uo_out wired, just wait."""
        b = self.board
        if b.uo() is None:
            b.wait_ms(20)
            return
        for _ in range(self.timeout_ms):
            if b.uo() & IRQ:
                return
            b.wait_ms(1)
        raise BridgeError("IRQ never rose")

    def fetch(self, n):
        """SPI host: the read-out frame."""
        return list(self.board.spi_transfer([0x00] * n))

    # ---------------------------------------------------------------- commands
    def transact(self, request, n):
        """Send a command, return the n response bytes."""
        if self.spi:
            self.send(request)
            self.wait_irq()
            return self.fetch(n)
        self.board.uart_write(request)
        out = list(self.board.uart_read(n, self.timeout_ms))
        if len(out) < n:
            raise BridgeError("no answer on UART (%d of %d bytes)" % (len(out), n))
        return out

    def status(self):
        """Status byte; does not clear the error flags."""
        return self.transact([cmd(OP_STATUS), 0], 1)[0]

    def write(self, addr, data, spi_div=0):
        """Write 1 or 2 bytes to the device. Returns the status byte (0x00 = done)."""
        data = list(data)
        return self.transact([cmd(OP_WRITE, len(data), spi_div), addr] + data, 1)[0]

    def read(self, addr, length, spi_div=0):
        """Read 1 or 2 bytes. A NACKed I2C read returns zeros: check status()."""
        return self.transact([cmd(OP_READ, length, spi_div), addr], length)

    def write_read(self, addr, byte, length, spi_div=0):
        """Write one byte (a register pointer or a command), then read 1 or 2 bytes."""
        return self.transact([cmd(OP_WRRD, length, spi_div), addr, byte], length)

    def scan(self, first=0x08, last=0x77):
        """I2C device modes: addresses that ACK a 1-byte read."""
        found = []
        for addr in range(first, last + 1):
            self.read(addr, 1)
            if not self.status() & NACK:
                found.append(addr)
        return found
