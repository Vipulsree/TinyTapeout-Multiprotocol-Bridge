# SPDX-FileCopyrightText: © 2026 VLSI PD Tapeout team
# SPDX-License-Identifier: Apache-2.0
"""Top-level tests for tt_um_mpbridge. The TT CI runs these through test/Makefile,
at RTL and on the gate-level netlist, so they only use pins and tb wires.

Covers reset state and pin directions, the mode matrix (6 modes x write / read /
write-then-read / status), mode 110 loopback, error flags (I2C NACK, UART
framing, FIFO overflow) and the idle-only mode latch. There are no timeouts
(removed to fit the tile)."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

from models.i2c_controller import I2CController
from models.i2c_target import I2CTarget
from models.spi import SpiDevice, SpiHost
from models.uart import UartPeer

CLK_NS = 40  # 25 MHz

M_UART_SPI, M_UART_I2C, M_SPI_UART, M_SPI_I2C, M_I2C_UART, M_I2C_SPI, M_LOOP, M_OFF = range(8)
OP_WRITE, OP_READ, OP_WRRD, OP_STATUS = range(4)
BAUD_115200 = 0b11 << 4
I2C_FAST = 1 << 7
BRIDGE_I2C = 0x2C  # bridge's own I2C target address (I2C_ADDR_LSB = 0)
SENSOR = 0x48      # I2C device on the bridge's controller port
NACK, FRAME, OVF = 0x80, 0x40, 0x20

# uio_oe per mode with the SPI slave not selected and the I2C bus idle:
# SPI master modes drive CS_N, MOSI and SCK (bits 0, 1, 3); everything else is an input.
OE_IDLE = {M_UART_SPI: 0x0B, M_UART_I2C: 0x00, M_SPI_UART: 0x00, M_SPI_I2C: 0x00,
           M_I2C_UART: 0x00, M_I2C_SPI: 0x0B, M_LOOP: 0x00, M_OFF: 0x00}


def cmd(op, length=1, spi_div=0):
    return (op << 6) | (spi_div << 2) | (length - 1)


# ---------------------------------------------------------------------- setup
async def reset(dut, mode=M_UART_SPI, cfg=BAUD_115200 | I2C_FAST):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_cfg.value = cfg | mode
    dut.uart_rx.value = 1
    dut.spi_cs_n_drv.value = 1
    dut.spi_mosi_drv.value = 0
    dut.spi_miso_drv.value = 0
    dut.spi_sck_drv.value = 0
    dut.i2c_scl_pull.value = 0
    dut.i2c_sda_pull.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    # Safe idle while in reset: no outputs, nothing driven
    assert int(dut.uo_out.value) == 0 and int(dut.uio_oe.value) == 0
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)


async def set_mode(dut, mode, cfg=BAUD_115200 | I2C_FAST):
    dut.ui_cfg.value = cfg | mode
    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)


def check_i2c_released(dut):
    assert int(dut.i2c_push_pull_violation.value) == 0
    assert int(dut.i2c_scl.value) == 1 and int(dut.i2c_sda.value) == 1


class BusWatch:
    """Records any cycle where the bridge drives an I2C line high or a spare pin."""

    def __init__(self, dut):
        self.dut = dut
        self.faults = []
        cocotb.start_soon(self._run())

    async def _run(self):
        d = self.dut
        while True:
            await FallingEdge(d.clk)
            if int(d.i2c_push_pull_violation.value):
                self.faults.append("I2C line driven high")
            if int(d.uio_oe.value) & 0x30:
                self.faults.append("spare uio pin driven")


async def wait_irq(dut, timeout_us=2000):
    for _ in range(timeout_us):
        if int(dut.irq.value):
            return
        await Timer(1, unit="us")
    raise AssertionError("IRQ never rose")


# ---------------------------------------------------------------------- hosts
class UartHost:
    def __init__(self, dut):
        self.peer = UartPeer(dut.uart_rx, dut.uart_tx, 115200)

    async def transact(self, req, n_resp, timeout_bits=40):
        await self.peer.send(req)
        return await self.peer.recv(n_resp, timeout_bits)


class SpiHostSide:
    def __init__(self, dut, period_ns=1000):
        self.dut = dut
        self.spi = SpiHost(dut.spi_cs_n_drv, dut.spi_sck_drv, dut.spi_mosi_drv, dut.spi_miso, period_ns)

    async def transact(self, req, n_resp):
        await self.spi.transfer(req)
        await wait_irq(self.dut)
        return await self.spi.transfer([0x00] * n_resp)


class I2CHostSide:
    def __init__(self, dut):
        self.dut = dut
        self.i2c = I2CController(dut.i2c_scl_pull, dut.i2c_sda_pull, dut.i2c_scl, dut.i2c_sda,
                                 period_ns=2500)
        self.addr = BRIDGE_I2C

    async def transact(self, req, n_resp):
        assert await self.i2c.write(self.addr, req)
        # Poll: the bridge NACKs its read address until the response is ready.
        for _ in range(200):
            out = await self.i2c.read(self.addr, n_resp)
            if out is not None:
                return out
            await Timer(20, unit="us")
        raise AssertionError("bridge never ACKed the read")


HOSTS = {M_UART_SPI: UartHost, M_UART_I2C: UartHost, M_SPI_UART: SpiHostSide, M_SPI_I2C: SpiHostSide,
         M_I2C_UART: I2CHostSide, M_I2C_SPI: I2CHostSide}


def uart_device(dut):
    peer = UartPeer(dut.uart_rx, dut.uart_tx, 115200)
    # Answers command 0x42 with two bytes, like a UART sensor.
    peer.reply = lambda b: [0x43, 0x44] if b == 0x42 else None
    return peer


def spi_device(dut):
    return SpiDevice(dut.spi_cs_n, dut.spi_sck, dut.spi_mosi, dut.spi_miso_drv)


def i2c_device(dut):
    dut.i2c_sda_pull.value = 0
    tgt = I2CTarget(dut.i2c_scl, dut.i2c_sda, dut.i2c_sda_pull, address=SENSOR).start()
    tgt.regs[0:2] = bytes([0x19, 0x80])  # temperature register
    tgt.regs[6:8] = bytes([0xAB, 0xCD])
    return tgt


# ---------------------------------------------------------------------- basic
@cocotb.test()
async def test_reset_state(dut):
    await reset(dut, M_UART_SPI)
    # DBG_STATE = IDLE, UART_TX idles high, IRQ / BUSY / ERR low
    assert int(dut.uo_out.value) == 0x10
    assert int(dut.uio_oe.value) == OE_IDLE[M_UART_SPI]
    assert int(dut.uio_out.value) & 0x01  # SPI master keeps CS_N high
    check_i2c_released(dut)


@cocotb.test()
async def test_pin_directions_per_mode(dut):
    await reset(dut, M_UART_SPI)
    for mode in range(8):
        await set_mode(dut, mode)
        assert int(dut.uio_oe.value) == OE_IDLE[mode], f"mode {mode:03b}: uio_oe={int(dut.uio_oe.value):#04x}"
        expect_uo = 0x00 if mode == M_OFF else 0x10
        assert int(dut.uo_out.value) == expect_uo, f"mode {mode:03b}: uo_out={int(dut.uo_out.value):#04x}"
        assert int(dut.uio_oe.value) & 0x30 == 0  # spare pins never driven
        check_i2c_released(dut)


@cocotb.test()
async def test_spi_slave_drives_miso_only_when_selected(dut):
    await reset(dut, M_SPI_UART)
    assert int(dut.uio_oe.value) & 0x04 == 0
    dut.spi_cs_n_drv.value = 0  # host selects the bridge
    await ClockCycles(dut.clk, 4)
    await FallingEdge(dut.clk)
    assert int(dut.uio_oe.value) & 0x0F == 0x04  # only MISO is an output
    dut.spi_cs_n_drv.value = 1
    await ClockCycles(dut.clk, 4)
    await FallingEdge(dut.clk)
    assert int(dut.uio_oe.value) & 0x04 == 0


@cocotb.test()
async def test_external_i2c_activity_is_harmless(dut):
    await reset(dut, M_UART_I2C)
    # Another device wiggles the bus: the bridge must stay released.
    for scl, sda in ((1, 0), (0, 0), (0, 1), (1, 1), (0, 0), (1, 0), (1, 1)):
        dut.i2c_scl_pull.value = 1 - scl
        dut.i2c_sda_pull.value = 1 - sda
        await ClockCycles(dut.clk, 5)
        assert int(dut.uio_oe.value) & 0xC0 == 0
        assert int(dut.i2c_push_pull_violation.value) == 0


@cocotb.test()
async def test_loopback_echo(dut):
    await reset(dut, M_LOOP)
    peer = UartPeer(dut.uart_rx, dut.uart_tx, 115200)
    data = [0x55, 0x00, 0xFF, 0x0D, 0x0A, 0xA5]
    await peer.send(data)  # back to back
    assert await peer.recv(len(data)) == data
    assert int(dut.uo_out.value) & 0xE0 == 0  # IRQ / BUSY / ERR stay low
    await peer.send([0x31], gap_bits=3)
    assert await peer.recv(1) == [0x31]


# ---------------------------------------------------------------------- mode matrix
async def run_matrix(dut, mode):
    await reset(dut, mode)
    watch = BusWatch(dut)
    host = HOSTS[mode](dut)
    dev_uart = mode in (M_SPI_UART, M_I2C_UART)
    dev_spi = mode in (M_UART_SPI, M_I2C_SPI)
    if dev_uart:
        dev = uart_device(dut)
    elif dev_spi:
        dev = spi_device(dut)
    else:
        dev = i2c_device(dut)

    # write, LEN = 2: the device sees the payload; response is the status byte
    assert await host.transact([cmd(OP_WRITE, 2), SENSOR, 0x05, 0x60], 1) == [0x00]
    if dev_uart:
        assert await dev.recv(2) == [0x05, 0x60]
    elif dev_spi:
        assert dev.frames[-1] == [0x05, 0x60]
    else:
        assert dev.regs[5] == 0x60 and dev.log[-1] == ["W", [0x05, 0x60]]
    assert int(dut.err.value) == 0

    # read, LEN = 2
    if dev_uart:  # a UART device's bytes are buffered while idle; IRQ shows data waiting
        await dev.send([0x11, 0x22])
        await ClockCycles(dut.clk, 50)
        assert int(dut.irq.value) == 1
        expect = [0x11, 0x22]
    elif dev_spi:
        expect = [0xA0, 0xA1]  # flash model: 0xA0 + byte index
    else:
        expect = [0xAB, 0xCD]  # sensor pointer is 6 after the write above
    assert await host.transact([cmd(OP_READ, 2), SENSOR], 2) == expect
    if dev_spi:
        assert dev.frames[-1] == [0x00, 0x00]

    # write 1 byte then read, LEN = 2
    if dev_uart:
        req, expect = 0x42, [0x43, 0x44]
    elif dev_spi:
        req, expect = 0x9F, [0xEF, 0x40]  # JEDEC ID
    else:
        req, expect = 0x00, [0x19, 0x80]  # temperature register
    assert await host.transact([cmd(OP_WRRD, 2), SENSOR, req], 2) == expect
    if dev_uart:
        assert await dev.recv(1) == [req]
    elif dev_spi:
        assert dev.frames[-1] == [0x9F, 0x00, 0x00]
    else:
        assert dev.log[-2:] == [["W", [0x00]], ["R", [0x19, 0x80]]]

    # status: no error flags, empty FIFO
    assert await host.transact([cmd(OP_STATUS), 0x00], 1) == [0x00]
    assert int(dut.err.value) == 0 and int(dut.busy.value) == 0
    assert watch.faults == []


@cocotb.test()
async def test_mode_000_uart_to_spi(dut):
    await run_matrix(dut, M_UART_SPI)


@cocotb.test()
async def test_mode_001_uart_to_i2c(dut):
    await run_matrix(dut, M_UART_I2C)


@cocotb.test()
async def test_mode_010_spi_to_uart(dut):
    await run_matrix(dut, M_SPI_UART)


@cocotb.test()
async def test_mode_011_spi_to_i2c(dut):
    await run_matrix(dut, M_SPI_I2C)


@cocotb.test()
async def test_mode_100_i2c_to_uart(dut):
    await run_matrix(dut, M_I2C_UART)


@cocotb.test()
async def test_mode_101_i2c_to_spi(dut):
    await run_matrix(dut, M_I2C_SPI)


# ---------------------------------------------------------------------- details and errors
@cocotb.test()
async def test_spi_master_divider_and_two_bytes(dut):
    await reset(dut, M_UART_SPI)
    host = UartHost(dut)
    dev = spi_device(dut)
    for div in range(4):
        # Measure one SCK period while writing 2 bytes (the FIFO's size)
        task = cocotb.start_soon(host.transact([cmd(OP_WRITE, 2, div), 0x00, 1, 2], 1))
        await RisingEdge(dut.spi_sck)
        t0 = get_sim_time(unit="ns")
        await RisingEdge(dut.spi_sck)
        period = get_sim_time(unit="ns") - t0
        assert period == 8 * CLK_NS << div, f"SPI_DIV={div}: SCK period {period} ns"
        assert await task == [0x00]
        assert dev.frames[-1] == [1, 2]


@cocotb.test()
async def test_i2c_nack_sets_status_and_err(dut):
    await reset(dut, M_UART_I2C)
    host = UartHost(dut)
    i2c_device(dut)
    # Nobody at 0x49: NACK on the address; the unsent payload byte stays in the FIFO
    assert await host.transact([cmd(OP_WRITE, 1), 0x49, 0x00], 1) == [NACK | 1]
    assert int(dut.err.value) == 1
    # A read from the absent device is padded with 0x00; the flag stays until the next command
    assert await host.transact([cmd(OP_READ, 2), 0x49], 2) == [0x00, 0x00]
    assert await host.transact([cmd(OP_STATUS), 0], 1) == [NACK]
    # The next good command clears it
    assert await host.transact([cmd(OP_WRITE, 1), SENSOR, 0x00], 1) == [0x00]
    assert int(dut.err.value) == 0


@cocotb.test()
async def test_i2c_target_address_and_busy_nack(dut):
    await reset(dut, M_I2C_SPI)
    host = I2CHostSide(dut)
    spi_device(dut)
    # Wrong address (0x2D while I2C_ADDR_LSB = 0) and a read with no response pending: NACK
    assert not await host.i2c.write(BRIDGE_I2C + 1, [cmd(OP_STATUS), 0])
    assert await host.i2c.read(BRIDGE_I2C, 1) is None
    # I2C_ADDR_LSB = 1 moves the bridge to 0x2D
    await set_mode(dut, M_I2C_SPI, BAUD_115200 | I2C_FAST | 0x40)
    host.addr = BRIDGE_I2C + 1
    assert await host.transact([cmd(OP_STATUS), 0], 1) == [0x00]
    assert not await host.i2c.write(BRIDGE_I2C, [cmd(OP_STATUS), 0])


@cocotb.test()
async def test_uart_framing_error_and_overflow(dut):
    await reset(dut, M_SPI_UART)
    host = SpiHostSide(dut)
    dev = UartPeer(dut.uart_rx, dut.uart_tx, 115200)
    await dev.send([0x7E], bad_stop=True)
    await ClockCycles(dut.clk, 50)
    assert int(dut.err.value) == 1
    assert await host.transact([cmd(OP_STATUS), 0], 1) == [FRAME]
    # Three unsolicited bytes into a 2-byte FIFO: overflow, count 2
    await dev.send([1, 2, 3])
    await ClockCycles(dut.clk, 50)
    assert await host.transact([cmd(OP_STATUS), 0], 1) == [FRAME | OVF | 2]
    assert await host.transact([cmd(OP_READ, 2), 0], 2) == [1, 2]
    assert int(dut.err.value) == 0


@cocotb.test()
async def test_mode_pins_ignored_until_idle(dut):
    await reset(dut, M_UART_I2C)
    host = UartHost(dut)
    i2c_device(dut)
    task = cocotb.start_soon(host.transact([cmd(OP_WRRD, 2), SENSOR, 0x00], 2))
    await RisingEdge(dut.busy)  # device transaction running
    await set_mode(dut, M_UART_SPI)
    assert int(dut.uio_oe.value) & 0x0F == 0  # still the I2C mode: no SPI outputs
    assert await task == [0x19, 0x80]
    await Timer(10, unit="us")  # rest of the last stop bit
    assert int(dut.uio_oe.value) == OE_IDLE[M_UART_SPI]  # now latched
