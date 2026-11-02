# Dell Pro 13 Plus (PB13250) — webcam fix for Ubuntu 24.04

The built-in webcam is dead on a clean Ubuntu 24.04 install: no image in any app,
and `/dev/video0` produces nothing. This repo explains why and fixes it.

Verified working in **Zoom** and **Google Meet** after the fix.

![status](https://img.shields.io/badge/status-working-success) ![license](https://img.shields.io/badge/license-GPL--2.0-blue)

---

## Affected hardware

| | |
|---|---|
| Laptop | Dell Pro 13 Plus **PB13250** (BIOS 2.7.4) |
| CPU | Intel Core Ultra 7 **255U** (Arrow Lake-U) |
| Camera block | Intel **IPU6** `8086:7d19` (`ipu6epmtl` firmware) |
| Sensor | OmniVision **OV05C10** (ACPI `OVTI05C1`), i2c bus 16 @ `0x10` |
| Aggregator | Intel **CVS** — Computer Vision Sensing (ACPI `INTC10E0`) |
| I²C/GPIO bridge | Intel **USBIO** (`06cb:0701`, USB) |
| OS tested | Ubuntu 24.04.5, kernel `7.0.0-38-generic` |

The IR camera (`HIMX1092`, Windows Hello) works out of the box — only the RGB
webcam is affected. Other Arrow Lake laptops that put an OV05C10 behind an Intel
CVS chip are likely affected the same way.

---

## TL;DR

Two independent kernel-side bugs, stacked:

1. **No driver claims the Intel CVS chip** (`INTC10E0`), so the kernel never
   enumerates the sensor at all.
2. Once enumerated, Ubuntu's `ov05c10` driver **defaults to a sensor mode this
   hardware cannot stream**, producing corrupt MIPI CSI-2 packets.

Fix both and the existing Ubuntu userspace stack (Intel camhal → `icamerasrc` →
`v4l2-relayd` → `v4l2loopback`) just works — it was never the problem.

```bash
git clone https://github.com/yudhistirau/dell-pro-13-plus-webcam-ubuntu.git
cd dell-pro-13-plus-webcam-ubuntu
./install.sh
sudo reboot
```

---

## Problem 1 — the sensor is never enumerated

On this platform the firmware puts the camera sensor behind an **Intel CVS**
chip, an always-on vision co-processor that owns the sensor until the host asks
for it. The DSDT encodes that as an ACPI dependency:

```
Device (LNK1)                       // the RGB camera
    _HID -> OVTI05C1
    _DEP -> { \_SB.PC00.CVSS,  \_SB.PC00.XHCI.RHUB.HS04.VIC1 }
                    ^ INTC10E0 = the CVS chip
```

Linux honours `_DEP`: a device whose supplier has no bound driver is held back
from enumeration. Nothing in Ubuntu 24.04 claims `INTC10E0`:

```console
$ grep -i INTC10E0 /lib/modules/$(uname -r)/modules.alias
   (no output)
```

So the chain never starts:

```
no driver for INTC10E0 (Intel CVS)
 └─ ACPI _DEP of OVTI05C1 never satisfied
     └─ no i2c client created on i2c-16 (VIC1)
         └─ ov05c10 never probes, no v4l-subdev
             └─ IPU6 has no sensor
                 └─ camhal fails: "readlink sysName /sys/dev/char/0:0 failed"
                     └─ icamerasrc registers with rank none
                         └─ /dev/video0 exists but is never fed
```

The contrast with the working IR camera makes it obvious — same machine, same
boot:

| ACPI device | Path | `_DEP` satisfied? | i2c client |
|---|---|---|---|
| `HIMX1092` (IR) | `\_SB.PC00.LNK0` | yes (`DSC0` bound) | ✅ on `i2c-15` |
| `OVTI05C1` (RGB) | `\_SB.PC00.LNK1` | **no** (`CVSS` unbound) | ❌ absent |

### Fix

Build Intel's official out-of-tree [`intel_cvs`](https://github.com/intel/vision-drivers)
driver. It acquires the sensor over a GPIO handshake and then clears the ACPI
dependency:

```c
/* drivers/misc/icvs/intel_cvs.c */
ret = cvs_acquire_camera_sensor_internal();   /* drive req low, wait for resp */
...
acpi_dev_clear_dependencies(ACPI_COMPANION(icvs->dev));
```

Its match table already includes `INTC10E0 /* ARL */`. After loading:

```console
$ dmesg | grep -i cvs
Intel CVS driver i2c-INTC10E0:00: cvs_common_probe: probed as i2c device
Intel CVS driver i2c-INTC10E0:00: cvs_find_magic_num_support:Device protocol is 1.0
Intel CVS driver i2c-INTC10E0:00: cvs_common_probe:Transfer of ownership success

$ ls -d /sys/bus/i2c/devices/*OVTI05C1*
/sys/bus/i2c/devices/i2c-OVTI05C1:00          # finally exists
```

---

## Problem 2 — corrupt CSI-2 packets

With the sensor enumerated, the media graph links up correctly, but no usable
frame arrives. The kernel reports MIPI link errors and camhal starves:

```
intel_ipu6_isys: csi2-0 error: Incomplete long packet detected
intel_ipu6_isys: csi2-0 error: Frame sync error
intel_ipu6_isys: csi2-0 error: Payload checksum (CRC) error
CamHAL[ERR] Poll: Device node fd 25 poll timeout.
CamHAL[INF] Sof poll time out.
```

Ubuntu's `ov05c10` exposes **two** sensor modes and defaults to the first one:

```console
$ v4l2-ctl -d /dev/v4l-subdev6 --list-ctrls-menus | grep -A2 link_frequency
link_frequency (intmenu): min=0 max=1 default=0 ...
        0: 900000000        <- 2888x1808 mode, the default
        1: 480000000        <- 2800x1576 mode
```

The `2888x1808 @ 900 MHz` mode does not stream on this hardware. The fix is to
expose only the `2800x1576 @ 480 MHz` mode and make the `LINK_FREQ` control
default follow the active mode — the patch in [`patches/`](patches/), authored by
[NightScript370/ov05c10-ipu6-cvs](https://github.com/NightScript370/ov05c10-ipu6-cvs).

After the fix: `default=1`, and **zero** CSI-2 errors.

### Ruled out along the way

Two plausible theories that turned out to be wrong — recorded so nobody re-walks them:

- **camhal asking for the wrong resolution.** It isn't. `/etc/camera/ipu6epmtl/sensors/ov05c10-uf.xml`
  declares `supportedISysSizes 2800x1576`, matching the driver exactly.
- **CSI-2 lane-count mismatch.** It isn't. The firmware's `SSDB` asks for 2 lanes
  and the driver drives 2 lanes. Measured with [`tools/ssdb_dump`](tools/ssdb_dump/):

  ```
  ssdb_dump: OVTI05C1: link=0 LANES=2 MCLKSPEED=19200000 Hz
  ssdb_dump: HIMX1092: link=4 LANES=1 MCLKSPEED=19200000 Hz
  ```

---

## Install

Requires internet (clones two upstream repos) and ~5 minutes.

```bash
./install.sh
sudo reboot
```

The script installs both modules through **DKMS**, so they are rebuilt
automatically on every kernel update. It touches nothing that Ubuntu ships: the
stock `ov05c10` is left in place and simply overridden by the DKMS build.

With **Secure Boot enabled**, DKMS will ask you to enrol a MOK key and you must
confirm it during the next boot. Secure Boot was *disabled* on the test machine,
so that path is untested here.

### Uninstall

```bash
./uninstall.sh
sudo reboot
```

---

## Verify

```bash
# 1. CVS driver loaded itself and took the sensor
dmesg | grep -i "Transfer of ownership"

# 2. the patched sensor driver is active -> default must be 1 (480 MHz)
v4l2-ctl -d /dev/v4l-subdev6 --list-ctrls | grep link_frequency

# 3. no MIPI errors at all
dmesg | grep -ciE "csi2.*error|stream (stop|close) time out"    # expect 0

# 4. grab a real frame
ffmpeg -f v4l2 -i /dev/video0 -vf "select=gte(n\,30)" -frames:v 1 -update 1 -y test.png
```

A working frame is a normal ~1 MB PNG. A few-KB PNG means a flat/black image —
the pipeline is running but the sensor is not delivering.

Expected media graph:

```
ov05c10 16-0010 → Intel IPU6 CSI2 0 → Intel IPU6 ISYS Capture 0   [ENABLED]
format: SGRBG10_1X10 / 2800x1576
```

---

## Known limitations

- **GNOME Camera (Snapshot) still errors.** Zoom and Meet work because they open
  `/dev/video0` (the `v4l2loopback` node) through plain V4L2; Snapshot goes via
  PipeWire/libcamera. Not investigated.
- **Kernel is tainted** (`OE`) — expected with out-of-tree modules.
- `intel_cvs` emits one `WARN` backtrace at probe on kernel 7.0. Harmless;
  probe completes and ownership transfer succeeds.
- `/dev/ipu-psys0` is `root`-only, so `icamerasrc` cannot be used directly as a
  normal user. Irrelevant for the `v4l2loopback` path, since `v4l2-relayd` runs
  as root.
- Output is capped at the sensor's single remaining mode (2800x1576), delivered
  to apps as 1280x720 by the stock `v4l2-relayd` config.

---

## How the userspace side already works

Worth stating because it is easy to blame: **Ubuntu's camera userspace needed no
changes.** It ships complete and correct for this sensor:

- `libcamhal-ipu6epmtl` with full OV05C10 tuning — `ov05c10_BBG501N3_MTL.aiqb`,
  `ov05c10-uf.xml`, `graph_settings_OV05C10_BBG501N3_MTL.xml`
- `gstreamer1.0-icamera` providing `icamerasrc`
- `v4l2-relayd` already configured in `/etc/v4l2-relayd.d/default.conf`:
  `VIDEOSRC=icamerasrc buffer-count=7`
- `v4l2loopback` exposing `/dev/video0` as *"Intel MIPI Camera"*

Note that `/etc/default/v4l2-relayd` still says `VIDEOSRC="videotestsrc"` — that
is a red herring. The per-instance file above overrides it.

---

## Credits

- [intel/vision-drivers](https://github.com/intel/vision-drivers) — the
  `intel_cvs` driver (GPL-2.0). Pinned at `845d6f8`.
- [NightScript370/ov05c10-ipu6-cvs](https://github.com/NightScript370/ov05c10-ipu6-cvs)
  — the `ov05c10` single-mode patch and the original proof that this combination
  can work on Linux. Pinned at `9f581ca`.
- [intel/ipu6-drivers](https://github.com/intel/ipu6-drivers) — the `ov05c10`
  sensor driver the patch applies to.

## License

GPL-2.0. The kernel modules are GPL-2.0 from their respective upstreams;
the scripts and `tools/ssdb_dump` in this repo are GPL-2.0 as well.
