# SPDX-License-Identifier: Apache-2.0
"""Bit-level 8N1 UART peer for cocotb tests (LSB first).

`tx` is the line this model drives (the bridge's UART_RX), `rx` the line it
watches (the bridge's UART_TX). Every byte seen on `rx` lands in `received`;
`reply` (optional) maps a received byte to bytes sent back, like a UART device
answering a command.
"""
import cocotb
from cocotb.triggers import FallingEdge, Timer


class UartPeer:
    def __init__(self, tx, rx, baud=115200):
        self.tx = tx
        self.rx = rx
        self.bit_ps = round(1e12 / baud)
        self.received = []
        self.frame_errors = 0
        self.reply = None  # callable(byte) -> list of bytes, or None
        tx.value = 1
        self._task = cocotb.start_soon(self._monitor())

    def stop(self):
        self._task.cancel()

    async def _bit(self, n=1.0):
        await Timer(round(self.bit_ps * n), unit="ps")

    async def send(self, data, bad_stop=False, gap_bits=0):
        """Send bytes back to back (gap_bits idle bits between them)."""
        for b in data:
            self.tx.value = 0
            await self._bit()
            for i in range(8):
                self.tx.value = (b >> i) & 1
                await self._bit()
            self.tx.value = 0 if bad_stop else 1
            await self._bit()
            self.tx.value = 1
            if gap_bits:
                await self._bit(gap_bits)

    async def _monitor(self):
        while True:
            await FallingEdge(self.rx)
            await self._bit(0.5)
            if int(self.rx.value) != 0:
                continue  # glitch
            v = 0
            for i in range(8):
                await self._bit()
                v |= int(self.rx.value) << i
            await self._bit()
            if int(self.rx.value) != 1:
                self.frame_errors += 1
                continue
            self.received.append(v)
            if self.reply is not None:
                out = self.reply(v)
                if out:
                    cocotb.start_soon(self.send(out))

    async def recv(self, n, timeout_bits=40):
        """Wait for n bytes (at most timeout_bits idle bit times between bytes)."""
        waited = 0
        seen = len(self.received)
        while len(self.received) < n:
            await self._bit()
            if len(self.received) != seen:
                seen, waited = len(self.received), 0
            waited += 1
            if waited > timeout_bits:
                raise AssertionError(f"UART: got {self.received}, wanted {n} bytes")
        out, self.received = self.received[:n], self.received[n:]
        return out
