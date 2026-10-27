#!/bin/bash
# The package in Chimera's own window (run headless: it needs no display),
# which the headless runner cannot show:
#  - the test program (tests/make-c64-program.py) autostarts in the window
#    and leaves the RAM the headless runner leaves at the same frame, with
#    the picture VICE gives (384x272);
#  - the keys the package ships become Chimera's keys for the C64;
#  - with a game on disk (C64_DISK_GAME, as waterbox/run-gate.sh takes it):
#    a project of it runs in the window and leaves the headless runner's RAM.
#
# Usage: tests/run-frontend.sh --chimera-root <chimera checkout> [--frames N] [--keep]
#   --keep   leave the work folder (logs, configurations, projects) and say where it is
# Needs: Chimera built with its window (chimera --headless), and the
# package installed in that checkout (waterbox/build-package.sh -r <chimera>).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
wb="$root/waterbox"
frames=700
chimera_root=""
keep=""
while [ $# -gt 0 ]; do
	case "$1" in
		--keep) keep=1 ;;
		--chimera-root) chimera_root="$2"; shift ;;
		--frames) frames="$2"; shift ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) break ;;
	esac
	shift
done
[ -n "$chimera_root" ] && [ -d "$chimera_root" ] || { echo "say where Chimera is: --chimera-root <chimera checkout>" >&2; exit 2; }
chimera_root="$(cd "$chimera_root" && pwd)"
game="${C64_DISK_GAME:-$here/games-local/jupiter}"

chimera_exe="$chimera_root/build/meson-linux/source/ui/chimera"
package="$chimera_root/build/Cores/vice.chimeraCore"
runwbx="$root/build/meson-native/run-wbx"
core="$root/build/meson-guest/core.wbx"
runner="$chimera_root/build/meson-linux/chimera-run"
[ -x "$chimera_exe" ] || { echo "Chimera's window is not built: $chimera_exe" >&2; exit 1; }
[ -f "$package" ] || { echo "the package is not installed: $package (run waterbox/build-package.sh -r $chimera_root)" >&2; exit 1; }
[ -x "$runwbx" ] && [ -f "$core" ] || { echo "the sandbox build is not there: $runwbx, $core" >&2; exit 1; }
[ -x "$runner" ] || { echo "Chimera's headless runner is not built: $runner" >&2; exit 1; }

work="$(mktemp -d)"
cleanup() {
	if [ -n "$keep" ]; then echo "work folder kept: $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

# run-wbx finds miniBox's host library in Chimera's build/dll
export LD_LIBRARY_PATH="$chimera_root/build/dll${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Chimera's window, run headless: the cores installed in the checkout, its
# settings, cache and recovery files the run's own, and nothing carried over
# from a Chimera installed on this machine
export ALSOFT_DRIVERS=null CHIMERA_CORES_DIR="$chimera_root/build/Cores" CHIMERA_QT_CACHE="$work/qt-cache" CHIMERA_QT_RECOVERY="$work/qt-recovery" \
	CHIMERA_QT_HASHES="$work/qt-file-hashes.txt" CHIMERA_QT_CHIMERA_SETTINGS="$work/no-chimera-config.ini"

ok=0
failed=0
skipped=0
report() {
	printf '%-16s %-5s %s\n' "$1" "$2" "$3"
	case "$2" in PASS) ok=$((ok + 1)) ;; SKIP) skipped=$((skipped + 1)) ;; *) failed=$((failed + 1)) ;; esac
}

# make_project <tag> <frames> <file> [<setting>=<value> | press=...]...
# A project with the file beside it, where Chimera looks, and a movie of
# that many frames over the C64's controls.
make_project() {
	local tag="$1" nframes="$2" gamefile="$3"; shift 3
	local dir="$work/$tag"
	mkdir -p "$dir"
	cp "$gamefile" "$dir/"
	python3 "$here/make-project.py" "$package" "$dir/$tag.chimeraProject" "$nframes" "panel=$work/panel.out" "$@" \
		-- "game=$dir/$(basename "$gamefile")" > "$work/$tag.log" 2>&1
}
# run_frontend <tag> <configuration> <frames> <domain or "">: the project in the window
run_frontend() {
	local tag="$1" cfg="$2" nframes="$3" domain="$4" job="$work/job.$1.txt"
	{
		echo "frames=$nframes"
		echo "out=$work/$tag.ram.bin"
		echo "meta=$work/$tag.meta.txt"
		echo "shot="
		echo "domain=$domain"
	} > "$job"
	( cd "$chimera_root" && MINIHAWK_JOB="$job" timeout 900 "$chimera_exe" --headless \
		"--config=$cfg" "--project=$work/$tag/$tag.chimeraProject" "--lua=$here/frontend-ram.lua" ) >> "$work/$tag.log" 2>&1
	[ -f "$work/$tag.meta.txt" ] && grep -q "^status=OK" "$work/$tag.meta.txt"
}
value() { sed -n "s/^$2=//p" "$work/$1.meta.txt" 2>/dev/null; }

python3 "$here/settings-config.py" "$work/settings.base.json" '{}'

