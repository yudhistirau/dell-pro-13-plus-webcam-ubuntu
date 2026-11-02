// SPDX-License-Identifier: GPL-2.0
/*
 * Modul diagnostik sekali-jalan: evaluasi ACPI _SSDB milik sensor kamera
 * dan cetak isinya ke dmesg. Dipakai untuk mengetahui jumlah CSI-2 lane dan
 * link frequency yang DIMINTA FIRMWARE, lalu dibandingkan dengan yang
 * diprogram driver sensor.
 *
 * Modul sengaja mengembalikan -EAGAIN dari init agar tidak ikut termuat:
 * output-nya sudah masuk dmesg saat init berjalan.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/acpi.h>
#include <linux/unaligned.h>

/* Tata letak SSDB sesuai struct sensor_bios_data_packed / ipu-bridge */
#define SSDB_OFF_LINK		0x1C
#define SSDB_OFF_LANES		0x1D
#define SSDB_OFF_MAXLANESPEED	0x46
#define SSDB_OFF_DEGREE		0x54
#define SSDB_OFF_MCLKSPEED	0x56
#define SSDB_OFF_CTRLLOGICID	0x5A
#define SSDB_OFF_MCLKPORT	0x5F

static void dump_one(const char *hid)
{
	struct acpi_buffer buf = { ACPI_ALLOCATE_BUFFER, NULL };
	struct acpi_device *adev;
	union acpi_object *obj;
	acpi_status st;
	u8 *p;
	u32 len;

	adev = acpi_dev_get_first_match_dev(hid, NULL, -1);
	if (!adev) {
		pr_info("ssdb_dump: %s: perangkat ACPI tidak ditemukan\n", hid);
		return;
	}

	st = acpi_evaluate_object(adev->handle, "SSDB", NULL, &buf);
	if (ACPI_FAILURE(st)) {
		pr_info("ssdb_dump: %s: evaluasi SSDB gagal (%s)\n",
			hid, acpi_format_exception(st));
		goto out;
	}

	obj = buf.pointer;
	if (!obj || obj->type != ACPI_TYPE_BUFFER) {
		pr_info("ssdb_dump: %s: SSDB bukan buffer\n", hid);
		goto free;
	}

	p = obj->buffer.pointer;
	len = obj->buffer.length;
	pr_info("ssdb_dump: %s: SSDB panjang=%u byte\n", hid, len);
	print_hex_dump(KERN_INFO, "ssdb_dump: raw ", DUMP_PREFIX_OFFSET,
		       16, 1, p, len, false);

	if (len > SSDB_OFF_MCLKPORT) {
		pr_info("ssdb_dump: %s: link=%u LANES=%u degree=%u ctrllogicid=%u mclkport=%u\n",
			hid, p[SSDB_OFF_LINK], p[SSDB_OFF_LANES],
			p[SSDB_OFF_DEGREE], p[SSDB_OFF_CTRLLOGICID],
			p[SSDB_OFF_MCLKPORT]);
		pr_info("ssdb_dump: %s: MAXLANESPEED=%u Hz  MCLKSPEED=%u Hz\n",
			hid, get_unaligned_le32(p + SSDB_OFF_MAXLANESPEED),
			get_unaligned_le32(p + SSDB_OFF_MCLKSPEED));
	}

free:
	kfree(buf.pointer);
out:
	acpi_dev_put(adev);
}

static int __init ssdb_dump_init(void)
{
	pr_info("ssdb_dump: mulai\n");
	dump_one("OVTI05C1");	/* webcam RGB di LNK1 */
	dump_one("HIMX1092");	/* kamera IR di LNK0, sebagai pembanding */
	pr_info("ssdb_dump: selesai (modul sengaja tidak termuat)\n");
	return -EAGAIN;
}

module_init(ssdb_dump_init);
MODULE_DESCRIPTION("Dump ACPI SSDB kamera untuk diagnosa CSI-2");
MODULE_LICENSE("GPL");
