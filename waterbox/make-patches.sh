#!/bin/sh
# Writes patches/ from the patched extern/vice tree: the reverse of
# apply-patches.sh. A patch is the tree's difference in a list of files. Edit
# the tree, run this, and apply-patches.sh must then say "already applied".
# A file is in ONE patch, whole.
set -eu
trap '' PIPE
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
tree="$root/extern/vice"

# name | files (space separated), in the order the patches apply
series='
0001-chimera-the-core-gives-the-controls|libretro/libretro-mapper.c
'

# a patch that did not change keeps its file (and its time: the test script
# asks whether the core is newer than its patches)
keep="$(mktemp -d)"
trap 'rm -rf "${keep:?}"' EXIT
cp -p "$root"/patches/*.patch "$keep"/ 2> /dev/null || true
rm -f "$root"/patches/*.patch
printf '%s\n' "$series" | grep '|' | while IFS='|' read -r name files; do
	# shellcheck disable=SC2086
	git -C "$tree" diff -- $files > "$root/patches/$name.patch"
	if cmp -s "$root/patches/$name.patch" "$keep/$name.patch"; then
		cp -p "$keep/$name.patch" "$root/patches/$name.patch"
	fi
	echo "$name.patch: $(grep -c '^diff --git' "$root/patches/$name.patch") files"
done
# a changed file no patch names would be lost by a fresh clone
left="$(git -C "$tree" status --porcelain | wc -l)"
named="$(cat "$root"/patches/*.patch | grep -c '^diff --git')"
[ "$left" -eq "$named" ] || { echo "extern/vice has $left changed files and the patches name $named: add the rest to the series" >&2; exit 1; }
