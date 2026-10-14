# Building

This core is built on Linux. The result, `core.wbx`, is one file that runs in
Chimera on Linux and on Windows.

## What is needed

- GCC 13 or newer (C and C++), meson, ninja, git, python3.
- A checkout of Chimera with miniBox built, with its C++ guest toolchain
  (Chimera's `AGENTS.md`, "Build"). Below, `<miniBox>` is its
  `extern/chimera-common-minibox` folder.

## VICE's source

vice-libretro, the libretro port of VICE, is a submodule, `extern/vice`, at
a commit of its master branch (docs/PLAN.md says which):

```sh
git submodule update --init
```

A change to it is kept as a numbered patch in `patches/`.
`waterbox/apply-patches.sh` lays the patches over the submodule (the build
runs it; it does nothing to a tree that has them). To make a patch, edit the
files in `extern/vice`, build and test, add the file to the list in
`waterbox/make-patches.sh` if it is new, and run that script.

## What is compiled

`meson.build` lists the files upstream's own Makefile compiles for x64sc,
VICE's cycle-exact C64 (`make EMUTYPE=x64sc platform=unix`), and the
core's own:

- `waterbox/cinterface.c`: the program around the emulator. It calls
  upstream's `retro_*` functions and answers their questions, as a libretro
  frontend does, and gives the C64 its controls directly.
- `waterbox/chimera-vfs.c`: every file VICE opens, held in memory (writes
  stay there; Export Save Data takes them out).
- `waterbox/libm/`: musl's `sin`, `cos`, `sinf`, `exp`, `log` and `pow`,
  in both builds, so the native build computes what the sandbox does
  (`waterbox/libm/README`).

## The two flavors

- `native`: for the host. `run-native` is the reference the tests compare
  the sandbox with.
- `guest`: for miniBox's sandbox. This is `core.wbx`, and `run-wbx` runs it.

```sh
meson setup build/meson-native -Dminibox_dir=<miniBox> && ninja -C build/meson-native
waterbox/setup-guest.sh -m <miniBox> && ninja -C build/meson-guest
```

Both runners take a work folder that holds what the sandbox would see: the
game's files under their names, a file `slots` (`{"game":["game.d64"]}`)
and a file `settings` (`{}` or, say, `{"c64_model":"C64 NTSC"}`).
`waterbox/gate-harness.h` lists the options they share (`--frames`,
`--report`, `--press`, `--vid-out`, `--dump-domain`, `--savedata-out`,
`--list-panel`). In the native runner, `CHIMERA_VICE_LOG=1` prints VICE's
log and `CHIMERA_VICE_OPTIONS=1` the options it was given, with their
values.

## The package

```sh
waterbox/build-package.sh -r <chimera checkout>
```

builds the sandbox core and writes `build/Cores/vice.chimeraCore` in that
checkout. `tests/make-project.py` writes a project for a game, which
Chimera's `chimera-run --project` then plays.

## The tests

```sh
CHIMERA_ROOT=<chimera checkout> waterbox/run-gate.sh
```

runs every test and says, for each, what was compared. The "c64:" tests
need nothing: `tests/make-c64-program.py` writes a small test program and
`tests/make-d64.py` puts it on a disk. The others need games that cannot be
in this repository, and say SKIP without them:

| Tests | What they need | Where the script looks | Or name it with |
|---|---|---|---|
| `game:disk` | a game on a disk, as a folder with a `.d64` | `tests/games-local/jupiter` | `C64_DISK_GAME` |
| `game:cartridge` | a cartridge, a `.crt` | `tests/games-local/jupiter` | `C64_CART_GAME` |
| `game:tape` | a game on tape, a `.tap` | `tests/games-local/tape` | `C64_TAPE_GAME` |

Copy the files there; do not link them from where you keep them. Without
`CHIMERA_ROOT` the tests that need Chimera are skipped.

`bash tests/run-frontend.sh --chimera-root <chimera checkout>` is the window
test: the package in Chimera's own window (under Mono, on a private Xvfb
display). Mono limits the length of a path it makes under the temporary
folder, so give it a short one (`TMPDIR=$PWD/build/t`) when the default is
long.

## What CI does

`.github/workflows/chimera.yml` builds the core from a fresh clone, runs
both test scripts and Chimera's checks of the package, and publishes the
package. No game may be put on a runner, so the "game:" tests are skipped
there; the "c64:" tests, the package's and the window's run.
