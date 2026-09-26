# SPDX-FileCopyrightText: © 2026 VLSI PD Tapeout team
# SPDX-License-Identifier: Apache-2.0
"""Top-level tests for tt_um_mpbridge. The TT CI runs these through test/Makefile,
at RTL and on the gate-level netlist, so they only use pins and tb wires.

Week-2 scope: reset state, per-mode pin directions, SPI slave MISO enable and the
open-drain rule on the I2C pins. Transaction tests arrive with the engines."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

CLK_NS = 40  # 25 MHz
UART_RX_IDLE = 1 << 3  # ui_in[3]
CS_N = 1 << 0  # uio[0]

# uio_oe per mode with the SPI slave not selected and the I2C bus idle:
# SPI master modes drive CS_N, MOSI and SCK (bits 0, 1, 3); everything else is an input.
OE_IDLE = {0b000: 0x0B, 0b001: 0x00, 0b010: 0x00, 0b011: 0x00,
           0b100: 0x00, 0b101: 0x0B, 0b110: 0x00, 0b111: 0x00}


async def reset(dut, mode=0b000):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = UART_RX_IDLE | mode
    dut.uio_in_drv.value = CS_N
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


async def set_mode(dut, mode):
    dut.ui_in.value = UART_RX_IDLE | mode
    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)


def check_i2c_released(dut):
    assert int(dut.i2c_push_pull_violation.value) == 0
    assert int(dut.i2c_scl.value) == 1 and int(dut.i2c_sda.value) == 1


@cocotb.test()
async def test_reset_state(dut):
    await reset(dut, 0b000)
    # DBG_STATE = IDLE, UART_TX idles high, IRQ / BUSY / ERR low
    assert int(dut.uo_out.value) == 0x10
    assert int(dut.uio_oe.value) == OE_IDLE[0b000]
    assert int(dut.uio_out.value) & CS_N  # SPI master keeps CS_N high
    check_i2c_released(dut)


@cocotb.test()
async def test_pin_directions_per_mode(dut):
    await reset(dut, 0b000)
    for mode in range(8):
        await set_mode(dut, mode)
        assert int(dut.uio_oe.value) == OE_IDLE[mode], f"mode {mode:03b}: uio_oe={int(dut.uio_oe.value):#04x}"
        expect_uo = 0x00 if mode == 0b111 else 0x10
        assert int(dut.uo_out.value) == expect_uo, f"mode {mode:03b}: uo_out={int(dut.uo_out.value):#04x}"
        assert int(dut.uio_oe.value) & 0x30 == 0  # spare pins never driven
        check_i2c_released(dut)


@cocotb.test()
async def test_spi_slave_drives_miso_only_when_selected(dut):
    await reset(dut, 0b010)
    assert int(dut.uio_oe.value) & 0x04 == 0
    dut.uio_in_drv.value = 0  # host pulls CS_N low
    await ClockCycles(dut.clk, 4)
    await FallingEdge(dut.clk)
    assert int(dut.uio_oe.value) & 0x0F == 0x04  # only MISO is an output
    dut.uio_in_drv.value = CS_N
    await ClockCycles(dut.clk, 4)
    await FallingEdge(dut.clk)
    assert int(dut.uio_oe.value) & 0x04 == 0


@cocotb.test()
async def test_external_i2c_activity_is_harmless(dut):
    await reset(dut, 0b001)
    # Another device wiggles the bus: the bridge must stay released.
    for scl, sda in ((1, 0), (0, 0), (0, 1), (1, 1), (0, 0)):
        dut.i2c_scl_pull.value = 1 - scl
        dut.i2c_sda_pull.value = 1 - sda
        await ClockCycles(dut.clk, 5)
        assert int(dut.uio_oe.value) & 0xC0 == 0
        assert int(dut.i2c_push_pull_violation.value) == 0
