#!/bin/sh
# The core's tests. Each line says what was compared. The script ends with a
# count of tests that passed, failed and were skipped, and with an error if
# any failed. A skipped test is not a pass.
#
#   waterbox/run-gate.sh
#
# CHIMERA_ROOT=<a Chimera checkout> adds the tests that need Chimera: the
# key names its bindings use, and the package in its headless runner
# (waterbox/build-package.sh -r <it> first). C64_DISK_GAME=<folder> holds a
# game on a disk, a .d64 file (tests/games-local/jupiter when not given),
# C64_CART_GAME=<folder> a cartridge, a .crt (the same folder), and
# C64_TAPE_GAME=<folder> a game on tape, a .tap (tests/games-local/tape).
#
# Needs the native build (meson setup build/meson-native ... && ninja) and
# the sandboxed core (waterbox/setup-guest.sh && ninja -C build/meson-guest):
# docs/BUILDING.md.
#
# WHAT RUNS WITH NO FILES OF YOURS. VICE carries the C64's ROMs, and
# tests/make-c64-program.py writes a small test program (tests/make-d64.py
# puts it on a disk), so the "c64:" tests run everywhere: the program runs,
# every control reaches it (both joysticks, every key, RESTORE), its reads
# of the controls are seen, a file it saves comes out as save data, a disk
# change reaches the drive, and the sandbox gives the native build's
# results with savestates. The "game:" tests need files of yours and say
# SKIP without them.
#
# The ways a test passes on a broken thing (Chimera's docs/gates.md) that
# these are written against: a machine that did nothing agrees with itself,
# so a run is first checked to have got somewhere; the end of a run hides a
# run that went another way and came back, so runs are compared as a stream
# of digests; and a comparison that cannot fail proves nothing, so each
# "the same" has a run beside it that must come out different.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
native="$root/build/meson-native/run-native"
runwbx="$root/build/meson-native/run-wbx"
core="$root/build/meson-guest/core.wbx"
chimera_root="${CHIMERA_ROOT:-}"
diskgame="${C64_DISK_GAME:-$root/tests/games-local/jupiter}"
cartgame="${C64_CART_GAME:-$root/tests/games-local/jupiter}"
tapegame="${C64_TAPE_GAME:-$root/tests/games-local/tape}"

work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT
ok=0; failed=0; skipped=0
report() { # <test> <PASS|FAIL|SKIP> <what>
	printf '%-24s %-6s %s\n' "$1" "$2" "$3"
	case "$2" in PASS) ok=$((ok + 1)) ;; FAIL) failed=$((failed + 1)) ;; *) skipped=$((skipped + 1)) ;; esac
}
# check <test> <what> <condition...>
check() {
	ck_test="$1"; ck_what="$2"; shift 2
	if "$@"; then report "$ck_test" PASS "$ck_what"; else report "$ck_test" FAIL "$ck_what"; fi
}
stream() { grep '^frame' "$1"; }
same() { [ -s "$1" ] && [ -s "$2" ] && cmp -s "$1" "$2"; }
differ() { [ -s "$1" ] && [ -s "$2" ] && ! cmp -s "$1" "$2"; }
# field <file> <name>: the value after a name in the file's last report line
field() { stream "$1" | tail -1 | awk -v f="$2" '{for (i = 1; i <= NF; i++) if ($i == f) { print $(i + 1); exit }}'; }
# the program's numbers (tests/make-c64-program.py keeps them from $C000):
# byte <RAM dump> <offset>, in hex; count <RAM dump>, its frame count
byte() { od -An -tx1 -j $((0xC000 + $2)) -N1 "$1" 2> /dev/null | tr -d ' '; }
bytes() { od -An -tx1 -j $((0xC000 + $2)) -N"$3" "$1" 2> /dev/null | tr -d ' \n'; }
count() { printf '%d' "0x$(od -An -tx1 -j $((0xC001)) -N1 "$1" 2> /dev/null | tr -d ' ')$(od -An -tx1 -j $((0xC000)) -N1 "$1" 2> /dev/null | tr -d ' ')"; }
# folder <name> <settings json> <file>...: a work folder as the sandbox
# mounts a project - every file under its name
folder() {
	fd_dir="$work/$1"; fd_settings="$2"; shift 2
	mkdir -p "$fd_dir"
	fd_files=""
	for fd_f in "$@"; do
		ln -sf "$fd_f" "$fd_dir/$(basename "$fd_f")"
		fd_files="$fd_files${fd_files:+,}\"$(basename "$fd_f")\""
	done
	printf '{"game":[%s]}' "$fd_files" > "$fd_dir/slots"
	printf '%s' "$fd_settings" > "$fd_dir/settings"
}
nat() { nt_out="$1"; nt_dir="$2"; shift 2; "$native" "$work/$nt_dir" "$@" > "$work/$nt_out.out" 2> "$work/$nt_out.err"; }
box() { bx_out="$1"; bx_dir="$2"; shift 2; "$runwbx" "$core" "$work/$bx_dir" "$@" > "$work/$bx_out.out" 2> "$work/$bx_out.err"; }
# index <folder> <control>: the control's place in the panel
index() { "$native" "$work/$1" --frames 1 --list-panel 2> /dev/null | grep "'$2'" | awk '{print $2}'; }
# repeats <file> <first> <second> <count> <step>: do the report lines from
# frame <second> on repeat those from frame <first> on (run-wbx --rewind).
# The count of lag frames is the runner's own and goes on counting, so it is
# left out.
repeats() {
	awk -v a="$2" -v b="$3" -v n="$4" -v step="$5" '
		/^frame/ { f = $2; $1 = ""; $2 = ""; sub(/ lag [0-9]+$/, ""); line[f] = $0 }
		END {
			for (i = step; i < n; i += step) {
				if (!((a + i) in line) || !((b + i) in line) || line[a + i] != line[b + i]) exit 1
				seen++
			}
			exit seen > 0 ? 0 : 1
		}' "$1"
}

