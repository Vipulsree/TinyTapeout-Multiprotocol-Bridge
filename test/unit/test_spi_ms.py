# SPDX-License-Identifier: Apache-2.0
"""Unit tests for spi_ms: the master against the SPI device model at every
SPI_DIV, the slave against the SPI host model up to 2 MHz, and abort.
The test plays cmd_ctrl. Inputs change on falling clock edges."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

from models.spi import SpiDevice, SpiHost

OP_WRITE, OP_READ, OP_WRRD = range(3)


class Env:
    def __init__(self, dut):
        self.dut = dut
        self.fifo = []
        self.pushed = []
        self.done = 0
        self.rx = []
        self.frames = []
        self.response = []
        self.takes = 0

    async def setup(self, master=0, slave=0):
        d = self.dut
        cocotb.start_soon(Clock(d.clk, 40, unit="ns").start())
        for name in ("spi_div", "sck_drv", "mosi_drv", "miso_drv", "h_tx_data", "d_start", "d_op",
                     "d_len", "d_abort", "d_wr_data"):
            getattr(d, name).value = 0
        d.cs_n_drv.value = 1
        d.master.value, d.slave.value = master, slave
        d.rst_n.value = 0
        await ClockCycles(d.clk, 3)
        await FallingEdge(d.clk)
        d.rst_n.value = 1
        cocotb.start_soon(self._io())
        return self

    async def _io(self):
        d = self.dut
        while True:  # inputs change after the rising edge, pulses are sampled mid-cycle
            await RisingEdge(d.clk)
            d.d_wr_data.value = self.fifo[0] if self.fifo else 0
            d.h_tx_data.value = self.response[0] if self.response else 0
            await FallingEdge(d.clk)
            if int(d.d_wr_pop.value):
                self.fifo.pop(0)
            if int(d.d_rd_push.value):
                self.pushed.append(int(d.rx_data.value))
            self.done += int(d.d_done.value)
            if int(d.h_rx_valid.value):
                self.rx.append(int(d.rx_data.value))
            if int(d.h_frame_start.value):
                self.frames.append("S")
            if int(d.h_frame_end.value):
                self.frames.append("E")
            if int(d.h_tx_take.value):
                self.takes += 1
                self.response = self.response[1:]

    async def run(self, op, length, data=(), div=0):
        d = self.dut
        self.fifo, self.pushed, done0 = list(data), [], self.done
        d.spi_div.value = div
        await RisingEdge(d.clk)
        d.d_wr_data.value = self.fifo[0] if self.fifo else 0
        d.d_op.value, d.d_len.value, d.d_start.value = op, length, 1
        await RisingEdge(d.clk)
        d.d_start.value = 0
        for _ in range(10000):
            if self.done > done0:
                return
            await ClockCycles(d.clk, 10)
        raise AssertionError("master never finished")


def device(dut):
    return SpiDevice(dut.cs_n, dut.sck, dut.mosi, dut.miso_drv)


@cocotb.test()
async def test_master_ops_at_every_divider(dut):
    env = await Env(dut).setup(master=1)
    dev = device(dut)
    for div in range(4):
        await env.run(OP_WRITE, 4, [0x12, 0x34, 0x56, 0x78], div)
        assert dev.frames[-1] == [0x12, 0x34, 0x56, 0x78] and env.fifo == []
        await env.run(OP_READ, 3, div=div)
        assert dev.frames[-1] == [0, 0, 0] and env.pushed == [0xA0, 0xA1, 0xA2]
        await env.run(OP_WRRD, 4, [0x9F], div)
        assert dev.frames[-1] == [0x9F, 0, 0, 0, 0] and env.pushed == [0xEF, 0x40, 0x18, 0x00]
    assert env.done == 12


@cocotb.test()
async def test_master_timing(dut):
    env = await Env(dut).setup(master=1)
    device(dut)
    for div in range(4):
        half = (4 << div) * 40
        task = cocotb.start_soon(env.run(OP_WRITE, 1, [0xA5], div))
        await FallingEdge(dut.cs_n)
        t_cs = get_sim_time(unit="ns")
        await RisingEdge(dut.sck)
        assert get_sim_time(unit="ns") - t_cs == half  # CS_N setup: half a period
        t_r = get_sim_time(unit="ns")
        await FallingEdge(dut.sck)
        assert get_sim_time(unit="ns") - t_r == half
        await task
        assert int(dut.sck.value) == 0 and int(dut.cs_n.value) == 1


@cocotb.test()
async def test_master_abort(dut):
    env = await Env(dut).setup(master=1)
    device(dut)
    task = cocotb.start_soon(env.run(OP_WRITE, 4, [1, 2, 3, 4], 3))
    await Timer(3, unit="us")
    await RisingEdge(dut.clk)
    dut.d_abort.value = 1
    await RisingEdge(dut.clk)
    dut.d_abort.value = 0
    await ClockCycles(dut.clk, 2)
    assert int(dut.cs_n.value) == 1 and int(dut.sck.value) == 0 and int(dut.idle.value) == 1
    await Timer(20, unit="us")
    assert env.done == 0
    task.cancel()


@cocotb.test()
async def test_slave_command_and_readout_frames(dut):
    env = await Env(dut).setup(slave=1)
    host = SpiHost(dut.cs_n_drv, dut.sck_drv, dut.mosi_drv, dut.miso, period_ns=1000)
    # Command frame: MISO is whatever h_tx_data is (0x00 while cmd_ctrl is idle)
    assert await host.transfer([0x81, 0x48, 0x00]) == [0, 0, 0]
    assert env.rx == [0x81, 0x48, 0x00] and env.frames == ["S", "E"]
    # Read-out frame: one take at CS fall, then one per completed byte
    env.response = [0xC3, 0x3C]
    env.takes = 0
    assert await host.transfer([0xFF, 0xFF]) == [0xC3, 0x3C]
    assert env.takes == 3 and env.frames == ["S", "E", "S", "E"]


@cocotb.test()
async def test_slave_at_2mhz(dut):
    env = await Env(dut).setup(slave=1)
    host = SpiHost(dut.cs_n_drv, dut.sck_drv, dut.mosi_drv, dut.miso, period_ns=500)
    env.response = [0x96, 0x69, 0xF0, 0x0F]
    assert await host.transfer([0x01, 0x80, 0x7F, 0xFE]) == [0x96, 0x69, 0xF0, 0x0F]
    assert env.rx == [0x01, 0x80, 0x7F, 0xFE]
