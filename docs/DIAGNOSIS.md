# Diagnosis walkthrough

How the two bugs were found, with the real commands and output. Useful if your
machine is similar but not identical — the method transfers even when the HIDs
and bus numbers do not.

All output below is from a Dell Pro 13 Plus PB13250, Ubuntu 24.04.5,
kernel 7.0.0-38-generic.

---

## 1. It is not a USB webcam

`lsusb` shows no camera at all. The camera is a MIPI sensor behind the Intel IPU6:

```console
$ lspci -nnk | grep -iA3 multimedia
00:05.0 Multimedia controller [0480]: Intel Corporation Device [8086:7d19] (rev 05)
        Subsystem: Dell Device [1028:0cf4]
        Kernel driver in use: intel-ipu6
```

So `/dev/video*` is driven by the IPU6 stack, not `uvcvideo`. Anything written
about USB webcams does not apply.

## 2. The IPU6 side is healthy — the sensor is missing

```console
$ journalctl -k -b | grep -i ipu6
intel-ipu6 0000:00:05.0: Found supported sensor OVTI05C1:00
intel-ipu6 0000:00:05.0: Connected 1 cameras
intel-ipu6 0000:00:05.0: CSE authenticate_run done
intel-ipu6 0000:00:05.0: IPU6-v4[7d19] hardware version 6
```

Firmware loads, `ipu_bridge` sees the sensor in ACPI. But the sensor driver never
binds — the i2c client does not exist:

```console
$ lsmod | grep ov05c10
ov05c10                24576  0          # refcount 0: loaded, bound to nothing

$ ls /sys/bus/i2c/devices/ | grep -i OVTI
   (nothing)
```

**This is the key observation.** The ACPI device exists and is enabled, yet no
i2c client was ever created for it:

```console
$ cat /sys/bus/acpi/devices/OVTI05C1:00/status
15                                        # present, enabled, functioning
$ ls /sys/bus/acpi/devices/OVTI05C1:00/physical_node
ls: cannot access ...: No such file or directory
```

## 3. Compare against the IR camera, which works

Same machine, same boot — the IR sensor enumerated fine. The difference points
straight at the cause:

| ACPI device | Path | `physical_node` | i2c client |
|---|---|---|---|
| `HIMX1092` (IR) | `\_SB.PC00.LNK0` | yes | `i2c-15` |
| `OVTI05C1` (RGB) | `\_SB.PC00.LNK1` | **no** | — |

Note `i2c-16` exists and is completely empty — that is where the RGB sensor
belongs.

## 4. Read the DSDT to find out why

```bash
sudo cp /sys/firmware/acpi/tables/DSDT . && sudo chown $USER DSDT
iasl -d DSDT
```

The sensor's `_HID` and `_CRS` are computed at runtime, so grepping for
`OVTI05C1` finds nothing. Look up the device by its namespace path instead:

```asl
Device (LNK1)
{
    Name (CVSB, Package (0x02) { "\\_SB.PC00.CVSS",
                                 "\\_SB.PC00.XHCI.RHUB.HS04.VIC1" })
    Name (PUSB, Package (0x02) { "\\_SB.PC00.DSC1",
                                 "\\_SB.PC00.XHCI.RHUB.HS04.VIC1" })
    Method (_DEP, 0, NotSerialized) {
        If (L1EN) { If (ARLP) { Return (CVSB) } Else { Return (PUSB) } }
    }
    Method (_HID, 0, NotSerialized) { Return (HCID (One)) }
    Method (_CRS, 0, NotSerialized) { Local0 = VIIC (L1A0, One)  ... }
}
```

`ARLP` is the "Arrow Lake platform" flag. It is true here — provable without
reading NVS, because `CVSS._STA` returns `0x0F` only `If (ARLP)` and the device
reports status 15:

```console
$ cat /sys/bus/acpi/devices/INTC10E0:00/status
15
```

So `LNK1._DEP` = `{ CVSS, VIC1 }`, where `CVSS` is:

```asl
Device (CVSS) {
    Method (_HID, 0, NotSerialized) { Return ("INTC10E0") }
    ...
}
```

Compare `LNK0` (the IR camera): its `_DEP` is `{ DSC0, VIC0 }`, and `DSC0`
(`INT3472:0c`) **is** bound. That is exactly why one camera works and the other
does not.

## 5. Confirm nothing claims INTC10E0

```console
$ grep -i INTC10E0 /lib/modules/$(uname -r)/modules.alias
   (nothing)

$ find /lib/modules/$(uname -r) -iname "*cvs*"
   (nothing)

$ modinfo mei-vsc-hw | grep alias
alias:          acpi*:INTC10D0:*
alias:          acpi*:INTC1094:*
alias:          acpi*:INTC1058:*
alias:          acpi*:INTC1009:*      # INTC10E0 is not among them
```