if [ ! -x "$native" ] || [ ! -x "$runwbx" ] || [ ! -f "$core" ]; then
	echo "not built: this needs build/meson-native/run-native and run-wbx, and build/meson-guest/core.wbx (docs/BUILDING.md)" >&2
	exit 1
fi

# ------------------------------------------------- the source and the package
# VICE is the pinned commit with exactly the patches of patches/
patches="$(ls "$root"/patches/*.patch 2> /dev/null | wc -l)"
check "source:patched" "extern/vice is the pinned commit with the $patches patches of patches/" \
	sh -c "sh '$here/apply-patches.sh' > '$work/patches.log' 2>&1 && [ \"\$(git -C '$root' rev-parse HEAD:extern/vice)\" = \"\$(git -C '$root/extern/vice' rev-parse HEAD)\" ]"

# a sandbox build that failed must not be tested as the previous one
stale=""
for src in "$here"/cinterface.c "$here"/chimera-vfs.c "$root"/patches/*.patch; do
	[ -e "$src" ] || continue
	[ "$core" -nt "$src" ] || stale="$stale $(basename "$src")"
done
check "package:fresh" "core.wbx is not older than its sources${stale:+ (older than:$stale)}" [ -z "$stale" ]

# ------------------------------------------------- the C64, everywhere
mkdir -p "$work/files"
python3 "$root/tests/make-c64-program.py" "$work/files/test.prg" > /dev/null
python3 "$root/tests/make-c64-program.py" "$work/files/quiet.prg" nopad > /dev/null
python3 "$root/tests/make-c64-program.py" "$work/files/save.prg" save > /dev/null
python3 "$root/tests/make-d64.py" "$work/files/save.d64" "$work/files/save.prg" > /dev/null
python3 "$root/tests/make-d64.py" "$work/files/other.d64" "$work/files/quiet.prg" OTHER > /dev/null
prog="$work/files/test.prg"
folder pr '{}' "$prog"
folder qu '{}' "$work/files/quiet.prg"

# the buttons the package declares are the ones the core has, in order
"$native" "$work/pr" --frames 1 --list-panel > "$work/panel.out" 2> /dev/null
check "package:controls" "the package declares the core's own $(grep -c '^panel' "$work/panel.out") buttons, in the core's order" \
	python3 - "$here/waterbox.config" "$work/panel.out" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
buttons = [l[l.index("'") + 1:l.rindex("'")] for l in open(sys.argv[2]) if l.startswith("panel ")]
m = cfg["machines"]
sys.exit(0 if len(m) == 1 and m[0]["input"]["buttons"] == buttons and len(buttons) == 82 else 1)
PY
if [ -n "$chimera_root" ] && [ -f "$chimera_root/source/gui/Chimera.Input/KeyMouseInput/DistinctKey.cs" ]; then
	check "package:key-names" "every host key the package's default bindings name is a key Chimera knows: $(python3 "$root/tests/check-key-names.py" "$chimera_root" "$here/default_keybinds.json" 2>&1)" \
		sh -c "python3 '$root/tests/check-key-names.py' '$chimera_root' '$here/default_keybinds.json' > /dev/null 2>&1"
else
	report "package:key-names" SKIP "needs CHIMERA_ROOT, whose source names the keys Chimera knows"
fi

# autostart puts the program in memory and runs it by about frame 300; the
# controls are held from frame 500 to the end (a press of F:N ends before
# frame F+N), and its copy read at 560
nat pr-idle pr --frames 560 --report 20 --dump-domain RAM "$work/pr-idle.ram"
pictures="$(stream "$work/pr-idle.out" | awk '{print $7}' | sort -u | wc -l)"
check "c64:runs" "a program this script writes autostarts: it marked itself ($(od -An -c -j $((0xC030)) -N4 "$work/pr-idle.ram" | tr -d ' ')) and counted $(count "$work/pr-idle.ram") frames by frame 560, with $pictures different pictures in 28 reports" \
	[ "$(od -An -c -j $((0xC030)) -N4 "$work/pr-idle.ram" | tr -d ' ')" = C64T -a "$(count "$work/pr-idle.ram")" -gt 100 -a "$pictures" -gt 2 ]

held() { # held <name> <folder> <control>: the program run with one control held from 500
	nat "$1" "$2" --frames 560 --press "$(index "$2" "$3")":500:100 --dump-domain RAM "$work/$1.ram"
}
p2=""; p1=""
for d in Up Down Left Right Fire; do
	held "j1-$d" pr "P1 $d"; p2="$p2 $(byte "$work/j1-$d.ram" 2)"
	held "j2-$d" pr "P2 $d"; p1="$p1 $(byte "$work/j2-$d.ram" 3)"
done
check "c64:joystick" "P1's joystick in control port 2 and P2's in port 1, each direction and fire held alone, read as CIA 1's ports read them (up down left right fire): port 2:$p2, port 1:$p1 (fe fd fb f7 ef), none held $(byte "$work/pr-idle.ram" 2) $(byte "$work/pr-idle.ram" 3)" \
	[ "$p2" = " fe fd fb f7 ef" -a "$p1" = " fe fd fb f7 ef" -a "$(byte "$work/pr-idle.ram" 2)$(byte "$work/pr-idle.ram" 3)" = ffff ]
folder p1 '{"p1Port":"1"}' "$prog"
held p1up p1 "P1 Up"
held p1p2 p1 "P2 Up"
check "c64:p1-port" "with P1 Port set to 1, P1's joystick is read in port 1 ($(byte "$work/p1up.ram" 3); port 2 $(byte "$work/p1up.ram" 2)) and P2's in port 2 ($(byte "$work/p1p2.ram" 2))" \
	[ "$(byte "$work/p1up.ram" 3)$(byte "$work/p1up.ram" 2)$(byte "$work/p1p2.ram" 2)" = feff"fe" ]

# every key of the matrix, held alone, is the one bit of its row and column.
# The C64's matrix by the names on its keys, row by row (row 0 is CIA 1 port A
# bit 0), as the machine's documentation gives it; the core lists the keys as
# they sit on the keyboard instead (chimera#310), so each is found by its name.
matrix_cell() { # matrix_cell <key name>: "<row> <col>", or nothing
	awk -v want="$1" -F'|' '{ for (c = 1; c <= NF; c++) if ($c == want) { print NR - 1, c - 1; exit } }' <<'MATRIX'
Del|Return|Cursor Right|F7|F1|F3|F5|Cursor Down
3|W|A|4|Z|S|E|Left Shift
5|R|D|6|C|F|T|X
7|Y|G|8|B|H|U|V
9|I|J|0|M|K|O|N
+|P|L|-|.|:|@|,
Pound|*|;|Home|Right Shift|=|Up Arrow|/
1|Left Arrow|Ctrl|2|Space|C=|Q|Run/Stop
MATRIX
}
keysbad=""; nkeys=0
grep "^panel .*'Key " "$work/panel.out" | grep -v "'Key Restore'" > "$work/keys.txt"
while IFS= read -r line; do
	k="$(echo "$line" | awk '{print $2}')"
	name="$(echo "$line" | sed -n "s/^panel [0-9]* 'Key \([^']*\)'.*/\1/p")"
	cell="$(matrix_cell "$name")"
	if [ -z "$cell" ]; then keysbad="$keysbad $k($name: not in the matrix)"; nkeys=$((nkeys + 1)); continue; fi
	row="${cell% *}"; col="${cell#* }"
	nat key pr --frames 560 --press "$k":500:100 --dump-domain RAM "$work/key.ram"
	want=""
	for r in 0 1 2 3 4 5 6 7; do
		if [ $r -eq $row ]; then want="$want$(printf '%02x' $((255 - (1 << col))))"; else want="${want}ff"; fi
	done
	[ "$(bytes "$work/key.ram" 8 8)" = "$want" ] || keysbad="$keysbad $k"
	nkeys=$((nkeys + 1))
