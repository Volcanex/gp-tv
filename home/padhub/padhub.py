#!/usr/bin/env python3
"""padhub: the Pi's gamepads, served over a WebSocket for a game running on another machine.

The DS3s are paired to the Pi (their master address is the Pi's), but the Pi 3 cannot render
the game, so the game runs on the Mac and this sends it the pads. public/js/remote-pad.js is
the other half; the Mac reaches this through an SSH tunnel (pi/README.md), because an https
page may open ws://localhost but not ws://10.42.0.1.

Standard library plus python3-websockets only (no python3-evdev: no sudo on the Pi). Reads
/dev/input/event* directly, which needs the `input` group, and never grabs a device, so the
Pi's own games still see the pads.

Every pad is sent already in the W3C `standard` mapping, whatever the driver:
  {"t": "pads", "pads": [{"slot": 0, "id": "...", "b": [17 values 0..1], "a": [LX, LY, RX, RY]}]}
b: 0 cross/south, 1 circle/east, 2 square/west, 3 triangle/north, 4 L1, 5 R1, 6 L2, 7 R2,
8 select, 9 start, 10 L3, 11 R3, 12-15 d-pad up down left right, 16 PS. Sticks -1..1, +y down.
A message goes out on every input frame that changed something, and in full to a new client.
"""
import asyncio
import fcntl
import json
import os
import struct

from websockets.asyncio.server import broadcast, serve

HOST, PORT = '127.0.0.1', int(os.environ.get('PADHUB_PORT', '8765'))
# pages allowed to connect; any localhost origin too, for testing the game locally
ORIGINS = os.environ.get('PADHUB_ORIGINS', 'https://newcastle.gabrielpenman.com').split(',')
RESCAN = 2.0  # seconds between looks for newly connected pads

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
EVENT = struct.Struct('llHHi')  # struct input_event: timeval, type, code, value
ABSINFO = struct.Struct('6i')   # struct input_absinfo: value min max fuzz flat resolution
BTN_SOUTH = 0x130

# evdev key code -> standard button index. hid-sony (kernel 4.12+) puts triangle on BTN_NORTH
# and square on BTN_WEST, as the Linux gamepad spec says.
KEYS = {
    0x130: 0, 0x131: 1, 0x134: 2, 0x133: 3, 0x136: 4, 0x137: 5, 0x138: 6, 0x139: 7,
    0x13a: 8, 0x13b: 9, 0x13d: 10, 0x13e: 11, 0x220: 12, 0x221: 13, 0x222: 14, 0x223: 15, 0x13c: 16,
}
ABS_X, ABS_Y, ABS_Z, ABS_RX, ABS_RY, ABS_RZ, HAT_X, HAT_Y = 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x10, 0x11
STICKS = {ABS_X: 0, ABS_Y: 1, ABS_RX: 2, ABS_RY: 3}
TRIGGERS = {ABS_Z: 6, ABS_RZ: 7}


def eviocgabs(code):  # _IOR('E', 0x40 + code, struct input_absinfo)
    return (2 << 30) | (ABSINFO.size << 16) | (ord('E') << 8) | (0x40 + code)


def has_bit(path, bit):
    """A bit of a /sys capabilities bitmap: hex words, most significant first, one per C long."""
    try:
        words = open(path).read().split()[::-1]
    except OSError:
        return False
    per = struct.calcsize('l') * 8
    i = bit // per
    return i < len(words) and bool(int(words[i], 16) >> (bit % per) & 1)


def is_gamepad(event):
    # a pad has the south face button; the DS3's separate "Motion Sensors" device does not
    return has_bit(f'/sys/class/input/{event}/device/capabilities/key', BTN_SOUTH)


