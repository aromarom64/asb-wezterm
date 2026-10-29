#!/bin/sh
# wezterm-deb.sh (make wezterm-deb): builds asb-wezterm_<v>_arm64.deb, upstream
# wezterm's CLI and mux server at build <v>, into dist/wezterm/<v>/. it compiles
# in a throwaway `container run` VM (scripts/wezterm-deb-vm.sh), installs the
# deb on a clean ubuntu:24.04, and only then writes the .sha256 and notes.md
# that publishing needs. env: BUILD (default: the host's `wezterm --version`),
# CPUS (6), MEMORY (8g), DNS (an IP for both runs' --dns=); long form in the
# README section "The wezterm build".
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
cmp=$(curl -fsS "$api/compare/$sha...main?per_page=1") ||
	die "cannot compare $sha with upstream main"
case $(printf '%s' "$cmp" | tr -d ' \t\r\n') in
*'"status":"ahead"'* | *'"status":"identical"'*) ;;
*) die "commit $sha is not on upstream wezterm main (a fork-only commit?)" ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
asb=$(git -C "$root" rev-parse --short HEAD) || die "$root is not a git checkout"
st=$(git -C "$root" status --porcelain)
[ -z "$st" ] || asb="$asb dirty"
dist=$root/dist/wezterm/$v
deb=asb-wezterm_${v}_arm64.deb
echo "wezterm-deb: building $v from wezterm/wezterm@$sha into $dist"
mkdir -p "$dist"
rm -f "$dist/$deb" "$dist/$deb.sha256" "$dist/notes.md" "$dist/build-info"
curl -fsSL -o "$dist/src.tar.gz" "https://github.com/wezterm/wezterm/archive/$sha.tar.gz"
src_sum=$(shasum -a 256 "$dist/src.tar.gz" | cut -d' ' -f1)

# every exit deletes the named run still in flight: the CLI forwards a Ctrl-C
# to the VM's PID 1, which defers it past its running command, and waits on.
run=
cleanup() {
	if [ -n "$run" ]; then
		container delete --force "$run" >/dev/null 2>&1 || true
		run=
	fi
}
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# vm <name> <run args>...: one named `container run --rm`, in the background
# because a trapped signal ends a `wait` at once but a foreground run only
# when the run ends.
vm() {
	run=$1
	shift
	container run --rm --name="$run" "$@" &
	wait "$!"
	run=
}

# the in-VM script runs as a file: piped over `container run -i` stdin it
# risks the 64 KiB wedge (root CLAUDE.md).
vm "asb-wezterm-build-$$" --cpus="${CPUS:-6}" --memory="${MEMORY:-8g}" ${DNS:+"--dns=$DNS"} \
	--volume="$here:/asb:ro" --volume="$dist:/out" \
	ubuntu:24.04 sh /asb/wezterm-deb-vm.sh build "$v" "$sha"
[ -f "$dist/$deb" ] && [ -f "$dist/build-info" ] || die "the build run left no deb or build-info in $dist"

vm "asb-wezterm-smoke-$$" ${DNS:+"--dns=$DNS"} \
	--volume="$here:/asb:ro" --volume="$dist:/out:ro" \
	ubuntu:24.04 sh /asb/wezterm-deb-vm.sh smoke "$v"

info() { sed -n "s/^$1=//p" "$dist/build-info"; }
codec=$(info codec)
case $codec in '' | *[!0-9]*) die "build-info has no numeric codec: '$codec'" ;; esac
(cd "$dist" && shasum -a 256 "$deb" >"$deb.sha256")
deb_sum=$(cut -d' ' -f1 "$dist/$deb.sha256")
cat >"$dist/notes.md" <<EOF
agent-sandbox's arm64 build of upstream wezterm's \`wezterm\` and \`wezterm-mux-server\`, without the GUI.

- upstream commit: https://github.com/wezterm/wezterm/commit/$sha
- source tarball: https://github.com/wezterm/wezterm/archive/$sha.tar.gz, sha256 $src_sum
- mux codec: $codec
- rust: $(info rust)
- static C libraries from: $(info vendored)
- third-party Rust crates: $(info crates), license texts in /usr/share/asb-wezterm/third-party-crates
- build VM: ${CPUS:-6} CPUs, ${MEMORY:-8g} memory; cargo build wall time $(info wall), peak VM memory $(info peak_mib) MiB
- agent-sandbox commit: $asb
- deb sha256: $deb_sum
EOF
rm -f "$dist/build-info"
cat "$dist/notes.md"
echo "wezterm-deb: wrote $dist/$deb"
