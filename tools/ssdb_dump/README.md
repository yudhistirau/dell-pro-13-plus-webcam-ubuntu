# ssdb_dump

Throwaway diagnostic module. Evaluates the ACPI `SSDB` buffer of the camera
sensors and prints it to the kernel log — this is how the firmware states the
CSI-2 **lane count**, link index and MCLK, which userspace cannot read.

It deliberately returns `-EAGAIN` from `module_init`, so `insmod` "fails" and the
module never stays resident. The output is already in `dmesg` by then.

```bash
make
sudo insmod ./ssdb_dump.ko      # reports "Resource temporarily unavailable" — expected
sudo dmesg | grep ssdb_dump
```

Example output:

```
ssdb_dump: OVTI05C1: link=0 LANES=2 degree=0 ctrllogicid=255 mclkport=1
ssdb_dump: OVTI05C1: MAXLANESPEED=0 Hz  MCLKSPEED=19200000 Hz
ssdb_dump: HIMX1092: link=4 LANES=1 degree=0 ctrllogicid=0 mclkport=0
```

Edit the HIDs in `ssdb_dump_init()` for other machines.