done < "$work/keys.txt"
nat rst pr --frames 560 --press "$(index pr "Key Restore")":500:10 --dump-domain RAM "$work/rst.ram"
nat rst2 pr --frames 560 --press "$(index pr "Key Restore")":480:10 --press "$(index pr "Key Restore")":520:10 --dump-domain RAM "$work/rst2.ram"
check "c64:keyboard" "each of the $nkeys keys of the matrix held alone is the one bit of its row and column in the program's scan${keysbad:+ (wrong: panel$keysbad)}; RESTORE pressed once gives one NMI ($(byte "$work/rst.ram" 4)), twice two ($(byte "$work/rst2.ram" 4)), none held $(byte "$work/pr-idle.ram" 4)" \
	[ -z "$keysbad" -a "$nkeys" = 64 -a "$(byte "$work/rst.ram" 4)$(byte "$work/rst2.ram" 4)$(byte "$work/pr-idle.ram" 4)" = 010200 ]

# lag: the program reads its controls every frame, its twin never does
nat q qu --frames 560 --report 20
lag460() { stream "$1" | awk '$2 == 460 {print $NF}'; }
check "c64:lag" "from frame 460 to 560 the program that reads its controls has no lag frame ($(lag460 "$work/pr-idle.out") then $(field "$work/pr-idle.out" lag)) and its twin that reads none has 100 ($(lag460 "$work/q.out") then $(field "$work/q.out" lag))" \
	[ "$(field "$work/pr-idle.out" lag)" = "$(lag460 "$work/pr-idle.out")" -a $(( $(field "$work/q.out" lag) - $(lag460 "$work/q.out") )) = 100 ]

