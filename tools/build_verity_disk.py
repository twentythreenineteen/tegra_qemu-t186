#!/usr/bin/env python3
"""
build_verity_disk.py — Assemble a sparse GPT disk image for dm-verity boot.

Combines an ext4 rootfs data image and a dm-verity hash tree image
into a single GPT-partitioned disk image that the QEMU tegra186 vblk backend
can serve as /dev/vblkdev0.

Layout (512-byte sectors / LBAs):
  LBA 0:        Protective MBR
  LBA 1:        GPT Header
  LBA 2-33:     GPT Partition Entries (128 entries x 128 bytes)
  LBA 34-2047:  Padding (alignment to 1 MiB)
  LBA 2048+:    Partition 1 — data (ext4 rootfs)
  ...           Partition 2 — hash (dm-verity tree)
  ...           Backup GPT entries + header at end of disk

Usage:
  python3 build_verity_disk.py <data.img> <hash.img> <output.img>

Example:
  python3 build_verity_disk.py \
    /path/to/data_ext4.img \
    /path/to/verity_hash.img \
    /path/to/verity_disk.img
"""

import os
import struct
import sys
import uuid

SECTOR_SIZE = 512
DATA_START_LBA = 2048          # 1 MiB alignment
GPT_ENTRIES = 128
GPT_ENTRY_SIZE = 128
GPT_ENTRY_SECTORS = (GPT_ENTRIES * GPT_ENTRY_SIZE) // SECTOR_SIZE  # 32

# Linux filesystem partition type GUID
LINUX_FS_GUID = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")


def guid_bytes(u):
    """Convert uuid.UUID to GPT mixed-endian byte representation."""
    # GPT GUIDs are stored in mixed-endian: first 3 fields LE, last 2 fields BE
    d1, d2, d3 = struct.unpack("<IHH", u.bytes_le[0:8])
    d4 = u.bytes[8:16]
    return struct.pack("<IHH", d1, d2, d3) + d4


def crc32(data):
    """CRC32 (IEEE 802.3, as used by GPT)."""
    import zlib
    return zlib.crc32(data) & 0xFFFFFFFF


def build_protective_mbr(total_sectors):
    """Build a protective MBR with a single type-0xEE partition."""
    mbr = bytearray(SECTOR_SIZE)
    # Boot signature
    mbr[510] = 0x55
    mbr[511] = 0xAA
    # Partition entry 0: type 0xEE (GPT protective)
    # CHS start (ignored by modern systems)
    mbr[446 + 0] = 0x00  # boot flag
    mbr[446 + 1] = 0x00  # CHS start
    mbr[446 + 2] = 0x00
    mbr[446 + 3] = 0x00
    mbr[446 + 4] = 0xEE  # partition type: GPT protective
    mbr[446 + 5] = 0xFF  # CHS end
    mbr[446 + 6] = 0xFF
    mbr[446 + 7] = 0xFF
    # LBA start = 1
    struct.pack_into("<I", mbr, 446 + 8, 1)
    # Number of sectors = total disk sectors - 1 (or max)
    struct.pack_into("<I", mbr, 446 + 12, min(total_sectors - 1, 0xFFFFFFFF))
    return bytes(mbr)


def build_gpt_header(total_sectors, part_entry_lba, num_entries, entry_size, entries_crc, disk_guid):
    """Build a GPT header (LBA 1)."""
    hdr = bytearray(SECTOR_SIZE)
    # Signature "EFI PART"
    hdr[0:8] = b"EFI PART"
    # Revision 1.0
    struct.pack_into("<I", hdr, 8, 0x00010000)
    # Header size (92 bytes for v1.0)
    struct.pack_into("<I", hdr, 12, 92)
    # CRC32 of header (placeholder, filled later)
    struct.pack_into("<I", hdr, 16, 0)
    # Reserved
    struct.pack_into("<I", hdr, 20, 0)
    # Current LBA (this header's location)
    struct.pack_into("<Q", hdr, 24, 1)
    # Backup LBA (at end of disk)
    struct.pack_into("<Q", hdr, 32, total_sectors - 1)
    # First usable LBA
    struct.pack_into("<Q", hdr, 40, DATA_START_LBA)
    # Last usable LBA
    struct.pack_into("<Q", hdr, 48, total_sectors - 1 - GPT_ENTRY_SECTORS - 1)
    # Disk GUID
    hdr[56:72] = guid_bytes(disk_guid)
    # Partition entry starting LBA
    struct.pack_into("<Q", hdr, 72, part_entry_lba)
    # Number of partition entries
    struct.pack_into("<I", hdr, 80, num_entries)
    # Size of each partition entry
    struct.pack_into("<I", hdr, 84, entry_size)
    # CRC32 of partition entries array
    struct.pack_into("<I", hdr, 88, entries_crc)
    # Calculate header CRC (with CRC field zeroed)
    hdr_crc = crc32(bytes(hdr[0:92]))
    struct.pack_into("<I", hdr, 16, hdr_crc)
    return bytes(hdr)