class Pad:
    def __init__(self, event, slot):
        self.event, self.slot = event, slot
        self.fd = os.open(f'/dev/input/{event}', os.O_RDONLY | os.O_NONBLOCK)
        try:
            self.name = open(f'/sys/class/input/{event}/device/name').read().strip()
        except OSError:
            self.name = event
        self.range = {}
        for code in (*STICKS, *TRIGGERS, HAT_X, HAT_Y):
            buf = bytearray(ABSINFO.size)
            try:
                fcntl.ioctl(self.fd, eviocgabs(code), buf)
            except OSError:
                continue
            value, lo, hi = ABSINFO.unpack(buf)[:3]
            if hi > lo:
                self.range[code] = (lo, hi)
        self.keys = [0.0] * 17  # from key events
        self.trig = {}          # standard index -> 0..1, from trigger axes
        self.hat = [0.0] * 4    # d-pad from a hat, for pads that report it as axes
        self.axes = [0.0] * 4
        self.buf = b''

    def read(self):
        """Apply whatever events are waiting; True when a frame (EV_SYN) arrived."""
        try:
            self.buf += os.read(self.fd, EVENT.size * 64)
        except BlockingIOError:
            return False
        synced = False
        while len(self.buf) >= EVENT.size:
            _, _, kind, code, value = EVENT.unpack_from(self.buf)
            self.buf = self.buf[EVENT.size:]
            if kind == EV_SYN:
                synced = True
            elif kind == EV_KEY and code in KEYS:
                self.keys[KEYS[code]] = 1.0 if value else 0.0
            elif kind == EV_ABS and code in self.range:
                lo, hi = self.range[code]
                t = (value - lo) / (hi - lo)
                if code in STICKS:
                    self.axes[STICKS[code]] = round(t * 2 - 1, 3)
                elif code in TRIGGERS:
                    self.trig[TRIGGERS[code]] = round(t, 3)
                elif code == HAT_X:
                    self.hat[2], self.hat[3] = float(t < 0.25), float(t > 0.75)
                elif code == HAT_Y:
                    self.hat[0], self.hat[1] = float(t < 0.25), float(t > 0.75)
        return synced

    def state(self):
        b = list(self.keys)
        for i, v in self.trig.items():
            b[i] = max(b[i], v) if v > 0.02 else b[i]
        for i in range(4):
            b[12 + i] = max(b[12 + i], self.hat[i])
        return {'slot': self.slot, 'id': f'{self.name} (padhub)', 'b': b, 'a': list(self.axes)}

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass


class Hub:
    def __init__(self):
        self.pads = {}  # event name -> Pad
        self.clients = set()
        self.last = None

    def message(self):
        return json.dumps({'t': 'pads', 'pads': [p.state() for p in sorted(self.pads.values(), key=lambda p: p.slot)]},
                          separators=(',', ':'))

    def send(self):
        msg = self.message()
        if msg != self.last:
            self.last = msg
            broadcast(self.clients, msg)

    def on_readable(self, event):
        pad = self.pads.get(event)
        try:
            if pad and pad.read():
                self.send()
        except OSError:  # the pad went away (switched off, out of range)
            self.drop(event)

    def drop(self, event):
        pad = self.pads.pop(event, None)
        if pad:
            asyncio.get_running_loop().remove_reader(pad.fd)
            pad.close()
            print(f'padhub: lost {pad.name} (slot {pad.slot})', flush=True)
            self.send()

    def scan(self):
        present = {e for e in os.listdir('/dev/input') if e.startswith('event')}
        for event in list(self.pads):
            if event not in present:
                self.drop(event)
        for event in sorted(present - set(self.pads)):
            if not is_gamepad(event):
                continue
            used = {p.slot for p in self.pads.values()}
            slot = next(i for i in range(len(used) + 1) if i not in used)
            try:
                pad = Pad(event, slot)
            except OSError as e:
                print(f'padhub: cannot open {event}: {e}', flush=True)
                continue
            self.pads[event] = pad
            asyncio.get_running_loop().add_reader(pad.fd, self.on_readable, event)
            print(f'padhub: {pad.name} on {event} as slot {slot}', flush=True)
            self.send()

    async def handler(self, ws):
        origin = ws.request.headers.get('Origin', '')
        if origin not in ORIGINS and not origin.startswith(('http://localhost:', 'http://127.0.0.1:')):
            print(f'padhub: refused origin {origin!r}', flush=True)
            await ws.close(1008, 'origin not allowed')
            return
        self.clients.add(ws)
        print(f'padhub: client from {origin} ({len(self.clients)} open)', flush=True)
        try:
            await ws.send(self.message())
            async for _ in ws:  # nothing comes back yet (rumble would)
                pass
        finally:
            self.clients.discard(ws)

    async def run(self):
        async with serve(self.handler, HOST, PORT, compression=None):
            print(f'padhub: listening on ws://{HOST}:{PORT}', flush=True)
            while True:
                self.scan()
                await asyncio.sleep(RESCAN)


if __name__ == '__main__':
    asyncio.run(Hub().run())