# every kind of control in one run, native and sandbox, and with savestates
allrun="--frames 900 --report 10 --press $(index pr "P1 Up"):500:20 --press $(index pr "P1 Fire"):520:10 --press $(index pr "P2 Right"):540:10 --press $(index pr "Key A"):560:5 --press $(index pr "Key Restore"):600:5 --press $(index pr "Key Space"):620:30"
nat all pr $allrun
box all-box pr $allrun
box all-rerecord pr $allrun --rerecord
box all-session pr $allrun --session
for n in all all-box all-rerecord all-session pr-idle; do stream "$work/$n.out" > "$work/$n.stream"; done
nat all-idle pr --frames 900 --report 10
stream "$work/all-idle.out" > "$work/all-idle.stream"
check "c64:sandbox" "native and sandbox print the same $(wc -l < "$work/all.stream") digests of memory, picture and sound with every kind of control pressed, which change the run" \
	sh -c "cmp -s '$work/all.stream' '$work/all-box.stream' && ! cmp -s '$work/all.stream' '$work/all-idle.stream'"
check "c64:state-every-frame" "a state saved and loaded every frame changes nothing" same "$work/all-box.stream" "$work/all-rerecord.stream"
check "c64:state-other-box" "a state moved to a new sandbox half way changes nothing" same "$work/all-box.stream" "$work/all-session.stream"
box rewind pr --frames 1600 --report 5 --press "$(index pr "P1 Left")":700:900 --rewind
check "c64:state-rewind" "a state kept at frame 800 and loaded at 1200: the frames after the load repeat those after the save" \
	repeats "$work/rewind.out" 800 1200 400 5

