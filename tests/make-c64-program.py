#!/usr/bin/env python3
"""Writes a C64 program (.prg) for the VICE core's tests. It needs no file of
anyone's.

usage: make-c64-program.py <out.prg> [nopad]

The program, hand-assembled below (6502 machine code), is a line of BASIC,
10 SYS 2061, and the code after it. VICE's autostart puts it in memory and
types RUN. It:
  - takes the machine over: no interrupts from CIA 1 (so the KERNAL does not
    scan the keyboard), and RESTORE's NMI counted by the program;
  - for ever, once a frame (it waits for raster line 250 to come and go):
    - counts the frames at $C000 (16 bits, low byte first);
    - with no keyboard row selected, copies CIA 1's port A ($DC00, the
      joystick in control port 2, bits 0-4 up down left right fire, 0 while
      held) to $C002 and port B ($DC01, the joystick in port 1) to $C003;
    - selects each keyboard row in turn ($DC00 = all bits but the row's) and
      copies the columns ($DC01, 0 for a key held) to $C008 + row;
    - RESTORE's NMI adds one to $C004.
  $C030 holds "C64T" once the program runs.
Made with "nopad" it reads neither port (only the raster), so every frame is
a lag frame. Made with "save" it first lets 250 frames go by, then saves
$C000-$C03F to drive 8 as the file OUT, through the KERNAL (SETLFS, SETNAM,
SAVE), and sets $C005 to 1 when the KERNAL says the save went well.
"""
import struct
import sys


def assemble(nopad, save=False):
    org = 0x0801
    code = bytearray()
    labels, fixups = {}, []

    def here():
        return org + len(code)

    def b(*xs):
        code.extend(xs)

    def w(v):
        code.extend(struct.pack("<H", v))

    def label(n):
        labels[n] = here()

    def branch(op, target):
        b(op, 0)
        fixups.append(("rel", len(code) - 1, target))

    def absref(op, target, add=0):
        b(op, 0, 0)
        fixups.append(("abs", len(code) - 2, target, add))

    # 10 SYS 2061
    w(0x080B); w(10); b(0x9E); code.extend(b"2061"); b(0); w(0)
    assert here() == 2061
    if save:
        # first 250 frames go by (time for a disk change), counted on the raster
        b(0xA0, 250)                                                        # ldy #250
        label("sw1")
        b(0xAD); w(0xD012); b(0xC9, 0xFA); branch(0xD0, "sw1")
        label("sw2")
        b(0xAD); w(0xD012); b(0xC9, 0xFA); branch(0xF0, "sw2")
        b(0x88); branch(0xD0, "sw1")                                        # dey / bne
        b(0xA9, 0x01); b(0xA2, 0x08); b(0xA0, 0x01); b(0x20); w(0xFFBA)   # SETLFS 1,8,1
        b(0xA9, 0x03)                                                       # three letters
        absref(0xA2, "outname")                                             # ldx #<name
        fixups[-1] = ("lo", len(code) - 2, "outname"); code.pop()
        b(0xA0, 0); fixups.append(("hi", len(code) - 1, "outname"))        # ldy #>name
        b(0x20); w(0xFFBD)                                                  # SETNAM
        b(0xA9, 0x00); b(0x85, 0xFB); b(0xA9, 0xC0); b(0x85, 0xFC)          # $FB/$FC = $C000
        b(0xA9, 0xFB); b(0xA2, 0x40); b(0xA0, 0xC0); b(0x20); w(0xFFD8)     # SAVE to $C040
        b(0x08)                                                             # php (carry: an error)
    b(0x78)                        # sei
    b(0xA9, 0x7F); b(0x8D); w(0xDC0D)   # lda #$7f / sta $dc0d: CIA 1 interrupts off
    b(0xAD); w(0xDC0D)             # lda $dc0d: and acknowledged
    if save:
        b(0x28)                    # plp
    b(0xA9, 0x00); b(0xA2, 0x3F)   # lda #0 / ldx #$3f
    label("clr")
    b(0x9D); w(0xC000)             # sta $c000,x
    b(0xCA)                        # dex
    branch(0x10, "clr")            # bpl clr
    if save:
        branch(0xB0, "saveerr")    # bcs: the save failed
        b(0xA9, 0x01); b(0x8D); w(0xC005)
        label("saveerr")
    for i, c in enumerate(b"C64T"):
        b(0xA9, c); b(0x8D); w(0xC030 + i)
    absref(0xA9, "nmi", 0)         # lda #<nmi (patched below to an immediate)
    fixups[-1] = ("lo", len(code) - 2, "nmi")
    code.pop()                     # an immediate is one byte
    b(0x8D); w(0x0318)             # sta $0318
    b(0xA9, 0)
    fixups.append(("hi", len(code) - 1, "nmi"))
    b(0x8D); w(0x0319)             # sta $0319
    label("loop")
    label("w1")
    b(0xAD); w(0xD012); b(0xC9, 0xFA)   # lda $d012 / cmp #250
    branch(0xD0, "w1")             # bne w1
    label("w2")
    b(0xAD); w(0xD012); b(0xC9, 0xFA)
    branch(0xF0, "w2")             # beq w2
    b(0xEE); w(0xC000)             # inc $c000
    branch(0xD0, "nocarry")        # bne
    b(0xEE); w(0xC001)             # inc $c001
    label("nocarry")
    if not nopad:
        b(0xA9, 0xFF); b(0x8D); w(0xDC00)   # no row selected
        b(0xAD); w(0xDC00); b(0x8D); w(0xC002)
        b(0xAD); w(0xDC01); b(0x8D); w(0xC003)
        b(0xA2, 0x00)              # ldx #0
        label("kb")
        absref(0xBD, "rows")       # lda rows,x
        b(0x8D); w(0xDC00)         # sta $dc00
        b(0xAD); w(0xDC01)         # lda $dc01
        b(0x9D); w(0xC008)         # sta $c008,x
        b(0xE8)                    # inx
        b(0xE0, 0x08)              # cpx #8
        branch(0xD0, "kb")         # bne kb
        b(0xA9, 0xFF); b(0x8D); w(0xDC00)
    absref(0x4C, "loop")           # jmp loop
    label("nmi")
    b(0xEE); w(0xC004)             # inc $c004
    b(0x40)                        # rti
    label("rows")
    b(0xFE, 0xFD, 0xFB, 0xF7, 0xEF, 0xDF, 0xBF, 0x7F)
    label("outname")
    code.extend(b"OUT")

    for f in fixups:
        kind, at, name = f[0], f[1], f[2]
        t = labels[name]
        if kind == "rel":
            d = t - (org + at + 1)
            assert -128 <= d <= 127, (name, d)
            code[at] = d & 0xFF
        elif kind == "abs":
            code[at:at + 2] = struct.pack("<H", t + f[3])
        elif kind == "lo":
            code[at] = t & 0xFF
        elif kind == "hi":
            code[at] = t >> 8
    return struct.pack("<H", org) + bytes(code)


def main():
    nopad = len(sys.argv) > 2 and sys.argv[2] == "nopad"
    save = len(sys.argv) > 2 and sys.argv[2] == "save"
    data = assemble(nopad, save)
    open(sys.argv[1], "wb").write(data)
    print("%s: %d bytes%s" % (sys.argv[1], len(data), " (no controls read)" if nopad else ""))


if __name__ == "__main__":
    main()
