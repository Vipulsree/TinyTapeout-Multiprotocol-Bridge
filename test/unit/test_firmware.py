# SPDX-License-Identifier: Apache-2.0
"""The RP2 firmware (firmware/mpbridge) against the RTL.

The firmware's bridge client and bring-up checklist are plain blocking Python.
Here they run unchanged in a thread next to the simulator: the board below
puts the UART and SPI traffic on the testbench pins instead of on GPIOs. So
the commands and the checklist that will run on the demo board are the ones
exercised here, on a bare board and with an I2C sensor and an SPI flash."""
import cocotb
from cocotb.clock import Clock
from cocotb.task import bridge, resume
from cocotb.triggers import ClockCycles, FallingEdge, Timer

from models.i2c_target import I2CTarget
from models.spi import SpiDevice, SpiHost
from models.uart import UartPeer
from mpbridge import bringup
from mpbridge.bridge import M_SPI_I2C, M_UART_I2C, M_UART_SPI, NACK, Bridge

CLK_NS = 40  # 25 MHz
SENSOR = 0x48


class SimBoard:
    """The board interface of firmware/mpbridge/boards.py on the testbench pins."""

    def __init__(self, dut):
        self.dut = dut
        self.peer = None
        self.claimed = False
        self.spi = SpiHost(dut.spi_cs_n_drv, dut.spi_sck_drv, dut.spi_mosi_drv, dut.spi_miso, 1000)
        self.contention = []
        for name in ("reset", "set_ui", "uo", "wait_ms", "uart_baud", "uart_write", "uart_read", "uart_flush",
                     "spi_claim", "spi_transfer", "miso_pull"):
            setattr(self, name, resume(getattr(self, "_" + name)))

    async def _reset(self):
        d = self.dut
        d.rst_n.value = 0
        await ClockCycles(d.clk, 5)
        await FallingEdge(d.clk)
        d.rst_n.value = 1
        await ClockCycles(d.clk, 5)

    async def _set_ui(self, value):
        self.dut.ui_cfg.value = value
        await ClockCycles(self.dut.clk, 4)

    async def _uo(self):
        await ClockCycles(self.dut.clk, 8)  # let the synchronisers catch up
        await FallingEdge(self.dut.clk)
        return int(self.dut.uo_out.value)

    async def _wait_ms(self, ms):
        # A board millisecond lasts 100 us here. The firmware's waits only have to
        # outlast a few clock cycles or one I2C transfer, and simulated time is slow.
        await Timer(ms * 100, unit="us")

    async def _uart_baud(self, baud):
        if self.peer is not None:
            self.peer.stop()
        self.peer = UartPeer(self.dut.uart_rx, self.dut.uart_tx, baud)

    async def _uart_write(self, data):
        await self.peer.send(list(data))

    async def _uart_read(self, n, timeout_ms=200):
        waited = 0
        while len(self.peer.received) < n and waited < timeout_ms * 20:
            await Timer(50, unit="us")
            waited += 1
        out, self.peer.received = self.peer.received[:n], self.peer.received[n:]
        return out

    async def _uart_flush(self):
        self.peer.received.clear()

    async def _spi_claim(self, on):
        # The RP2 may only drive CS_N, MOSI and SCK while the bridge does not.
        self.claimed = on
        if on and int(self.dut.uio_oe.value) & 0x0B:
            self.contention.append("SPI pins claimed while the bridge drives them")
        self.dut.spi_cs_n_drv.value = 1  # released: pulled high

    async def _spi_transfer(self, data):
        assert self.claimed, "SPI transfer without the pins"
        return await self.spi.transfer(list(data))

    async def _miso_pull(self, level):
        self.dut.spi_miso_drv.value = 1 if level else 0


class BusWatch:
    """Records any cycle where the bridge drives a pin it must not."""

    def __init__(self, dut, board):
        self.dut = dut
        self.board = board
        self.faults = []
        cocotb.start_soon(self._run())

    async def _run(self):
        d = self.dut
        while True:
            await FallingEdge(d.clk)
            if not int(d.rst_n.value):
                continue
            oe = int(d.uio_oe.value)
            if int(d.i2c_push_pull_violation.value):
                self.faults.append("I2C line driven high")
            if oe & 0x30:
                self.faults.append("spare uio pin driven")
            if self.board.claimed and oe & 0x0B:
                self.faults.append("bridge and RP2 both drive an SPI pin")