def build_partition_entry(part_type_guid, part_guid, first_lba, last_lba, attr, name):
    """Build a single GPT partition entry (128 bytes)."""
    entry = bytearray(GPT_ENTRY_SIZE)
    # Partition type GUID
    entry[0:16] = guid_bytes(part_type_guid)
    # Unique partition GUID
    entry[16:32] = guid_bytes(part_guid)
    # First LBA
    struct.pack_into("<Q", entry, 32, first_lba)
    # Last LBA
    struct.pack_into("<Q", entry, 40, last_lba)
    # Attributes
    struct.pack_into("<Q", entry, 48, attr)
    # Partition name (UTF-16LE, max 36 chars = 72 bytes)
    name_bytes = name.encode("utf-16-le")[:72]
    entry[56:56 + len(name_bytes)] = name_bytes
    return bytes(entry)


def build_partition_entries(partitions):
    """Build the full partition entries array (128 entries x 128 bytes)."""
    entries = bytearray(GPT_ENTRIES * GPT_ENTRY_SIZE)
    for i, (type_guid, part_guid, first_lba, last_lba, attr, name) in enumerate(partitions):
        entry = build_partition_entry(type_guid, part_guid, first_lba, last_lba, attr, name)
        entries[i * GPT_ENTRY_SIZE:(i + 1) * GPT_ENTRY_SIZE] = entry
    return bytes(entries)


