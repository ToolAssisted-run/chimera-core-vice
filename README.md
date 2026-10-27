# chimera-core-vice

A core for [Chimera](https://github.com/ToolAssisted-run/chimera), the
frontend for tool-assisted speedruns, for the **Commodore 64**. It is built
on [VICE](https://vice-emu.sourceforge.io/) through its libretro port,
[vice-libretro](https://github.com/libretro/vice-libretro), and runs VICE's
cycle-exact C64 (x64sc). It produces one file, `vice.chimeraCore`, that goes
in Chimera's `cores` folder.

## Status

New, and not published yet.

- Games on disk, cartridge and tape run, and the sandboxed core gives the
  same results as a plain native build: picture, sound, both joysticks, the
  keyboard, lag frames, savestates, disk changes and disks the C64 writes
  to. Tried: Jupiter Lander (on disk and on cartridge) and Ninja (on tape).
- On Windows, Chimera's headless runner plays projects of a disk game, a
  tape game and the core's test program to the same memory as on Linux.
  Chimera's window was tried on Linux only.
- Not there: the C128 and VIC-20 and VICE's other machines, a second drive,
  the mouse, paddles and light pens, JiffyDOS.

## What you bring

- The game's files: disk images (`.d64`, `.g64`, `.x64`, `.d71`, `.d81`),
  tapes (`.t64`, `.tap`), a cartridge (`.crt`) or a program (`.prg`,
  `.p00`). A project holds up to 20; the first is loaded and run when the
  C64 is switched on (VICE's autostart).
- Nothing else: VICE carries the C64's and the 1541 drive's ROMs.

## Buttons and settings

- **P1 and P2**: a joystick each, Up, Down, Left, Right and Fire. P1's is in
  control port 2, where most games read the joystick (P1 Port moves it).
- **The keyboard**: the C64's own keys, by what is printed on them (`C=` is
  the Commodore key), and RESTORE.
- **The drive**: Previous Disk and Next Disk choose a disk; Eject Disk takes
  the disk out of drive 8 while it is held and puts the chosen one in.
- **The datasette**: Tape Play, Tape Stop, Tape Rewind, Tape Forward.
- **Settings**: Model (C64, C64C, SX-64 and others, PAL or NTSC), SID
  Model, True Drive Emulation, Autostart, P1 Port and Starting Clock (from
  which VICE takes its random numbers). All of them are part of the
  machine, so a movie needs the same values.

The C64 writes to copies of its disks in memory, never to your files, and a
savestate holds them. Emulator > Export Save Data writes each disk the C64
changed.

RAM Watch and RAM Search read the C64's 64 KB as RAM.

## Building and testing

[docs/BUILDING.md](docs/BUILDING.md) has every step. [docs/PLAN.md](docs/PLAN.md)
is the design log: what was decided, why, and what was measured.

## Licence

This repository's own code is MIT. VICE is under the GNU General Public
License version 2 or later, and so are the patches to it here and the
program in the built package. The package carries the licence texts of
everything in it; it holds the C64's and the 1541's ROMs that VICE itself
carries, and no game. See [LICENSE](LICENSE).