# ---- the test program: needs no file of anyone's
mkdir -p "$work/prog" "$work/probe"
python3 "$here/make-c64-program.py" "$work/prog/test.prg" > /dev/null
ln -sf "$work/prog/test.prg" "$work/probe/test.prg"
printf '{"game":["test.prg"]}' > "$work/probe/slots"; printf '{}' > "$work/probe/settings"
"$runwbx" "$core" "$work/probe" --frames 1 --list-panel > "$work/panel.out" 2> /dev/null
# the movie is longer than the run: a window whose movie ends stops there;
# P1 Up is held from frame 500 (row 499) to the end
make_project pg $((frames + 100)) "$work/prog/test.prg" "press=P1 Up:499:$frames"
"$runner" --project "$work/pg/pg.chimeraProject" "$package" --files "$work/pg" --frames "$frames" \
	--dump "RAM=$work/engine.ram.bin" > "$work/engine.log" 2>&1
up="$(od -An -tx1 -j $((0xC002)) -N1 "$work/engine.ram.bin" 2> /dev/null | tr -d ' ')"
if ! run_frontend pg "$work/settings.base.json" "$frames" "RAM"; then
	report "window:c64" FAIL "Chimera did not finish the run: $(value pg detail) $(tail -2 "$work/pg.log" | tr '\n' ' ' | cut -c1-200)"
elif [ "$(value pg frames)" != "$frames" ] || [ "$(value pg width)" != 384 ] || [ "$(value pg height)" != 272 ]; then
	report "window:c64" FAIL "frames $(value pg frames) of $frames, picture $(value pg width)x$(value pg height) and not 384x272"
elif [ -s "$work/engine.ram.bin" ] && cmp -s "$work/engine.ram.bin" "$work/pg.ram.bin" && [ "$up" = fe ]; then
	report "window:c64" PASS "the test program autostarted and ran $frames frames in Chimera's window, 384x272, with P1 Up held from frame 500 (port 2 reads $up); its RAM ($(wc -c < "$work/pg.ram.bin") bytes) is what the headless runner leaves"
else
	report "window:c64" FAIL "the RAM differs from the headless runner's (or one of the two is missing), or P1 Up did not reach the program (port 2 $up)"
fi

# the keys the package ships are the machine's when nobody changed them (the
# window keeps only the keys a person changed; fresh settings have none)
mkdir -p "$work/keys"; cp "$work/pg/test.prg" "$work/keys/"; sed 's/"vice-test-[^"]*"/"vice-test-keys"/' "$work/pg/pg.chimeraProject" > "$work/keys/keys.chimeraProject"
printf 'out=%s/keys.controls.json\nmeta=%s/keys.meta.txt\n' "$work" "$work" > "$work/job.keys.txt"
( cd "$chimera_root" && MINIHAWK_JOB="$work/job.keys.txt" timeout 900 "$chimera_exe" --headless \
	"--config=$work/settings.keys.json" "--project=$work/keys/keys.chimeraProject" "--lua=$here/dump-controls.lua" ) >> "$work/keys.log" 2>&1
if [ -f "$work/keys.meta.txt" ] && grep -q "^status=OK" "$work/keys.meta.txt"; then
	if python3 "$here/check-keybinds.py" "$work/keys.controls.json" "$wb/default_keybinds.json" "C64 Controls" "P1 Fire" > "$work/keys.txt" 2>&1; then
		report "window:keys" PASS "$(cat "$work/keys.txt")"
	else
		report "window:keys" FAIL "$(head -1 "$work/keys.txt")"
	fi
else
	report "window:keys" FAIL "Chimera did not finish the run: $(tail -2 "$work/keys.log" | tr '\n' ' ' | cut -c1-200)"
fi

# ---- a game on disk
d64="$(ls "$game"/*.d64 "$game"/*.D64 2> /dev/null | head -1)"
if [ -z "$d64" ]; then
	report "window:game" SKIP "needs a game on disk (a .d64 in C64_DISK_GAME)"
else
	gframes=1500
	make_project gm $((gframes + 100)) "$d64" "press=Key 1:1399:10"
	"$runner" --project "$work/gm/gm.chimeraProject" "$package" --files "$work/gm" \
		--frames "$gframes" --dump "RAM=$work/gm-engine.ram.bin" > "$work/gm-engine.log" 2>&1
	if ! run_frontend gm "$work/settings.base.json" "$gframes" "RAM"; then
		report "window:game" FAIL "Chimera did not finish the run: $(value gm detail) $(tail -2 "$work/gm.log" | tr '\n' ' ' | cut -c1-200)"
	elif [ "$(value gm frames)" = "$gframes" ] && [ -s "$work/gm-engine.ram.bin" ] && cmp -s "$work/gm-engine.ram.bin" "$work/gm.ram.bin"; then
		report "window:game" PASS "a project of $(basename "$d64") autostarted from its disk, ran $gframes frames in the window with a key pressed, $(value gm width)x$(value gm height), and left the RAM the headless runner leaves"
	else
		report "window:game" FAIL "frames $(value gm frames) of $gframes, or the RAM differs from the headless runner's"
	fi
fi

echo
echo "$ok passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
