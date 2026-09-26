# SPDX-License-Identifier: Apache-2.0
"""Unit tests for cmd_ctrl. The host byte stream is driven directly and a fake
device engine answers d_start. Inputs change on falling edges."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

S_IDLE, S_HEADER, S_WRITE, S_EXEC, S_RESPOND = range(5)
OP_WRITE, OP_READ, OP_WRRD, OP_STATUS = range(4)

INPUTS = ("h_rx_data", "h_rx_valid", "h_frame_start", "h_frame_rd", "h_frame_end", "h_tx_take",
          "d_done", "d_nack", "d_wr_pop", "d_rd_data", "d_rd_push", "frame_err")
TIMEOUT = 0x10  # status byte bit 4


def cmd(op, length, spi_div=0):
    return (op << 6) | (spi_div << 2) | (length - 1)


class Env:
    def __init__(self, dut):
        self.dut = dut
        self.reads = []       # bytes the fake device returns
        self.n_reads = None   # push this many bytes instead of d_len (short UART reply)
        self.nack = False     # fake device reports a NACK
        self.hang = False     # fake device never pulses d_done
        self.writes = []      # bytes the fake device popped
        self.starts = []      # (op, len, addr, spi_div) per d_start
        self.aborts = 0       # d_abort pulses seen

    async def setup(self, host_uart=1, dev_uart=0, host_limit=2000, dev_limit=2000):
        d = self.dut
        cocotb.start_soon(Clock(d.clk, 40, unit="ns").start())
        for name in INPUTS:
            getattr(d, name).value = 0
        d.host_uart.value = host_uart
        d.dev_uart.value = dev_uart
        d.to_host_limit.value = host_limit
        d.to_dev_limit.value = dev_limit
        d.rst_n.value = 0
        await ClockCycles(d.clk, 2)
        await FallingEdge(d.clk)
        d.rst_n.value = 1
        await FallingEdge(d.clk)
        cocotb.start_soon(self._device())
        cocotb.start_soon(self._abort_watch())
        return self

    async def _abort_watch(self):
        while True:
            await FallingEdge(self.dut.clk)
            self.aborts += int(self.dut.d_abort.value)

    async def _device(self):
        d = self.dut
        while True:
            await FallingEdge(d.clk)
            if not int(d.d_start.value):
                continue
            op, ln = int(d.d_op.value), int(d.d_len.value)
            self.starts.append((op, ln, int(d.d_addr.value), int(d.d_spi_div.value)))
            for _ in range({OP_WRITE: ln, OP_WRRD: 1}.get(op, 0)):
                self.writes.append(int(d.d_wr_data.value))
                d.d_wr_pop.value = 1
                await FallingEdge(d.clk)
                d.d_wr_pop.value = 0
                await FallingEdge(d.clk)
            if op in (OP_READ, OP_WRRD):
                for _ in range(ln if self.n_reads is None else self.n_reads):
                    d.d_rd_data.value = self.reads.pop(0) if self.reads else 0xEE
                    d.d_rd_push.value = 1
                    await FallingEdge(d.clk)
                    d.d_rd_push.value = 0
            if self.hang:
                continue
            await ClockCycles(d.clk, 3)
            await FallingEdge(d.clk)
            d.d_nack.value = int(self.nack)
            d.d_done.value = 1
            await FallingEdge(d.clk)
            d.d_done.value = 0
            d.d_nack.value = 0

    # ------------------------------------------------------------ host side
    async def send(self, *data):
        d = self.dut
        for b in data:
            d.h_rx_data.value = b
            d.h_rx_valid.value = 1
            await FallingEdge(d.clk)
            d.h_rx_valid.value = 0
            await FallingEdge(d.clk)

    async def pulse(self, name, **extra):
        d = self.dut
        for k, v in extra.items():
            getattr(d, k).value = v
        getattr(d, name).value = 1
        await FallingEdge(d.clk)
        getattr(d, name).value = 0
        for k in extra:
            getattr(d, k).value = 0
        await FallingEdge(d.clk)

    async def wait_state(self, st, limit=200):
        for _ in range(limit):
            if int(self.dut.state.value) == st:
                return
            await FallingEdge(self.dut.clk)
        raise AssertionError(f"state {int(self.dut.state.value)} never reached {st}")

    async def take(self, n):
        d, out = self.dut, []
        for _ in range(n):
            assert int(d.h_tx_valid.value) == 1, f"response ran out after {out}"
            out.append(int(d.h_tx_data.value))
            await self.pulse("h_tx_take")
        return out

    async def transact(self, *data, n_resp):
        """UART-host style: send the command, wait for the response, read it."""
        await self.send(*data)
        await self.wait_state(S_RESPOND)
        resp = await self.take(n_resp)
        await self.wait_state(S_IDLE, limit=5)
        return resp


@cocotb.test()
async def test_write_returns_status(dut):
    env = await Env(dut).setup()
    resp = await env.transact(cmd(OP_WRITE, 2), 0x48, 0x01, 0x60, n_resp=1)
    assert env.starts == [(OP_WRITE, 2, 0x48, 0)]
    assert env.writes == [0x01, 0x60]
    assert resp == [0x00]
    assert int(dut.err.value) == 0 and int(dut.busy.value) == 0


@cocotb.test()
async def test_read_returns_data(dut):
    env = await Env(dut).setup()
    env.reads = [0xAA, 0xBB]
    resp = await env.transact(cmd(OP_READ, 2), 0x48, n_resp=2)
    assert env.starts == [(OP_READ, 2, 0x48, 0)] and env.writes == []
    assert resp == [0xAA, 0xBB]


@cocotb.test()
async def test_write_then_read(dut):
    env = await Env(dut).setup()
    env.reads = [0x12, 0x34]
    resp = await env.transact(0x81, 0x48, 0x00, n_resp=2)  # the example from the plan
    assert env.starts == [(OP_WRRD, 2, 0x48, 0)] and env.writes == [0x00]
    assert resp == [0x12, 0x34]


@cocotb.test()
async def test_status_skips_device(dut):
    env = await Env(dut).setup()
    resp = await env.transact(cmd(OP_STATUS, 1), 0x00, n_resp=1)
    assert env.starts == [] and resp == [0x00]


@cocotb.test()
async def test_busy_during_exec(dut):
    env = await Env(dut).setup()
    await env.send(cmd(OP_READ, 1), 0x48)
    await env.wait_state(S_EXEC, limit=5)
    assert int(dut.busy.value) == 1 and int(dut.can_write.value) == 0
    await env.wait_state(S_RESPOND)
    await env.take(1)


@cocotb.test()
async def test_nack_sets_err_until_next_command(dut):
    env = await Env(dut).setup()
    env.nack = True
    assert await env.transact(cmd(OP_WRITE, 1), 0x50, 0x00, n_resp=1) == [0x80]
    assert int(dut.err.value) == 1
    env.nack = False
    # a status read reports the flag without clearing it
    assert await env.transact(cmd(OP_STATUS, 1), 0x00, n_resp=1) == [0x80]
    assert await env.transact(cmd(OP_WRITE, 1), 0x48, 0x00, n_resp=1) == [0x00]
    assert int(dut.err.value) == 0


@cocotb.test()
async def test_spi_div_and_max_length(dut):
    env = await Env(dut).setup()
    await env.transact(cmd(OP_WRITE, 4, spi_div=3), 0x00, 1, 2, 3, 4, n_resp=1)
    assert env.starts == [(OP_WRITE, 4, 0x00, 3)] and env.writes == [1, 2, 3, 4]


@cocotb.test()
async def test_framed_host_readout(dut):
    env = await Env(dut).setup(host_uart=0)
    env.reads = [0x01, 0x02]
    await env.send(cmd(OP_READ, 2), 0x48)
    await env.wait_state(S_RESPOND)
    assert int(dut.irq.value) == 1 and int(dut.can_read.value) == 1 and int(dut.busy.value) == 0
    await env.pulse("h_frame_start", h_frame_rd=1)
    assert await env.take(2) == [0x01, 0x02]
    assert int(dut.h_tx_valid.value) == 0 and int(dut.h_tx_data.value) == 0  # extra clocks read 0x00
    assert int(dut.state.value) == S_RESPOND  # stays until the frame ends
    await env.pulse("h_frame_end")
    assert int(dut.state.value) == S_IDLE and int(dut.irq.value) == 0


@cocotb.test()
async def test_framed_host_short_frame_aborts(dut):
    env = await Env(dut).setup(host_uart=0)
    await env.send(cmd(OP_WRITE, 2))
    assert int(dut.state.value) == S_HEADER
    await env.pulse("h_frame_end")
    assert int(dut.state.value) == S_IDLE and env.starts == []
    await env.send(cmd(OP_WRITE, 2), 0x48, 0x01)
    await env.pulse("h_frame_end")
    assert int(dut.state.value) == S_IDLE and env.starts == []


@cocotb.test()
async def test_i2c_host_new_write_drops_response(dut):
    env = await Env(dut).setup(host_uart=0)
    await env.send(cmd(OP_READ, 1), 0x48)
    await env.wait_state(S_RESPOND)
    await env.pulse("h_frame_start", h_frame_rd=0)  # I2C write frame instead of a read
    assert int(dut.state.value) == S_IDLE
    await env.send(cmd(OP_STATUS, 1), 0x00)
    await env.wait_state(S_RESPOND)


@cocotb.test()
async def test_uart_device_buffers_rx_while_idle(dut):
    env = await Env(dut).setup(host_uart=0, dev_uart=1)
    for b in (0x41, 0x42, 0x43):  # bytes arriving on the device-side UART
        dut.d_rd_data.value = b
        await env.pulse("d_rd_push")
    assert int(dut.irq.value) == 1 and int(dut.state.value) == S_IDLE
    await env.send(cmd(OP_READ, 2), 0x00)
    await env.wait_state(S_RESPOND, limit=10)
    assert env.starts == []  # served from the buffer, no device transaction
    await env.pulse("h_frame_start", h_frame_rd=1)
    assert await env.take(2) == [0x41, 0x42]
    await env.pulse("h_frame_end")
    assert int(dut.irq.value) == 1  # one byte still waiting
    await env.send(cmd(OP_WRITE, 1), 0x00)  # a write discards unread RX bytes
    assert int(dut.irq.value) == 0


@cocotb.test()
async def test_fifo_overflow_sets_flag(dut):
    env = await Env(dut).setup(host_uart=0, dev_uart=1)
    for b in range(5):
        dut.d_rd_data.value = b
        await env.pulse("d_rd_push")
    assert int(dut.err.value) == 1
    await env.send(cmd(OP_STATUS, 1), 0x00)
    await env.wait_state(S_RESPOND, limit=10)
    await env.pulse("h_frame_start", h_frame_rd=1)
    assert await env.take(1) == [0x20 | 4]  # OVF + 4 bytes buffered


@cocotb.test()
async def test_uart_frame_error_flag(dut):
    env = await Env(dut).setup()
    await env.pulse("frame_err")
    assert int(dut.err.value) == 1
    assert await env.transact(cmd(OP_STATUS, 1), 0x00, n_resp=1) == [0x40]


# ------------------------------------------------------------------ timeouts

async def idle_for(dut, cycles):
    await ClockCycles(dut.clk, cycles, rising=False)


@cocotb.test()
async def test_host_silence_mid_header_times_out(dut):
    env = await Env(dut).setup(host_limit=100)
    await env.send(cmd(OP_WRITE, 1))  # first header byte, then silence
    assert int(dut.state.value) == S_HEADER
    await idle_for(dut, 120)
    assert int(dut.state.value) == S_IDLE and int(dut.err.value) == 1
    # the parser starts clean; status reports the timeout until the next command
    assert await env.transact(cmd(OP_STATUS, 1), 0x00, n_resp=1) == [TIMEOUT]
    assert await env.transact(cmd(OP_WRITE, 1), 0x48, 0x00, n_resp=1) == [0x00]
    assert int(dut.err.value) == 0


@cocotb.test()
async def test_host_silence_mid_payload_times_out(dut):
    env = await Env(dut).setup(host_limit=100)
    await env.send(cmd(OP_WRITE, 2), 0x48, 0x01)  # one of two payload bytes
    assert int(dut.state.value) == S_WRITE
    await idle_for(dut, 120)
    assert int(dut.state.value) == S_IDLE and int(dut.err.value) == 1
    assert env.starts == []


@cocotb.test()
async def test_slow_host_within_limit(dut):
    env = await Env(dut).setup(host_limit=100)
    for b in (cmd(OP_WRITE, 2), 0x48, 0x01):
        await env.send(b)
        await idle_for(dut, 80)  # long gaps, but shorter than the limit
    await env.send(0x02)
    await env.wait_state(S_RESPOND)
    assert await env.take(1) == [0x00]
    assert env.writes == [0x01, 0x02] and int(dut.err.value) == 0


@cocotb.test()
async def test_device_timeout_aborts_and_reports(dut):
    env = await Env(dut).setup(dev_limit=200)
    env.hang = True
    await env.send(cmd(OP_WRITE, 1), 0x48, 0x00)
    await env.wait_state(S_RESPOND, limit=400)
    assert await env.take(1) == [TIMEOUT]
    assert env.aborts == 1 and int(dut.err.value) == 1


@cocotb.test()
async def test_read_timeout_still_returns_len_bytes(dut):
    env = await Env(dut).setup(dev_limit=200)
    env.hang = True
    env.reads = [0x11]
    env.n_reads = 1  # the device returns 1 of 2 bytes, then stalls
    await env.send(cmd(OP_READ, 2), 0x48)
    await env.wait_state(S_RESPOND, limit=400)
    assert await env.take(2) == [0x11, 0x00]
    assert env.aborts == 1 and int(dut.err.value) == 1


@cocotb.test()
async def test_uart_reply_window_ends_normally(dut):
    env = await Env(dut).setup(host_uart=0, dev_uart=1, dev_limit=150)
    env.hang = True
    env.reads = [0x61, 0x62]
    env.n_reads = 2  # the UART peer answers 2 of 3 bytes
    await env.send(cmd(OP_WRRD, 3), 0x00, 0x41)
    await env.wait_state(S_RESPOND, limit=400)
    await env.pulse("h_frame_start", h_frame_rd=1)
    assert await env.take(3) == [0x61, 0x62, 0x00]
    await env.pulse("h_frame_end")
    assert env.writes == [0x41] and env.aborts == 1
    assert int(dut.err.value) == 0  # a closed reply window is not an error


@cocotb.test()
async def test_stalled_readout_times_out(dut):
    env = await Env(dut).setup(host_uart=0, host_limit=100)
    env.reads = [0x01, 0x02]
    await env.send(cmd(OP_READ, 2), 0x48)
    await env.wait_state(S_RESPOND)
    await env.pulse("h_frame_start", h_frame_rd=1)
    assert await env.take(1) == [0x01]  # host stops after one byte, frame left open
    await idle_for(dut, 120)
    assert int(dut.state.value) == S_IDLE and int(dut.err.value) == 1


@cocotb.test()
async def test_pending_response_waits_for_framed_host(dut):
    env = await Env(dut).setup(host_uart=0, host_limit=100)
    await env.send(cmd(OP_READ, 1), 0x48)
    await env.wait_state(S_RESPOND)
    await idle_for(dut, 300)  # SPI / I2C hosts may poll IRQ as long as they like
    assert int(dut.state.value) == S_RESPOND and int(dut.err.value) == 0


@cocotb.test()
async def test_zero_limit_disables_timeouts(dut):
    env = await Env(dut).setup(host_limit=0)
    await env.send(cmd(OP_WRITE, 1))
    await idle_for(dut, 500)
    assert int(dut.state.value) == S_HEADER and int(dut.err.value) == 0