# the clock: VICE's random numbers come from it (the power-on RAM pattern)
folder clk '{"initialTime":"1262304000"}' "$prog"
nat clk clk --frames 300 --report 10
box clk-box clk --frames 300 --report 10
nat clk-def pr --frames 300 --report 10
for n in clk clk-box clk-def; do stream "$work/$n.out" > "$work/$n.stream"; done
check "c64:clock" "with the Starting Clock on the first of January 2010 the run is another than with the default (VICE's random numbers come from it), and the sandbox gives the native build's digests" \
	sh -c "cmp -s '$work/clk.stream' '$work/clk-box.stream' && ! cmp -s '$work/clk.stream' '$work/clk-def.stream'"

# the disk: the program saves a file to the disk it came from; the disk
# comes out changed as save data, the user's file stays as it was
folder sv '{}' "$work/files/save.d64"
mkdir -p "$work/saved"
box sv sv --frames 1200 --dump-domain RAM "$work/sv.ram" --savedata-out "$work/saved"
check "c64:disk-write" "a program on a disk saves a file through the KERNAL (it says it went well: $(byte "$work/sv.ram" 5)); Export Save Data gives the disk, $(basename "$work/files/save.d64"), with the file OUT on it, closed (the 1541's track written back first); the user's file is unchanged" \
	python3 - "$work/files/save.d64" "$work/saved" "$(byte "$work/sv.ram" 5)" <<'PY'
import os, sys
orig, outdir, ok = open(sys.argv[1], "rb").read(), sys.argv[2], sys.argv[3]
files = os.listdir(outdir)
if ok != "01" or files != ["save.d64"]:
    sys.exit(1)
out = open(os.path.join(outdir, "save.d64"), "rb").read()
d = (sum([21] * 17) * 256) + 256          # track 18 sector 1: the directory
def files(img):  # (type, name) of each directory entry in use
    return [(img[d + 32 * i + 2], img[d + 32 * i + 5:d + 32 * i + 21].rstrip(b"\xa0")) for i in range(8) if img[d + 32 * i + 2]]
# OUT is there and closed (0x82, a PRG), beside TEST; the user's disk has TEST alone
sys.exit(0 if files(out) == [(0x82, b"TEST"), (0x82, b"OUT")] and files(orig) == [(0x82, b"TEST")] else 1)
PY

# a disk change: the program's save lands on the disk in the drive when it
# saves; Next Disk and Eject Disk put the second disk in before that
folder ch '{}' "$work/files/save.d64" "$work/files/other.d64"
mkdir -p "$work/ch-saved"
box ch ch --frames 1200 --press "$(index ch "Next Disk")":320:5 --press "$(index ch "Eject Disk")":340:20 --savedata-out "$work/ch-saved"
check "c64:disk-change" "with Next Disk and Eject Disk pressed before the program saves, the file goes to the second disk: Export Save Data gives $(ls "$work/ch-saved" | tr '\n' ' ')" \
	sh -c "[ \"\$(ls '$work/ch-saved')\" = other.d64 ]"

# ------------------------------------------------- what is refused
mkdir -p "$work/nogame"
printf '{"game":[]}' > "$work/nogame/slots"; printf '{}' > "$work/nogame/settings"
nat nogame nogame --frames 1
check "refused:no-game" "a C64 with no game is refused, and says so" grep -q "Init failed.*no game was given" "$work/nogame.out" "$work/nogame.err"

