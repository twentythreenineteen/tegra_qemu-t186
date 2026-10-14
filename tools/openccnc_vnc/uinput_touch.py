"""
Pure-stdlib virtual multitouch touchscreen via /dev/uinput.

Creates a Linux input device that reports EV_ABS multitouch protocol B
(ABS_MT_SLOT / ABS_MT_TRACKING_ID / ABS_MT_POSITION_X / ABS_MT_POSITION_Y)
plus INPUT_PROP_DIRECT, matching the shape of a real touchscreen so
libinput/Weston classify and route it the same way (ID_INPUT_TOUCHSCREEN).

Coordinate space is whatever you pass to open_touch_device() - we declare
our own axis range rather than mirroring the real digitizer's calibration,
since libinput maps a touch device's declared ABS_MT_POSITION_X/Y range
linearly onto screen coordinates. Passing (1920, 720) here means tap(x, y)
takes coordinates directly in full captured-frame pixel space.
"""
import struct
import fcntl
import os
import time

# ---- ioctl numbers, derived from the standard Linux _IOC macro (see
# analysis notes - cross-checked against UI_DEV_CREATE/UI_DEV_DESTROY's
# known-good values 0x5501/0x5502) ----
_IOC_WRITE = 1
_IOC_NONE = 0

def _IOC(direction, type_, nr, size):
    return (direction << 30) | (type_ << 8) | nr | (size << 16)

def _IO(type_, nr):
    return _IOC(_IOC_NONE, type_, nr, 0)

def _IOW(type_, nr, size):
    return _IOC(_IOC_WRITE, type_, nr, size)

_U = ord('U')
UI_SET_EVBIT   = _IOW(_U, 100, 4)
UI_SET_KEYBIT  = _IOW(_U, 101, 4)
UI_SET_ABSBIT  = _IOW(_U, 103, 4)
UI_SET_PROPBIT = _IOW(_U, 110, 4)
UI_DEV_CREATE  = _IO(_U, 1)
UI_DEV_DESTROY = _IO(_U, 2)
UI_DEV_SETUP   = _IOW(_U, 3, 92)  # sizeof(struct uinput_setup)
UI_ABS_SETUP   = _IOW(_U, 4, 28)  # sizeof(struct uinput_abs_setup)

# ---- event/prop/code constants (from linux/input-event-codes.h) ----
EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT = 0
BTN_TOUCH = 0x14a
ABS_MT_SLOT = 0x2f
ABS_MT_TRACKING_ID = 0x39
ABS_MT_POSITION_X = 0x35
ABS_MT_POSITION_Y = 0x36
INPUT_PROP_DIRECT = 0x01

class VirtualTouchscreen:
    def __init__(self, width, height, name=b"claude-virtual-touch"):
        self.width = width
        self.height = height
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        self._next_tracking_id = 1

        # Declare capabilities before UI_DEV_SETUP (order matters per uinput API)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_SYN)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_ABS)
        fcntl.ioctl(self.fd, UI_SET_KEYBIT, BTN_TOUCH)
        fcntl.ioctl(self.fd, UI_SET_ABSBIT, ABS_MT_SLOT)
        fcntl.ioctl(self.fd, UI_SET_ABSBIT, ABS_MT_TRACKING_ID)
        fcntl.ioctl(self.fd, UI_SET_ABSBIT, ABS_MT_POSITION_X)
        fcntl.ioctl(self.fd, UI_SET_ABSBIT, ABS_MT_POSITION_Y)
        fcntl.ioctl(self.fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT)

        # struct uinput_setup { struct input_id id; char name[80]; u32 ff_effects_max; }
        # struct input_id { u16 bustype; u16 vendor; u16 product; u16 version; }
        bustype, vendor, product, version = 0x06, 0x0001, 0x0001, 0x0001  # BUS_VIRTUAL
        name_padded = name[:79].ljust(80, b"\x00")
        setup = struct.pack("<HHHH80sI", bustype, vendor, product, version, name_padded, 0)
        fcntl.ioctl(self.fd, UI_DEV_SETUP, setup)

        # struct uinput_abs_setup { u16 code; u16 _pad; struct input_absinfo {
        #   s32 value, minimum, maximum, fuzz, flat, resolution; } }
        def abs_setup(code, minimum, maximum):
            return struct.pack("<HH iiiiii", code, 0, 0, minimum, maximum, 0, 0, 0)

        fcntl.ioctl(self.fd, UI_ABS_SETUP, abs_setup(ABS_MT_SLOT, 0, 9))
        fcntl.ioctl(self.fd, UI_ABS_SETUP, abs_setup(ABS_MT_TRACKING_ID, 0, 65535))
        fcntl.ioctl(self.fd, UI_ABS_SETUP, abs_setup(ABS_MT_POSITION_X, 0, width - 1))
        fcntl.ioctl(self.fd, UI_ABS_SETUP, abs_setup(ABS_MT_POSITION_Y, 0, height - 1))

        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        # kernel/udev needs a moment to register the new device node
        time.sleep(0.2)

    def _emit(self, ev_type, code, value):
        # struct input_event { struct timeval time (2x long=16B on 64-bit);
        #                       u16 type; u16 code; s32 value; }
        event = struct.pack("<qqHHi", 0, 0, ev_type, code, value)
        os.write(self.fd, event)

    def _syn(self):
        self._emit(EV_SYN, SYN_REPORT, 0)

    def tap(self, x, y, hold_seconds = 0.1):
        """Single-finger tap at (x, y) in the coordinate space this device
        was created with."""
        self.swipe([(x, y)], duration = hold_seconds)

    def swipe(self, points, duration = 0.3):
        """Single-finger drag through a sequence of (x, y) points, all in
        the coordinate space this device was created with. A single point
        behaves like a tap (down then immediately up at the same spot).
        `duration` is spread evenly across the moves between points."""
        if not points:
            raise ValueError("swipe() needs at least one point")

        def clamp(x, y):
            return (
                max(0, min(self.width - 1, int(x))),
                max(0, min(self.height - 1, int(y))),
            )

        tracking_id = self._next_tracking_id
        self._next_tracking_id += 1

        x0, y0 = clamp(*points[0])
        self._emit(EV_ABS, ABS_MT_SLOT, 0)
        self._emit(EV_ABS, ABS_MT_TRACKING_ID, tracking_id)
        self._emit(EV_ABS, ABS_MT_POSITION_X, x0)
        self._emit(EV_ABS, ABS_MT_POSITION_Y, y0)
        self._emit(EV_KEY, BTN_TOUCH, 1)
        self._syn()

        remaining = points[1:]
        if remaining:
            step_delay = duration / len(remaining)
            for px, py in remaining:
                time.sleep(step_delay)
                x, y = clamp(px, py)
                self._emit(EV_ABS, ABS_MT_SLOT, 0)
                self._emit(EV_ABS, ABS_MT_POSITION_X, x)
                self._emit(EV_ABS, ABS_MT_POSITION_Y, y)
                self._syn()
        else:
            time.sleep(duration)

        self._emit(EV_ABS, ABS_MT_SLOT, 0)
        self._emit(EV_ABS, ABS_MT_TRACKING_ID, -1)
        self._emit(EV_KEY, BTN_TOUCH, 0)
        self._syn()

    def close(self):
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        finally:
            os.close(self.fd)

if __name__ == "__main__":
    import sys
    x, y = int(sys.argv[1]), int(sys.argv[2])
    ts = VirtualTouchscreen(1920, 720)
    print(f"[+] virtual touchscreen created, tapping ({x},{y})...")
    ts.tap(x, y)
    print("[+] tap sent")
    time.sleep(0.5)
    ts.close()