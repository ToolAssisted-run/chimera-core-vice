#!/usr/bin/env python3
"""Writes a 1541 disk image (.d64, 174,848 bytes, 35 tracks) for the VICE
core's tests, formatted as the 1541 formats a disk, with one program on it.
It needs no file of anyone's.

usage: make-d64.py <out.d64> <program.prg> [name]

The program is the disk's first file (PRG, under the name given, TEST when
none), so that LOAD"*",8 loads it; the rest of the disk is free."""
import sys

SECTORS = [21] * 17 + [19] * 7 + [18] * 6 + [17] * 5   # tracks 1-35


def offset(track, sector):
    return (sum(SECTORS[:track - 1]) + sector) * 256


def main():
    out, prg = sys.argv[1], open(sys.argv[2], "rb").read()
    name = (sys.argv[3] if len(sys.argv) > 3 else "TEST").upper().encode()
    disk = bytearray(sum(SECTORS) * 256)
    used = {18: {0, 1}}
    # the file, on track 17 from sector 0
    chunks = [prg[i:i + 254] for i in range(0, len(prg), 254)]
    track, sectors = 17, list(range(len(chunks)))
    assert len(chunks) <= SECTORS[track - 1]
    for i, chunk in enumerate(chunks):
        o = offset(track, sectors[i])
        if i + 1 < len(chunks):
            disk[o:o + 2] = bytes([track, sectors[i + 1]])
        else:
            disk[o:o + 2] = bytes([0, len(chunk) + 1])
        disk[o + 2:o + 2 + len(chunk)] = chunk
        used.setdefault(track, set()).add(sectors[i])
    # the directory, track 18 sector 1: one entry
    d = offset(18, 1)
    disk[d:d + 2] = bytes([0, 0xFF])
    entry = bytearray(30)
    entry[0] = 0x82                         # PRG, closed
    entry[1:3] = bytes([track, sectors[0]])
    entry[3:19] = name[:16].ljust(16, b"\xA0")
    entry[28:30] = len(chunks).to_bytes(2, "little")
    disk[d + 2:d + 32] = entry
    # the BAM, track 18 sector 0
    b = offset(18, 0)
    disk[b:b + 4] = bytes([18, 1, 0x41, 0])
    for t in range(1, 36):
        free = [s for s in range(SECTORS[t - 1]) if s not in used.get(t, set())]
        bits = sum(1 << s for s in free)
        disk[b + 4 * t:b + 4 * t + 4] = bytes([len(free), bits & 0xFF, (bits >> 8) & 0xFF, (bits >> 16) & 0xFF])
    disk[b + 0x90:b + 0xA0] = b"CHIMERA TEST".ljust(16, b"\xA0")
    disk[b + 0xA0:b + 0xAB] = b"\xA0\xA0CT\xA02A\xA0\xA0\xA0\xA0"
    open(out, "wb").write(disk)
    print("%s: %s, %d blocks" % (out, name.decode(), len(chunks)))


if __name__ == "__main__":
    main()