# ------------------------------------------------- Chimera's engine
runner="$chimera_root/build/dll/chimera-run"
package="$chimera_root/build/Cores/vice.chimeraCore"
if [ -n "$chimera_root" ] && [ -x "$runner" ] && [ -f "$package" ]; then
	mkdir -p "$work/proj"
	cp "$prog" "$work/proj/"
	python3 "$root/tests/make-project.py" "$package" "$work/proj/prog.chimeraProject" 600 \
		"press=P1 Up:499:20" "press=Key A:519:5" panel="$work/panel.out" -- game="$work/proj/test.prg" > /dev/null
	"$runner" --project "$work/proj/prog.chimeraProject" "$package" --files "$work/proj" --frames 600 \
		--dump "RAM=$work/engine.ram" > "$work/engine.log" 2>&1
	box eng pr --frames 600 --press "$(index pr "P1 Up")":500:20 --press "$(index pr "Key A")":520:5 --dump-domain RAM "$work/eng.ram"
	check "engine:c64" "a project of the program with presses plays in Chimera's headless runner to the sandbox runner's RAM ($(wc -c < "$work/eng.ram" 2> /dev/null) bytes, the program's count $(count "$work/engine.ram")), another than the idle run's" \
		sh -c "cmp -s '$work/engine.ram' '$work/eng.ram' && ! cmp -s '$work/engine.ram' '$work/pr-idle.ram'"
else
	report "engine:c64" SKIP "needs CHIMERA_ROOT with build/dll/chimera-run and build/Cores/vice.chimeraCore"
fi

# ------------------------------------------------- games
gamerun() { # gamerun <test> <what> <file>: boots, and native == sandbox with presses
	gr_t="$1"; gr_what="$2"; gr_f="$3"
	folder "$gr_t" '{}' "$gr_f"
	gr_run="--frames 2400 --report 50 --press $(index "$gr_t" "Key 1"):1400:10 --press $(index "$gr_t" "P1 Fire"):1700:20 --press $(index "$gr_t" "P1 Right"):1800:200"
	nat "$gr_t" "$gr_t" $gr_run
	box "$gr_t-box" "$gr_t" $gr_run
	box "$gr_t-rr" "$gr_t" $gr_run --rerecord
	for n in "$gr_t" "$gr_t-box" "$gr_t-rr"; do stream "$work/$n.out" > "$work/$n.stream"; done
	gr_pics="$(awk '{print $7}' "$work/$gr_t.stream" | sort -u | wc -l)"
	check "$gr_t" "$(basename "$gr_f") ($gr_what) $gr_pics different pictures in 48 reports; native and sandbox print the same digests with presses, and with a state saved and loaded every frame" \
		sh -c "[ $gr_pics -gt 3 ] && cmp -s '$work/$gr_t.stream' '$work/$gr_t-box.stream' && cmp -s '$work/$gr_t-box.stream' '$work/$gr_t-rr.stream'"
}
d64="$(ls "$diskgame"/*.d64 "$diskgame"/*.D64 2> /dev/null | head -1)"
if [ -n "$d64" ]; then gamerun game:disk "autostarted from its disk" "$d64"; else report game:disk SKIP "no game on disk (a .d64 in C64_DISK_GAME)"; fi
crt="$(ls "$cartgame"/*.crt 2> /dev/null | head -1)"
if [ -n "$crt" ]; then gamerun game:cartridge "a cartridge" "$crt"; else report game:cartridge SKIP "no cartridge (a .crt in C64_CART_GAME)"; fi
tap="$(ls "$tapegame"/*.tap 2> /dev/null | head -1)"
if [ -n "$tap" ]; then
	folder tp '{}' "$tap"
	nat tp tp --frames 12000 --report 250
	box tp-box tp --frames 12000 --report 250
	for n in tp tp-box; do stream "$work/$n.out" > "$work/$n.stream"; done
	check game:tape "$(basename "$tap") loads from the datasette ($(awk '{print $7}' "$work/tp.stream" | sort -u | wc -l) different pictures in 48 reports over 12,000 frames); native and sandbox print the same digests" \
		sh -c "[ \$(awk '{print \$7}' '$work/tp.stream' | sort -u | wc -l) -gt 3 ] && cmp -s '$work/tp.stream' '$work/tp-box.stream'"
else
	report game:tape SKIP "no game on tape (a .tap in C64_TAPE_GAME)"
fi

echo
echo "$ok passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
