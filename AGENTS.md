# AGENTS.md - VICE core for Chimera

This repository builds VICE's Commodore 64 (x64sc, its cycle-exact one),
through its libretro port vice-libretro (https://github.com/libretro/vice-libretro),
as a core for Chimera (https://github.com/ToolAssisted-run/chimera), a
frontend for tool-assisted speedruns. It produces one file,
`vice.chimeraCore`: VICE compiled to run inside Chimera's sandbox (miniBox),
a small program around it, and the declarations Chimera reads (buttons,
settings, file types).

Read [docs/BUILDING.md](docs/BUILDING.md) before building and
[docs/PLAN.md](docs/PLAN.md) before changing how the core works: it is the
design log, with what was decided, why, and what was measured.

## Layout

- `extern/vice` - vice-libretro at a commit of its master branch, a
  submodule. Never edited in place: a change is a numbered patch in
  `patches/`, laid over the submodule by `waterbox/apply-patches.sh` and
  written by `waterbox/make-patches.sh` (its list says which file is in
  which patch; a file is in one patch, whole). Every change is inside
  `#ifdef CHIMERA_CORE` with a comment that says why.
- `meson.build` - the build of both flavors, with the files upstream's
  Makefile compiles for x64sc.
- `waterbox/cinterface.c` - the program around VICE: it answers the libretro
  layer's questions from the project (its settings and files), drives
  `retro_load_game` and `retro_run`, sets the control ports and the
  keyboard matrix, and is what Chimera's engine calls. It also defines the
  C library's time functions and `rand` (the core's own clock). It must not
  include VICE's headers (their `sysconfig.h` redefines stdio).
- `waterbox/chimera-vfs.c` - every file VICE opens, held in memory.
- `waterbox/libm/` - musl's math functions, in both builds.
- `waterbox/guest-syscalls.c` - sandbox-only answers to "is this file
  there" and "which folder is this" (the sandbox has files and no folders).
- `waterbox/waterbox.config`, `file_slots.json`, `default_keybinds.json`,
  `package-licenses.json` - what the package declares.
- `waterbox/run-native.c`, `waterbox/run-wbx.c` - the native runner and the
  sandbox runner. They take the same options and print the same lines
  (`waterbox/gate-harness.h` is the part they share).
- `waterbox/*.sh` - `apply-patches.sh`, `make-patches.sh`, `setup-guest.sh`
  (configures the sandbox build), `build-package.sh`, `run-gate.sh` (the
  test script).
- `tests/` - `make-c64-program.py` and `make-d64.py` (the test program and
  its disk), `run-frontend.sh` (the window test, with its helpers),
  `make-project.py` (writes a project for a game).
- `build/` - every build output, and `tests/games-local/` - games, for the
  tests that need them. Both are ignored by git.

## Build and test

```sh
git submodule update --init
meson setup build/meson-native -Dminibox_dir=<miniBox> && ninja -C build/meson-native
waterbox/setup-guest.sh -m <miniBox> && ninja -C build/meson-guest
waterbox/build-package.sh -r <chimera checkout>
CHIMERA_ROOT=<chimera checkout> waterbox/run-gate.sh
TMPDIR=$PWD/build/t bash tests/run-frontend.sh --chimera-root <chimera checkout>
```

Run both test scripts before every commit that touches what they cover, and
say in the commit what ran, with the numbers. A new test is broken on
purpose once and seen to fail.

## Rules of the repository

- **One thread.** A core runs on one thread on one clock. vice-libretro
  starts no thread; its locks are harmless with one.
- **No host clock, one random generator.** The core defines `time`,
  `gettimeofday`, `clock_gettime`, `localtime`, `localtime_r` and `rand`:
  the time is the Starting Clock setting plus the frames run, in UTC, and
  VICE seeds its random numbers from it. The test `c64:clock` holds it.
- **One libm.** A floating-point result that differs in its last bit
  becomes a different cycle count (the 1541's wobble). The functions VICE
  calls come from `waterbox/libm` in both builds; a new one VICE starts to
  call goes there too (`nm -u` on the native runner lists them).
- **The machine's state is its memory.** A savestate is the sandbox's copy
  of the core's memory, so nothing the machine changes may live in a file.
  Every file VICE opens is read whole into memory and written there
  (`chimera-vfs.c`); the user's file is never written to, and Export Save
  Data writes the project's files that changed.
- **The controls reach VICE directly**, not through upstream's libretro
  mapper (patch 0001). They are in two places that must agree: the tables
  in `cinterface.c` and the `input` of the machine in `waterbox.config`.
  The test `package:controls` compares them; `package:key-names` checks
  that the default bindings name keys Chimera knows
  (`tests/check-key-names.py`).
- **VICE's options are settings by name**: a setting named like an option
  less `vice_` sets it (`c64_model` is `vice_c64_model`). An option that
  names no default has its first value, as libretro has it. A few are fixed
  in `cinterface.c` (`kForced`): what would put warp, the host's
  configuration or upstream's own menus into a run.
- **The test program keeps a press only while it lasts.** A test that
  compares memory at the end holds the control to the end (a press of F:N
  ends before frame F+N). A movie's row N is the test runner's frame N + 1.
  Autostart runs the test program by about frame 300.
- **No game** is committed, uploaded to CI or attached to an issue. Test
  content stays under `tests/games-local`, and is copied there, never
  linked from where the owner keeps it.
- **When native and sandbox part,** compare VICE's own snapshots of both
  builds at a frame (`retro_serialize`) and map the differing byte to its
  module and field (docs/PLAN.md has how the last one was found).
- **Say what was not tried.** A model that started and never ran a game
  has not been shown to work.
- **Write in plain language**: commit messages, documents, comments and
  setting descriptions are read by people who have never seen this
  repository. `.md` files are ASCII.
- **Commits**: `type(scope): what changed`; a short body with what changed,
  why, and how it was tested, with the numbers. Stage explicit paths. No
  amending, no force push.

## What is the owner's to decide

Publishing, the roster row in Chimera, moving to another VICE commit,
whether the package carries VICE's ROMs, and anything a licence does not
plainly allow.
