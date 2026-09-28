# SPDX-License-Identifier: Apache-2.0
"""Unit tests for uart_trx against the Python UART model: bit timing at every
BAUD_SEL, host streaming, the device sequencer, framing errors and loopback.
The test plays cmd_ctrl. Inputs change on falling clock edges."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

from models.uart import UartPeer

OP_WRITE, OP_READ, OP_WRRD = range(3)
DIV = {0b00: 2604, 0b01: 1302, 0b10: 434, 0b11: 217}  # clocks per bit
BAUD = {0b00: 9600, 0b01: 19200, 0b10: 57600, 0b11: 115200}


class Env:
    def __init__(self, dut):
        self.dut = dut
        self.rx = []        # host role: bytes received
        self.pushed = []    # device role: bytes pushed
        self.fifo = []      # device role: bytes to send
        self.response = []  # host role: bytes to send
        self.done = 0
        self.ferr = 0

    async def setup(self, host=0, dev=0, loop=0, baud=0b11):
        d = self.dut
        cocotb.start_soon(Clock(d.clk, 40, unit="ns").start())
        for name in ("h_tx_data", "h_tx_valid", "d_start", "d_op", "d_len", "d_abort", "d_wr_data"):
            getattr(d, name).value = 0
        d.host.value, d.dev.value, d.loop.value, d.baud.value = host, dev, loop, baud
        d.rst_n.value = 0
        await ClockCycles(d.clk, 3)
        await FallingEdge(d.clk)
        d.rst_n.value = 1
        self.peer = UartPeer(d.rx_pin, d.tx, BAUD[baud])
        cocotb.start_soon(self._io())
        return self

    async def _io(self):
        # Inputs change just after the rising edge, like cmd_ctrl's registers;
        # pulses are sampled mid-cycle and take effect at the next rising edge.
        d = self.dut
        while True:
            await RisingEdge(d.clk)
            d.h_tx_data.value = self.response[0] if self.response else 0
            d.h_tx_valid.value = 1 if self.response else 0
            d.d_wr_data.value = self.fifo[0] if self.fifo else 0
            await FallingEdge(d.clk)
            if int(d.h_rx_valid.value):
                self.rx.append(int(d.h_rx_data.value))
            if int(d.h_tx_take.value):
                self.response = self.response[1:]
            if int(d.d_rd_push.value):
                self.pushed.append(int(d.d_rd_data.value))
            if int(d.d_wr_pop.value):
                self.fifo.pop(0)
            self.done += int(d.d_done.value)
            self.ferr += int(d.frame_err.value)

    async def start(self, op, length):
        d = self.dut
        await RisingEdge(d.clk)
        d.d_op.value, d.d_len.value, d.d_start.value = op, length, 1
        await RisingEdge(d.clk)
        d.d_start.value = 0


@cocotb.test()
async def test_bit_time_and_rx_at_every_rate(dut):
    env = await Env(dut).setup(host=1)
    for baud in (0b11, 0b10, 0b01, 0b00):
        dut.baud.value = baud
        env.peer.stop()
        env.peer = UartPeer(dut.rx_pin, dut.tx, BAUD[baud])
        env.rx = []
        await ClockCycles(dut.clk, 2)
        env.response = [0x55]  # alternating bits: every edge is a bit boundary
        # 0x55 LSB first: start 0, then 1 0 1 0 ... so SDA falls at bits 1, 3, 5, 7.
        # Time bits 1 to 3: the first start bit may be up to 1/7 bit short.
        await FallingEdge(dut.tx)  # start bit
        await FallingEdge(dut.tx)  # bit 1
        t0 = get_sim_time(unit="ns")
        await FallingEdge(dut.tx)  # bit 3
        bit_ns = (get_sim_time(unit="ns") - t0) / 2
        assert bit_ns == DIV[baud] * 40, f"BAUD_SEL={baud:02b}: bit time {bit_ns} ns"
        assert await env.peer.recv(1) == [0x55]
        await env.peer.send([0xA7, 0x00])
        await Timer(env.peer.bit_ps // 1000, unit="ns")
        assert env.rx == [0xA7, 0x00], f"BAUD_SEL={baud:02b}: {env.rx}"


@cocotb.test()
async def test_host_streams_response_back_to_back(dut):
    env = await Env(dut).setup(host=1)
    env.response = [0x01, 0x02, 0x03, 0x04]
    t0 = get_sim_time(unit="ns")
    assert await env.peer.recv(4) == [0x01, 0x02, 0x03, 0x04]
    # 4 frames of 10 bits with no gaps: under 42 bit times (recv polls once per bit;
    # a one-bit gap between frames would take 44)
    assert get_sim_time(unit="ns") - t0 < 42 * 217 * 40
    assert env.response == []


@cocotb.test()
async def test_framing_error(dut):
    env = await Env(dut).setup(host=1)
    await env.peer.send([0x3C], bad_stop=True, gap_bits=1)  # line back to idle
    await env.peer.send([0x3D])
    await Timer(20, unit="us")
    assert env.ferr == 1 and env.rx == [0x3D]  # the bad byte is dropped, the next one arrives


@cocotb.test()
async def test_device_write_and_write_then_read(dut):
    env = await Env(dut).setup(dev=1)
    env.fifo = [0x10, 0x20, 0x30]
    await env.start(OP_WRITE, 3)
    assert await env.peer.recv(3) == [0x10, 0x20, 0x30]
    await Timer(20, unit="us")
    assert env.done == 1 and env.fifo == []
    # write-then-read: one byte out, d_done after LEN reply bytes
    env.peer.reply = lambda b: [b + 1, b + 2]
    env.fifo = [0x40]
    await env.start(OP_WRRD, 2)
    assert await env.peer.recv(1) == [0x40]
    await Timer(250, unit="us")
    assert env.pushed == [0x41, 0x42] and env.done == 2


@cocotb.test()
async def test_device_abort_and_idle_buffering(dut):
    env = await Env(dut).setup(dev=1)
    env.fifo = [0x40]
    await env.start(OP_WRRD, 3)  # nobody answers
    await Timer(200, unit="us")
    await RisingEdge(dut.clk)
    dut.d_abort.value = 1
    await RisingEdge(dut.clk)
    dut.d_abort.value = 0
    await ClockCycles(dut.clk, 5)
    assert int(dut.idle.value) == 1 and env.done == 0
    # While idle every received byte is pushed (cmd_ctrl buffers it)
    await env.peer.send([0x99])
    await Timer(20, unit="us")
    assert env.pushed == [0x99]


@cocotb.test()
async def test_loopback_echo(dut):
    env = await Env(dut).setup(loop=1)
    data = list(range(0x30, 0x3A))
    await env.peer.send(data)
    assert await env.peer.recv(len(data)) == data
    assert env.rx == [] and env.pushed == []  # nothing reaches cmd_ctrl
