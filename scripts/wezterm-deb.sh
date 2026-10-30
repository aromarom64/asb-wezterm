#!/bin/sh
# wezterm-deb.sh (make wezterm-deb): builds asb-wezterm_<v>_arm64.deb, upstream
# wezterm's CLI and mux server at build <v>, into dist/wezterm/<v>/. it compiles
# in a throwaway `container run` VM (scripts/wezterm-deb-vm.sh), installs the
# deb on a clean ubuntu:24.04, and only then writes the .sha256 and notes.md
# that publishing needs. env: BUILD (default: the host's `wezterm --version`),
# CPUS (6), MEMORY (8g), DNS (an IP for both runs' --dns=); long form in
# agent-sandbox's README section "The wezterm build".
set -eu
# bytewise ranges: in a UTF-8 locale macOS sh's [a-f] also matches A-F.
LC_ALL=C
export LC_ALL

die() {
	echo "wezterm-deb: $*" >&2
	exit 1
}

if [ -z "${BUILD:-}" ]; then
	command -v wezterm >/dev/null 2>&1 ||
		die "no BUILD given and no wezterm on PATH: set BUILD=<build>, e.g. BUILD=20261026-082628-e68a8ec2"
	BUILD=$(wezterm --version)
	BUILD=${BUILD#wezterm }
fi
v=$BUILD
case $v in
[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
*) die "BUILD '$v' is not a wezterm build string (YYYYMMDD-HHMMSS-<8 hex>)" ;;
esac
for t in container curl git shasum; do
	command -v "$t" >/dev/null 2>&1 || die "$t not found on PATH"
done

# every exit deletes the named run still in flight (the CLI forwards a Ctrl-C
# to the VM's PID 1, which defers it past its running command, and waits on),
# the scratch git dir, the VMs' script and the lock it took, each cleared once
# removed, since a signal's exit runs the EXIT trap again, whose second rmdir
# would exit 1.
run=
up=
snap=
lock=
cleanup() {
	if [ -n "$run" ]; then
		container delete --force "$run" >/dev/null 2>&1 || true
		run=
	fi
	[ -z "$up" ] || rm -rf "$up"
	[ -z "$snap" ] || rm -rf "$snap"
	[ -z "$lock" ] || rmdir "$lock"
	up=
	snap=
	lock=
}
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
dist=$root/dist/wezterm/$v
deb=asb-wezterm_${v}_arm64.deb

# real_dist [mk]: dist/ is git-ignored and an asb sandbox run in this checkout
# can write it, so each level down to $dist must be a directory, not a symlink
# aiming this script's removals and writes or a VM's /in at a host directory;
# mk first makes each missing level, never through a symlink.
real_dist() {
	for d in "$root/dist" "$root/dist/wezterm" "$dist"; do
		if [ -n "${1:-}" ] && [ ! -L "$d" ]; then
			mkdir -p "$d" || die "cannot make $d"
		fi
		[ -d "$d" ] && [ ! -L "$d" ] || die "$d is a symlink or not a directory: remove it, then rerun"
	done
}

real_dist mk
# held from before the upstream checks to the end, as wezterm-publish.sh holds
# it, so no publish of <v> runs between those checks and the clear and neither
# reads files the other replaces; a mkdir, as macOS has no flock(1).
mkdir "$dist/.lock" 2>/dev/null ||
	die "another wezterm-deb or wezterm-publish of $v holds $dist/.lock: wait for it, or rmdir it if none runs"
lock=$dist/.lock

# the commit and archive endpoints also resolve fork-only commits through the
# shared fork network, so the commit must also be on upstream main.
short=${v##*-}
api=https://api.github.com/repos/wezterm/wezterm
sha=$(curl -fsS -H 'Accept: application/vnd.github.sha' "$api/commits/$short") ||
	die "upstream wezterm has no commit $short (or api.github.com is unreachable)"
case $sha in
*[!0-9a-f]*) die "commit $short resolved to '$sha', not a sha" ;;
"$short"*) [ "${#sha}" -eq 40 ] || die "commit $short resolved to '$sha', not a 40-hex sha" ;;
*) die "commit $short resolved to '$sha', which does not start with $short" ;;
esac
compare=$(curl -fsS "$api/compare/$sha...main?per_page=1") ||
	die "cannot compare $sha with upstream main"
case $(printf '%s' "$compare" | tr -d ' \t\r\n') in
*'"status":"ahead"'* | *'"status":"identical"'*) ;;
*) die "commit $sha is not on upstream wezterm main (a fork-only commit?)" ;;
esac
# <v>'s time is upstream's tag name, the committer date at the committer's own
# UTC offset (git's %cd with --date=format:), which only the commit object
# holds, as the API gives UTC: a depth-1 treeless fetch brings that one object.
up=$(mktemp -d) || die "cannot make a scratch git dir"
git init -q --bare "$up"
git -C "$up" fetch -q --depth=1 --filter=tree:0 https://github.com/wezterm/wezterm.git "$sha" ||
	die "cannot fetch commit $sha from github.com/wezterm/wezterm"
ctime=$(GIT_NO_LAZY_FETCH=1 git -C "$up" log -1 --no-show-signature --format=%cd --date=format:%Y%m%d-%H%M%S "$sha") ||
	die "cannot read commit $sha's committer date"
rm -rf "$up"
up=
[ "$ctime" = "${v%-*}" ] || die "BUILD '$v' does not match commit $short, committed $ctime at its committer's UTC offset"

