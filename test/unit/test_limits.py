# SPDX-License-Identifier: Apache-2.0
"""Checks the timeout limits project.v picks for every MODE x BAUD_SEL pair
against the formulas in docs/architecture.md. Reads internal wires, so it runs
at RTL only (it is a unit suite, not part of the TT gate-level test)."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

UART_DIV = {0b00: 2604, 0b01: 1302, 0b10: 434, 0b11: 217}  # clocks per bit
CHAR_BITS = 10
HOST_UART_CHARS = 16
DEV_UART_CHARS = 8
TO_BUS = 875_000       # 35 ms
TO_SPI_DEV = 65_535

HOST_UART_MODES = {0b000, 0b001, 0b110}
DEV_UART_MODES = {0b010, 0b100}
DEV_SPI_MODES = {0b000, 0b101}


def expected(mode, baud):
    char = UART_DIV[baud] * CHAR_BITS
    host = char * HOST_UART_CHARS if mode in HOST_UART_MODES else TO_BUS
    if mode in DEV_UART_MODES:
        dev = char * DEV_UART_CHARS
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
            assert max(got) < (1 << 20)
            dut._log.info(f"mode {mode:03b} baud {baud:02b}: host {host:>7} dev {dev:>7} clocks")