async def setup(dut, sensor=False, flash=False):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_cfg.value = 0x07
    dut.uart_rx.value = 1
    dut.spi_cs_n_drv.value = 1
    dut.spi_mosi_drv.value = 0
    dut.spi_miso_drv.value = 0
    dut.spi_sck_drv.value = 0
    dut.i2c_scl_pull.value = 0
    dut.i2c_sda_pull.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    tgt = dev = None
    if sensor:
        tgt = I2CTarget(dut.i2c_scl, dut.i2c_sda, dut.i2c_sda_pull, address=SENSOR).start()
        tgt.regs[0:2] = bytes([0x19, 0x80])  # temperature register
    if flash:
        dev = SpiDevice(dut.spi_cs_n, dut.spi_sck, dut.spi_mosi, dut.spi_miso_drv)
    board = SimBoard(dut)
    return board, BusWatch(dut, board), tgt, dev


async def checklist(dut, board, **kw):
    lines = []
    report = await bridge(bringup.run_all)(board, sensor=SENSOR, out=lines.append, **kw)
    for line in lines:
        dut._log.info(line)
    assert report.failed == [], report.failed
    return report, lines


@cocotb.test()
async def test_bringup_bare_board(dut):
    """Nothing plugged in: the checklist as it runs on a demo board on its own."""
    board, watch, _, _ = await setup(dut)
    report, lines = await checklist(dut, board)
    assert len(report.results) == 36, len(report.results)
    assert sum("no device answered" in line for line in lines) == 2
    assert watch.faults == [] and board.contention == []


@cocotb.test()
async def test_bringup_with_sensor_and_flash(dut):
    board, watch, tgt, dev = await setup(dut, sensor=True, flash=True)
    report, lines = await checklist(dut, board, expect=[0x19, 0x80], flash=True, i2c_fast=True)
    assert len(report.results) == 43, len(report.results)
    assert any("JEDEC ID" in line and "EF 40" in line for line in lines)
    assert any("25.50 C" in line for line in lines)
    assert tgt.log.count(["R", [0x19, 0x80]]) == 4  # write-then-read and plain read, in modes 001 and 011
    assert [0x9F, 0x00, 0x00] in dev.frames
    assert watch.faults == [] and board.contention == []


@cocotb.test()
async def test_bridge_client(dut):
    """The Bridge class by hand, as from the REPL: I2C scan, then the SPI device."""
    board, watch, tgt, dev = await setup(dut, sensor=True, flash=True)
    tgt.regs[0:4] = bytes([1, 2, 3, 4])

    def session():
        bringup.enter(board, M_UART_I2C, i2c_fast=True)
        board.reset()
        br = Bridge(board, M_UART_I2C)
        assert br.write_read(SENSOR, 0x00, 2) == [1, 2]
        assert br.read(SENSOR, 2) == [3, 4]
        assert br.write(SENSOR, [0x02, 0xAA]) == 0x00
        assert br.write_read(SENSOR, 0x02, 1) == [0xAA]
        assert br.status() == 0x00
        assert br.scan(0x47, 0x49) == [SENSOR]
        assert br.status() == NACK  # the last scanned address did not answer

        bringup.enter(board, M_SPI_I2C, i2c_fast=True)
        br = Bridge(board, M_SPI_I2C)
        assert br.scan(0x48, 0x49) == [SENSOR]
        assert br.write_read(SENSOR, 0x00, 2) == [1, 2]

        bringup.enter(board, M_UART_SPI)
        br = Bridge(board, M_UART_SPI)
        assert br.write_read(0, 0x9F, 2) == [0xEF, 0x40]
        assert br.write(0, [0x04], spi_div=3) == 0x00

    await bridge(session)()
    assert dev.frames[-1] == [0x04]
    assert watch.faults == [] and board.contention == []
