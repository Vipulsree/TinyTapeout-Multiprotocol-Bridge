# SPDX-License-Identifier: Apache-2.0
"""SPI mode 0 models (CPOL = 0, CPHA = 0, MSB first) for cocotb tests.

SpiHost   drives CS_N / SCK / MOSI and samples MISO: the external master in
          modes 010 / 011.
SpiDevice watches CS_N / SCK / MOSI and drives MISO: the peripheral in modes
          000 / 101. It changes MISO after SCK falls and samples MOSI on SCK rise.
"""
import cocotb
from cocotb.triggers import First, FallingEdge, RisingEdge, Timer


class SpiHost:
    def __init__(self, cs_n, sck, mosi, miso, period_ns=1000):
        self.cs_n = cs_n
        self.sck = sck
        self.mosi = mosi
        self.miso = miso
        self.half = period_ns / 2
        cs_n.value = 1
        sck.value = 0
        mosi.value = 0

    async def _w(self):
        await Timer(self.half, unit="ns")

    async def transfer(self, data):
        """One CS_N-low frame: sends data on MOSI, returns the MISO bytes."""
        out = []
        self.cs_n.value = 0
        await self._w()
        for b in data:
            v = 0
            for i in range(7, -1, -1):
                self.mosi.value = (b >> i) & 1
                await self._w()
                v = (v << 1) | int(self.miso.value)  # sample at the rising edge
                self.sck.value = 1
                await self._w()
                self.sck.value = 0
            out.append(v)
        await self._w()
        self.cs_n.value = 1
        self.mosi.value = 0
        await self._w()
        return out


def flash_responder(index, mosi):
    """A small SPI flash: 0x9F returns the JEDEC ID, anything else returns 0xA0 + index."""
    if index > 0 and mosi[0] == 0x9F:
        return [0xEF, 0x40, 0x18, 0x00][min(index - 1, 3)]
    return 0xA0 + index


class SpiDevice:
    def __init__(self, cs_n, sck, mosi, miso_drv, responder=flash_responder):
        self.cs_n = cs_n
        self.sck = sck
        self.mosi = mosi
        self.miso = miso_drv
        self.responder = responder  # (byte index, MOSI bytes so far) -> MISO byte
        self.frames = []            # MOSI bytes of every completed CS frame
        miso_drv.value = 0
        self._task = cocotb.start_soon(self._run())

    def stop(self):
        self._task.cancel()

    async def _run(self):
        while True:
            await FallingEdge(self.cs_n)
            mosi, cur, n, v = [], self.responder(0, []), 0, 0
            self.miso.value = (cur >> 7) & 1
            while True:
                r, f, e = RisingEdge(self.sck), FallingEdge(self.sck), RisingEdge(self.cs_n)
                t = await First(r, f, e)
                if t is e:
                    self.frames.append(mosi)
                    break
                if t is r:
                    v = ((v << 1) | int(self.mosi.value)) & 0xFF
                    n += 1
                    if n == 8:
                        mosi.append(v)
                        n = 0
                elif n == 0:  # falling edge after a whole byte: next byte's MSB
                    cur = self.responder(len(mosi), mosi)
                    self.miso.value = (cur >> 7) & 1
                else:
                    self.miso.value = (cur >> (7 - n)) & 1