Root cause of bug #1 established.

## 6. After loading intel_cvs — sensor appears, frames do not

```console
$ sudo insmod intel_cvs.ko
$ dmesg | tail
Intel CVS driver i2c-INTC10E0:00: cvs_common_probe: probed as i2c device
Intel CVS driver i2c-INTC10E0:00: cvs_common_probe:Transfer of ownership success

$ ls -d /sys/bus/i2c/devices/*OVTI05C1*
/sys/bus/i2c/devices/i2c-OVTI05C1:00
$ readlink -f /sys/bus/i2c/devices/*OVTI05C1*/driver
/sys/bus/i2c/drivers/ov05c10
```

Media graph now links end to end:

```console
$ sudo media-ctl -d /dev/media0 -p | grep -i ENABLED
<- "ov05c10 16-0010":0 [ENABLED,IMMUTABLE]
-> "Intel IPU6 CSI2 0":0 [ENABLED,IMMUTABLE]
<- "Intel IPU6 CSI2 0":1 [ENABLED]
-> "Intel IPU6 ISYS Capture 0":0 [ENABLED]
```

But streaming produces corrupt packets:

```
intel_ipu6_isys: csi2-0 error: Incomplete long packet detected
intel_ipu6_isys: csi2-0 error: Frame sync error
intel_ipu6_isys: csi2-0 error: Payload checksum (CRC) error
```

## 7. Eliminating the wrong theories

### camhal requesting the wrong resolution — **no**

```console
$ grep supportedISysSizes /etc/camera/ipu6epmtl/sensors/ov05c10-uf.xml
<supportedISysSizes value="2800x1576"/>
```

Matches the driver exactly. camhal also detects the sensor correctly:

```
CamHAL[LV2] @getAvailableSensors, available sensor name: ov05c10-uf-0,
            sensorSinkNameTmp:Intel IPU6 CSI2 0
```

### Missing V4L2 subdev routing — **no**

The CSI2 entity reports `0 routes`, which looks suspicious, but this driver does
not implement the streams API at all:

```console
$ sudo media-ctl -d /dev/media0 -R '"Intel IPU6 CSI2 0"[0/0->1/0[1]]'
Unable to setup routes: Operation not supported (95)
```

### CSI-2 lane mismatch — **no**

The firmware's lane count lives in the ACPI `SSDB` buffer, which userspace cannot
evaluate. [`tools/ssdb_dump`](../tools/ssdb_dump/) is a throwaway kernel module
that evaluates it and prints the result (it returns `-EAGAIN` from `init` so it
never stays loaded):

```
ssdb_dump: OVTI05C1: SSDB panjang=108 byte
ssdb_dump: OVTI05C1: link=0 LANES=2 degree=0 ctrllogicid=255 mclkport=1
ssdb_dump: OVTI05C1: MAXLANESPEED=0 Hz  MCLKSPEED=19200000 Hz
ssdb_dump: HIMX1092: link=4 LANES=1 ...
```

Firmware asks for 2 lanes. The driver drives 2 lanes as well — confirmed from
the pixel rate, since `pixel_rate = link_freq x 2 x lanes / bpp`:

```
192 MHz = 480 MHz x 2 x 2 / 10        ✓ 2 lanes
```

Lanes match. Theory dead.

## 8. The actual cause of bug #2

```console
$ v4l2-ctl -d /dev/v4l-subdev6 --list-ctrls-menus | grep -A2 link_frequency
link_frequency (intmenu): min=0 max=1 default=0 value=1 ...
        0: 900000000
        1: 480000000
```

Two modes, and `default=0` — the `2888x1808 @ 900 MHz` mode, which this hardware
cannot stream. Ubuntu ships the unpatched Intel driver. After installing the
patched one, `default=1` and the CSI-2 errors disappear entirely.

> Tip for telling the drivers apart without rebooting into guesswork:
> ```bash
> cat /sys/module/ov05c10/srcversion          # what is loaded right now
> modinfo -n ov05c10                          # which file would be loaded next
> ```

## 9. A trap worth knowing

Once a stream has failed, `intel_ipu6_psys` leaks references and the module
chain can no longer be unloaded, so the patched sensor driver cannot be swapped
in live:

```console
$ cat /sys/module/intel_ipu6_psys/refcnt
34                                  # with no module holders at all
$ sudo modprobe -r ov05c10
modprobe: FATAL: Module ov05c10 is in use.
```

Symptoms of the wedged state:

```
intel_ipu6_isys: stream stop time out
intel_ipu6_isys: stream close time out
```

**Reboot after installing.** Trying to hot-swap wastes time and leaves a messier
state. After a clean boot the leak is gone (`refcnt=0`) and there are zero CSI-2
errors.
