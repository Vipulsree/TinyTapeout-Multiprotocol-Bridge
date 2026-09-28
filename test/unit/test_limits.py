# SPDX-License-Identifier: Apache-2.0
"""Checks the timeout limits project.v picks for every MODE x BAUD_SEL pair
against the table in docs/architecture.md (all powers of two). Reads internal
wires, so it runs at RTL only (it is a unit suite, not part of the TT gate-level test)."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

HOST_UART = {0b00: 1 << 19, 0b01: 1 << 18, 0b10: 1 << 16, 0b11: 1 << 15}  # 20 / 20 / 15 / 15 chars
DEV_UART = {0b00: 1 << 18, 0b01: 1 << 17, 0b10: 1 << 15, 0b11: 1 << 14}   # 10 / 10 / 7.5 / 7.5 chars
TO_BUS = 1 << 20      # 41.9 ms
TO_SPI_DEV = 1 << 16  # 2.6 ms

HOST_UART_MODES = {0b000, 0b001, 0b110}
DEV_UART_MODES = {0b010, 0b100}
DEV_SPI_MODES = {0b000, 0b101}


def expected(mode, baud):
    host = HOST_UART[baud] if mode in HOST_UART_MODES else TO_BUS
    if mode in DEV_UART_MODES:
        dev = DEV_UART[baud]
    elif mode in DEV_SPI_MODES:
        dev = TO_SPI_DEV
    else:
        dev = TO_BUS
    return host, dev


@cocotb.test()
async def test_limits_per_mode_and_baud(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.ena.value = 1
    dut.uio_in.value = 0x01
    dut.ui_in.value = 0x08
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    for mode in range(8):
        for baud in range(4):
            dut.ui_in.value = 0x08 | (baud << 4) | mode
            await ClockCycles(dut.clk, 2)
            await FallingEdge(dut.clk)
            host, dev = expected(mode, baud)
            got = (int(dut.to_host_limit.value), int(dut.to_dev_limit.value))
            assert got == (host, dev), f"mode {mode:03b} baud {baud:02b}: got {got}, want {(host, dev)}"
            assert all(v & (v - 1) == 0 for v in got) and max(got) <= (1 << 20)
            dut._log.info(f"mode {mode:03b} baud {baud:02b}: host {host:>7} dev {dev:>7} clocks")