def copy_file_to_offset(src_path, dst_file, dst_offset, chunk_size=1024 * 1024 * 64):
    """Copy src_path to dst_file at dst_offset (sparse-aware)."""
    src_size = os.path.getsize(src_path)
    copied = 0
    with open(src_path, "rb") as src:
        dst_file.seek(dst_offset)
        while True:
            chunk = src.read(chunk_size)
            if not chunk:
                break
            dst_file.write(chunk)
            copied += len(chunk)
            if copied % (1024 * 1024 * 512) == 0:
                print(f"    ... copied {copied / 1024 / 1024:.0f} MiB / {src_size / 1024 / 1024:.0f} MiB", flush=True)
    return copied


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)

    data_path = sys.argv[1]
    hash_path = sys.argv[2]
    output_path = sys.argv[3]

    data_size = os.path.getsize(data_path)
    hash_size = os.path.getsize(hash_path)

    data_sectors = data_size // SECTOR_SIZE
    hash_sectors = hash_size // SECTOR_SIZE

    print(f"=== dm-verity Disk Image Assembler ===")
    print(f"  Data image: {data_path}")
    print(f"    Size: {data_size} bytes = {data_sectors} sectors = {data_size // 4096} 4K-blocks")
    print(f"  Hash image: {hash_path}")
    print(f"    Size: {hash_size} bytes = {hash_sectors} sectors = {hash_size // 4096} 4K-blocks")
    print(f"  Output: {output_path}")
    print()

    # Calculate layout
    data_first_lba = DATA_START_LBA
    data_last_lba = data_first_lba + data_sectors - 1

    # Hash partition: align start to 2048-sector (1 MiB) boundary
    hash_first_lba_raw = data_last_lba + 1
    hash_first_lba = ((hash_first_lba_raw + 2047) // 2048) * 2048
    hash_last_lba = hash_first_lba + hash_sectors - 1

    # Total disk: round up to 2048-sector boundary, then add GPT backup (34 sectors)
    last_usable = hash_last_lba
    # Backup GPT: entries (32 sectors) + header (1 sector) = 33 sectors after last usable
    total_sectors = ((last_usable + 1 + GPT_ENTRY_SECTORS + 1 + 2047) // 2048) * 2048
    backup_entries_lba = total_sectors - 1 - GPT_ENTRY_SECTORS
    backup_header_lba = total_sectors - 1

    total_4k_blocks = total_sectors // 8

    print(f"=== Virtual Disk Layout ===")
    print(f"  LBA 0:              Protective MBR")
    print(f"  LBA 1:              GPT Header")
    print(f"  LBA 2-{1 + GPT_ENTRY_SECTORS}:       GPT Partition Entries ({GPT_ENTRY_SECTORS} sectors)")
    print(f"  LBA {GPT_ENTRY_SECTORS + 2}-{data_first_lba - 1}:       Padding (alignment)")
    print(f"  LBA {data_first_lba}-{data_last_lba}:  Partition 1 (data, {data_sectors} sectors = {data_size / 1024 / 1024 / 1024:.2f} GiB)")
    if hash_first_lba > data_last_lba + 1:
        print(f"  LBA {data_last_lba + 1}-{hash_first_lba - 1}:       Padding (alignment)")
    print(f"  LBA {hash_first_lba}-{hash_last_lba}:  Partition 2 (hash, {hash_sectors} sectors = {hash_size / 1024 / 1024:.2f} MiB)")
    print(f"  LBA {backup_entries_lba}-{backup_entries_lba + GPT_ENTRY_SECTORS - 1}:  Backup GPT Entries")
    print(f"  LBA {backup_header_lba}:          Backup GPT Header")
    print(f"  Total: {total_sectors} sectors = {total_sectors * SECTOR_SIZE / 1024 / 1024 / 1024:.2f} GiB = {total_4k_blocks} 4K-blocks")
    print()

    # Generate GUIDs
    disk_guid = uuid.uuid4()
    part1_guid = uuid.uuid4()
    part2_guid = uuid.uuid4()

    # Build partition entries
    partitions = [
        (LINUX_FS_GUID, part1_guid, data_first_lba, data_last_lba, 0, "gos1-fs"),
        (LINUX_FS_GUID, part2_guid, hash_first_lba, hash_last_lba, 0, "verity_rootfs_hash"),
    ]
    entries_data = build_partition_entries(partitions)
    entries_crc = crc32(entries_data)

    # Build GPT header
    gpt_header = build_gpt_header(total_sectors, 2, GPT_ENTRIES, GPT_ENTRY_SIZE, entries_crc, disk_guid)

    # Build protective MBR
    mbr = build_protective_mbr(total_sectors)

    # Create output file (sparse)
    print(f"  Creating sparse disk image ({total_sectors * SECTOR_SIZE} bytes)...")
    total_bytes = total_sectors * SECTOR_SIZE
    with open(output_path, "wb") as f:
        # Truncate to full size (creates sparse file)
        f.truncate(total_bytes)

        # Write protective MBR at LBA 0
        print("  Writing protective MBR...")
        f.seek(0)
        f.write(mbr)

        # Write GPT header at LBA 1
        print("  Writing GPT header...")
        f.seek(1 * SECTOR_SIZE)
        f.write(gpt_header)

        # Write partition entries at LBA 2
        print("  Writing GPT partition entries...")
        f.seek(2 * SECTOR_SIZE)
        f.write(entries_data)

        # Write backup partition entries
        print("  Writing backup GPT partition entries...")
        f.seek(backup_entries_lba * SECTOR_SIZE)
        f.write(entries_data)

        # Write backup GPT header (with swapped current/backup LBA)
        print("  Writing backup GPT header...")
        backup_hdr = bytearray(gpt_header)
        # Swap current and backup LBA
        struct.pack_into("<Q", backup_hdr, 24, backup_header_lba)  # current = backup location
        struct.pack_into("<Q", backup_hdr, 32, 1)                   # backup = primary location
        # Recalculate CRC
        struct.pack_into("<I", backup_hdr, 16, 0)
        backup_crc = crc32(bytes(backup_hdr[0:92]))
        struct.pack_into("<I", backup_hdr, 16, backup_crc)
        f.seek(backup_header_lba * SECTOR_SIZE)
        f.write(bytes(backup_hdr))

        # Copy data image to partition 1
        data_offset = data_first_lba * SECTOR_SIZE
        print(f"  Copying data image to LBA {data_first_lba} (offset {data_offset})...")
        copy_file_to_offset(data_path, f, data_offset)

        # Copy hash image to partition 2
        hash_offset = hash_first_lba * SECTOR_SIZE
        print(f"  Copying hash image to LBA {hash_first_lba} (offset {hash_offset})...")
        copy_file_to_offset(hash_path, f, hash_offset)

    actual_size = os.path.getsize(output_path)
    # Check sparseness
    import subprocess
    du_result = subprocess.run(["du", "-h", output_path], capture_output=True, text=True)
    du_line = du_result.stdout.strip()

    print()
    print(f"=== Done ===")
    print(f"  Output: {output_path}")
    print(f"  Logical size: {actual_size} bytes ({actual_size / 1024 / 1024 / 1024:.2f} GiB)")
    print(f"  Disk usage: {du_line}")
    print(f"  Total 4K blocks (for TEGRA_VBLK_TOTAL_BLOCKS): {total_4k_blocks}")
    print()
    print(f"  To use with QEMU tegra186 --verity mode:")
    print(f"    export TEGRA_ROOTFS_IMG={output_path}")
    print(f"    export TEGRA_VBLK_TOTAL_BLOCKS={total_4k_blocks}")
    print(f"    ./launch_tegra186.sh --verity")
    print()
    print(f"  Expected dm-verity bootargs:")
    print(f'    dm="1 vroot none ro 1,0 {data_sectors} verity 1 /dev/vblkdev0p1 /dev/vblkdev0p2 4096 4096 {data_size // 4096} 0 sha256 5830e1d5ab8e48dff4e005a812f60b9244b007f0651eb8b0de6c1e518d1ffdb2 caa1129717e173bfcc27ec028cd8bb5b9471fb4b5d00db401d715b5a3cc4a238 1 check_at_most_once" root=/dev/dm-0')


if __name__ == "__main__":
    main()
