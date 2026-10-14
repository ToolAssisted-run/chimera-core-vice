# Design log

What was decided for this core, why, and what was measured. Newest last.

## 2026-10-14: VICE, through vice-libretro

**Why this core.** The owner's goal is every system BizHawk has in Chimera
too (2026-10-12); after the cores BizHawk runs in its own sandbox came the
systems BizHawk emulates in C#, each needing an emulator chosen. The C64
first: the owner has its games and BizHawk's C64 firmware here. VICE is the
C64 emulator of record, with a cycle-exact C64 (x64sc) and a 1541 drive
that runs its own processor. As for the other cores of this round, the
owner's instruction: a fresh adaptation of upstream's latest, BizHawk read
for ideas only (nothing was taken from it).

**Upstream.** vice-libretro (libretro/vice-libretro f63b566, 2026-10-03),
VICE 3.10 with a libretro layer, GPL-2.0-or-later. `meson.build` compiles
the list its Makefile compiles for x64sc. The core drives upstream's
libretro layer (`waterbox/cinterface.c`), as the PUAE core does.

**Controls go to VICE directly.** Upstream's input mapper builds the
control ports from a libretro controller every frame; patch 0001 makes it
stand aside. The core sets the two ports itself (P1 in port 2 by default)
and the C64's keyboard matrix (the 64 keys at their row and column; RESTORE
on the NMI line). SHIFT LOCK is not a key: it latches Left Shift down.
Patch 0002 counts reads of CIA 1's ports, where the keyboard and the
joysticks are read; a frame without one is a lag frame.

**What made a run differ, and what was done:**

- VICE seeds its random numbers from `time(NULL)` (the pattern the RAM holds
  at power-on, a random wait before autostart). The core's clock is the
  Starting Clock plus the frames run, and `rand()` is defined once (musl's),
  so the native build draws what the sandbox draws.
- The 1541's rotation wobble is computed with `sinf()` and turned into whole
  cycles, and reSID builds its filter with `sin`, `cos`, `exp`, `log` and
  `pow`: glibc and musl can differ in the last bit. musl's own functions are
  compiled into both builds (`waterbox/libm`).
- The sandbox's files cannot be opened for writing, so VICE attached the
  disk write-protected in the sandbox and writable natively, and the 1541's
  DOS reads the write-protect sensor. Found by comparing VICE's own
  snapshots of both builds frame by frame: one byte, the drive's
  `read_only`, from frame 2. Now every file VICE opens goes through the
  core's libretro file interface (`waterbox/chimera-vfs.c`), which reads it
  whole and keeps it in memory: a write changes the copy only, a savestate
  holds it, and Export Save Data writes out the project's files the C64
  changed, after the 1541 writes back the track under its head (it keeps it
  until the head moves or the disk comes out).
- Smaller ones: upstream's `sysconfig.h` turns stdio into libretro's file
  functions and makes `stderr` 0, so the core's own file declares the VICE
  functions it calls instead of including it; the sandbox's `getcwd` answers
  "." (VICE joins it to its search folders) and its `stat` takes "./name"
  as "name".

**The ROMs.** VICE carries the C64's KERNAL, BASIC and character ROMs and
the 1541's DOS ROM (Commodore's copyright, says its README) and the core is
built with them, as upstream builds it; so no firmware is asked for. The
owner decides whether the package may carry them (the Jaguar's boot ROMs
were decided the same way, "as upstream").

**Measured** (test script, `waterbox/run-gate.sh`, with a program and a
disk the tests write themselves):

- every joystick direction and fire of both ports, and P1 Port moving P1;
- each of the 64 keys alone is the one bit of its row and column; RESTORE
  pressed once is one NMI, twice two;
- the program that reads its controls has no lag frame, its twin that reads
  none one every frame;
- native == sandbox (memory, picture, sound, every 10 frames), with a state
  saved and loaded every frame, moved to a new sandbox, and rewound;
- another Starting Clock is another run, the same in both builds;
- a file the program saves through the KERNAL is on the exported disk,
  closed; the user's file is unchanged; with Next Disk and Eject Disk
  pressed first, it goes to the second disk;
- Jupiter Lander on disk and on cartridge, Ninja on tape: they load, and
  native == sandbox with presses (and a state every frame).

Test script 21 passed, 0 failed, 0 skipped; window test 3 passed (the test
program and Jupiter Lander in Chimera's window, the RAM Chimera's headless
runner leaves); Chimera's package checks 18. On Windows, Chimera's
headless runner plays the test program, Jupiter Lander and 8,000 frames of
Ninja's tape to the same memory as on Linux.
