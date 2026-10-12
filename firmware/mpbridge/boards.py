# SPDX-License-Identifier: Apache-2.0
"""What the bring-up script needs from the hardware around the bridge: reset,
the ui_in and uo_out pins, a UART on UART_RX / UART_TX and an SPI host on the
top uio row.

TTDemoBoard  the Tiny Tapeout demo board (ASIC, or the FPGA breakout in its place),
             through the TT MicroPython SDK (ttboard).
PicoBoard    a bare Raspberry Pi Pico wired to any FPGA board with jumper wires.

The UART is the RP2's hardware UART. On the demo board ui_in[3] / uo_out[4] sit
on a UART TX / RX pin pair (GP12 / GP13 on the RP2040 board, GP20 / GP37 on the
RP2350 board). The SPI host is machine.SoftSPI, so it works on any pins.
"""
from machine import PWM, UART, Pin, SoftSPI
from time import sleep_ms, ticks_diff, ticks_ms


def uart_id(tx, rx):
    """Which hardware UART has TX on GPIO tx and RX on GPIO rx (RP2040 and RP2350)."""
    a, b = ((tx + 4) // 8) % 2, ((rx + 4) // 8) % 2
    if tx % 4 != 0 or rx % 4 != 1 or a != b:
        raise ValueError("GP%d / GP%d are not a UART TX / RX pair" % (tx, rx))
    return a


class _RP2Board:
    """Everything that only needs GPIO numbers. ui / uo / uio are lists of 8."""

    def _pins(self, ui, uo, uio, spi_hz):
        self._ui = [Pin(g, Pin.OUT, value=0) if g is not None and i != 3 else None for i, g in enumerate(ui)]
        self._uo = [Pin(g) for g in uo] if uo else None  # read only: the mode of the pin is left alone
        self._tx, self._rx = ui[3], (uo[4] if uo else None)
        self._cs, self._mosi, self._miso, self._sck = uio[0], uio[1], uio[2], uio[3]
        self._scl, self._sda = uio[6], uio[7]
        self._spi_hz = spi_hz
        self._spi = None
        self._uart = None
        self.spi_claim(False)
        self.i2c_pullups(True)
        self.uart_baud(115200)

    def i2c_pullups(self, on):
        """RP2 pull-ups on the I2C lines (uio[6], uio[7]). Without any pull-up the
        bridge sees SCL low, takes that for a stretched clock and waits for ever.
        They are weak (tens of kOhm): enough for 99.2 kHz with nothing connected.
        A sensor board brings its own; fit 2.2 to 4.7 kOhm for 367.6 kHz."""
        for g in (self._scl, self._sda):
            if g is not None:
                Pin(g, Pin.IN, Pin.PULL_UP if on else None)

    def set_ui(self, value):
        for i, p in enumerate(self._ui):
            if p is not None:
                p.value((value >> i) & 1)

    def uo(self):
        if not self._uo:
            return None
        v = 0
        for i, p in enumerate(self._uo):
            v |= p.value() << i
        return v

    def wait_ms(self, ms):
        sleep_ms(ms)

    # ---------------------------------------------------------------- UART
    def uart_baud(self, baud):
        if self._rx is None:
            raise ValueError("uo_out[4] (UART_TX) must be wired")
        self._uart = UART(uart_id(self._tx, self._rx), baudrate=baud, bits=8, parity=None, stop=1,
                          tx=Pin(self._tx), rx=Pin(self._rx))

    def uart_write(self, data):
        self._uart.write(bytes(data))
        if hasattr(self._uart, "flush"):
            self._uart.flush()  # wait until the last byte has left

    def uart_read(self, n, timeout_ms=200):
        buf = b""
        t0 = ticks_ms()
        while len(buf) < n and ticks_diff(ticks_ms(), t0) < timeout_ms:
            if self._uart.any():
                buf += self._uart.read(min(self._uart.any(), n - len(buf)))
        return list(buf)

    def uart_flush(self):
        while self._uart.any():
            self._uart.read()

    # ---------------------------------------------------------------- SPI host
    def spi_claim(self, on):
        """True: drive CS_N, MOSI and SCK (the bridge is the SPI slave, modes 010 / 011).
        False: let go of them (in mode 000 the bridge drives them)."""
        if on:
            self._cs_pin = Pin(self._cs, Pin.OUT, value=1)
            self._spi = SoftSPI(baudrate=self._spi_hz, polarity=0, phase=0, sck=Pin(self._sck),
                                mosi=Pin(self._mosi), miso=Pin(self._miso))
        else:
            self._spi = None
            Pin(self._cs, Pin.IN, Pin.PULL_UP)  # not selected
            Pin(self._mosi, Pin.IN, Pin.PULL_DOWN)
            Pin(self._sck, Pin.IN, Pin.PULL_DOWN)
            Pin(self._miso, Pin.IN, None)

    def spi_transfer(self, data):
        """One CS-low frame: sends data, returns what came back on MISO."""
        out = bytearray(len(data))
        self._cs_pin.value(0)
        self._spi.write_readinto(bytes(data), out)
        self._cs_pin.value(1)
        return list(out)

    def miso_pull(self, level):
        """Mode 000 without an SPI device: pull MISO high (1), low (0) or not at all (None)."""
        Pin(self._miso, Pin.IN, None if level is None else (Pin.PULL_UP if level else Pin.PULL_DOWN))


class TTDemoBoard(_RP2Board):
    def __init__(self, tt=None, clock_hz=25_000_000, spi_hz=100_000):
        """tt: the SDK's DemoBoard object (the `tt` of the REPL). The design must
        already be selected: tt.shuttle.<name>.enable()."""
        if tt is None:
            from ttboard.demoboard import DemoBoard
            tt = DemoBoard.get()
        from ttboard.mode import RPMode
        tt.mode = RPMode.ASIC_RP_CONTROL  # the RP2 drives ui_in, clock and reset
        self.tt = tt
        p = tt.pins
        tt.clock_project_PWM(clock_hz)  # the baud rates and bus rates assume 25 MHz
        self._pins([getattr(p, "ui_in%d" % i).gpio_num for i in range(8)],
                   [getattr(p, "uo_out%d" % i).gpio_num for i in range(8)],
                   [getattr(p, "uio%d" % i).gpio_num for i in range(8)], spi_hz)

    def reset(self, ms=10):
        self.tt.reset_project(True)
        sleep_ms(ms)
        self.tt.reset_project(False)
        sleep_ms(ms)


class PicoBoard(_RP2Board):
    def __init__(self, ui, uo, uio, rst_n=None, clk=None, clock_hz=25_000_000, spi_hz=100_000):
        """GPIO numbers on the Pico.
        ui     8 GPIOs wired to ui_in[0..7]; ui[3] (UART_RX of the bridge) must be a UART TX
               pin; entries may be None for pins strapped on the FPGA board
        uo     8 GPIOs wired to uo_out[0..7]; uo[4] (UART_TX of the bridge) must be the RX pin
               of the same UART
        uio    8 GPIOs wired to uio[0..7]; uio[4] and uio[5] may be None
        rst_n  GPIO wired to rst_n (None: reset the FPGA by hand when asked)
        clk    GPIO that outputs the 25 MHz clock (None: the FPGA board has its own)"""
        self.rst = Pin(rst_n, Pin.OUT, value=1) if rst_n is not None else None
        if clk is not None:
            self.pwm = PWM(Pin(clk))
            self.pwm.freq(clock_hz)
            self.pwm.duty_u16(32768)
        self._pins(ui, uo, uio, spi_hz)

    def reset(self, ms=10):
        if self.rst is None:
            input("Press and release the reset button of the FPGA board, then Enter ")
            return
        self.rst.value(0)
        sleep_ms(ms)
        self.rst.value(1)
        sleep_ms(ms)