# tree_status: the checkout's git status, dist/ aside, since in a checkout that
# does not ignore dist/ the build's own outputs would read as a change.
tree_status() { git -C "$root" status --porcelain -- . ':(exclude)dist'; }
asb_head=$(git -C "$root" rev-parse HEAD) || die "$root is not a git checkout"
asb_rev=$(git -C "$root" rev-parse --short "$asb_head")
st=$(tree_status)
[ -z "$st" ] || asb_rev="$asb_rev dirty"
cpus=${CPUS:-6} memory=${MEMORY:-8g}
echo "wezterm-deb: building $v from wezterm/wezterm@$sha into $dist"
rm -f "$dist/$deb" "$dist/$deb.sha256" "$dist/notes.md" "$dist/build-info" "$dist/src.tar.gz"
rm -rf "$dist/build"
curl -fsSL -o "$dist/src.tar.gz" "https://github.com/wezterm/wezterm/archive/$sha.tar.gz"
src_sum=$(shasum -a 256 "$dist/src.tar.gz")
src_sum=${src_sum%% *}

# vm <name> <run args>...: one named `container run --rm`, in the background
# because a trapped signal ends a `wait` at once but a foreground run only
# when the run ends; dist/ is checked again first, as the build gives minutes
# to swap a symlink in.
vm() {
	real_dist
	run=$1
	shift
	container run --rm --name="$run" "$@" &
	wait "$!"
	run=
}

# the in-VM script runs as a file: piped over `container run -i` stdin it
# risks the 64 KiB wedge (agent-sandbox's root CLAUDE.md). it is a snapshot, a
# clean tree's read from $asb_head itself, so no edit or checkout during the
# build changes what notes.md's commit names.
snap=$(mktemp -d)
if [ -z "$st" ]; then
	git -C "$root" cat-file blob "$asb_head:scripts/wezterm-deb-vm.sh" >"$snap/wezterm-deb-vm.sh"
else
	cp "$here/wezterm-deb-vm.sh" "$snap/wezterm-deb-vm.sh"
fi
# the build VM, which runs every crate's build code as root, writes only into
# the empty $dist/build, since a symlink it left in $dist would aim this
# script's writes at a host file.
mkdir "$dist/build"
vm "asb-wezterm-build-$$" --cpus="$cpus" --memory="$memory" ${DNS:+"--dns=$DNS"} \
	--volume="$snap:/asb:ro" --volume="$dist:/in:ro" --volume="$dist/build:/out" \
	ubuntu:24.04 sh /asb/wezterm-deb-vm.sh build "$v" "$sha"
[ "$(cd "$dist/build" && find . -mindepth 1 -maxdepth 1 | sort | tr '\n' ' ')" = "./$deb ./build-info " ] ||
	die "the build run left other than $deb and build-info in $dist/build"
for f in "$deb" build-info; do
	[ -f "$dist/build/$f" ] && [ ! -L "$dist/build/$f" ] || die "the build run left $f as other than a regular file"
	mv "$dist/build/$f" "$dist/$f"
done
rmdir "$dist/build"

vm "asb-wezterm-smoke-$$" ${DNS:+"--dns=$DNS"} \
	--volume="$snap:/asb:ro" --volume="$dist:/in:ro" \
	ubuntu:24.04 sh /asb/wezterm-deb-vm.sh smoke "$v" "$sha"

# a clean build's notes name $asb_rev, and this script itself runs from the
# live tree, so that tree must still be $asb_head, unchanged.
if [ -z "$st" ]; then
	head_now=$(git -C "$root" rev-parse HEAD) || die "cannot re-read agent-sandbox's HEAD after the build"
	st_now=$(tree_status) || die "cannot re-read agent-sandbox's git status after the build"
	[ "$head_now" = "$asb_head" ] && [ -z "$st_now" ] ||
		die "agent-sandbox's checkout moved off $asb_rev or changed during the build: rebuild with it left alone"
fi

# info <key>: build-info's value of <key>, which must be one non-empty line,
# since a blank would reach the published release notes.
info() {
	[ "$(grep -c "^$1=" "$dist/build-info")" -eq 1 ] && [ "$(grep -c "^$1=." "$dist/build-info")" -eq 1 ] ||
		die "build-info has no single non-empty $1="
	sed -n "s/^$1=//p" "$dist/build-info"
}
codec=$(info codec)
rust=$(info rust)
vendored=$(info vendored)
crates=$(info crates)
wall=$(info wall)
peak_mib=$(info peak_mib)
(cd "$dist" && shasum -a 256 "$deb" >"$deb.sha256")
deb_sum=$(cut -d' ' -f1 "$dist/$deb.sha256")
cat >"$dist/notes.md" <<EOF
agent-sandbox's arm64 build of upstream wezterm's \`wezterm\` and \`wezterm-mux-server\`, without the GUI.

- upstream commit: https://github.com/wezterm/wezterm/commit/$sha
- source tarball: https://github.com/wezterm/wezterm/archive/$sha.tar.gz, sha256 $src_sum
- mux codec: $codec
- rust: $rust
- static C libraries from: $vendored
- third-party Rust crates: $crates, license texts in /usr/share/asb-wezterm/third-party-crates
- build VM: $cpus CPUs, $memory memory; cargo build wall time $wall, peak VM memory $peak_mib MiB
- agent-sandbox commit: $asb_rev
- deb sha256: $deb_sum
EOF
rm -f "$dist/build-info"
cat "$dist/notes.md"
echo "wezterm-deb: wrote $dist/$deb"
