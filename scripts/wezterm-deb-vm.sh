#!/bin/sh
# wezterm-deb-vm.sh: the in-VM half of scripts/wezterm-deb.sh, run as root in a
# throwaway ubuntu:24.04 VM with the dist dir at /out.
#   build <v> <sha>  compile wezterm and wezterm-mux-server from /out/src.tar.gz,
#                    check the staged binaries, write /out/build-info and then
#                    /out/asb-wezterm_<v>_arm64.deb
#   smoke <v>        install that deb on a clean VM and repeat the checks
# any failed check exits non-zero before a deb is written.
set -eu

# the toolchain every release is built with; notes.md records it.
rust=1.99.1
maint='aromarom64 <aromarom64@users.noreply.github.com>'
min_free_gb=10
export DEBIAN_FRONTEND=noninteractive

die() {
	echo "wezterm-deb-vm: $*" >&2
	exit 1
}

# one <path>...: prints its only argument, an existing path; a glob that
# matched nothing or several paths dies.
one() {
	[ "$#" -eq 1 ] && [ -e "$1" ] || die "want exactly one match, found: $*"
	printf '%s\n' "$1"
}

# check_wezterm <v>: the wezterm on PATH reports build <v>, the mux server is
# there and the GUI is not.
check_wezterm() {
	got=$(wezterm --version)
	[ "$got" = "wezterm $1" ] || die "wezterm reports '$got', want 'wezterm $1'"
	command -v wezterm-mux-server >/dev/null || die "no wezterm-mux-server on PATH"
	! command -v wezterm-gui >/dev/null || die "wezterm-gui is on PATH"
}

# check_version_file <file> <v>: the build= and codec= lines asb-wezpair reads.
check_version_file() {
	grep -qx "build=$2" "$1" || die "$1 lacks build=$2"
	grep -qx 'codec=[0-9][0-9]*' "$1" || die "$1 lacks a numeric codec="
}

# probe_codec: prints the mux codec of the wezterm on PATH. no binary prints
# it, so it is read from the trace of a handshake between two private mux
# servers; the proxy_command's bare `wezterm` is why the binaries go on PATH.
probe_codec() {
	d=$(mktemp -d)
	printf 'return {unix_domains={{name="a",socket_path="%s/a"}}}' "$d" >"$d/a.lua"
	printf 'return {unix_domains={{name="b",socket_path="%s/b"},{name="p",socket_path="%s/p",proxy_command={"env","WEZTERM_UNIX_SOCKET=%s/a","wezterm","cli","--no-auto-start","proxy"}}}}' \
		"$d" "$d" "$d" >"$d/b.lua"
	HOME=$d wezterm-mux-server --config-file="$d/a.lua" -- sleep 60 >/dev/null 2>&1 &
	a=$!
	HOME=$d WEZTERM_LOG=wezterm_client=trace \
		wezterm-mux-server --config-file="$d/b.lua" -- sleep 60 >/dev/null 2>"$d/log" &
	b=$!
	for _ in $(seq 100); do
		[ -S "$d/a" ] && [ -S "$d/b" ] && break
		sleep 0.1
	done
	HOME=$d WEZTERM_UNIX_SOCKET=$d/b timeout 30 \
		wezterm cli --no-auto-start spawn --new-window --domain-name=p -- true >/dev/null ||
		echo "wezterm-deb-vm: codec probe: spawn through the proxy failed" >&2
	codec=$(sed -n 's/.*(codec version \([0-9][0-9]*\)).*/\1/p' "$d/log" | head -n1)
	kill "$a" "$b" 2>/dev/null || true
	wait "$a" "$b" || true
	[ -n "$codec" ] || { tail -n 20 "$d/log" >&2; die "codec probe: no codec version in the trace"; }
	rm -rf "$d"
	printf '%s\n' "$codec"
}

# sample_peak: records the VM's peak used memory (MemTotal - MemAvailable) in
# KiB to /tmp/peak-kb once a second; GNU time's max RSS is one process only.
sample_peak() {
	peak=0
	while :; do
		used=$(awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2} END {print t - a}' /proc/meminfo)
		if [ "$used" -gt "$peak" ]; then
			peak=$used
			echo "$peak" >/tmp/peak-kb
		fi
		sleep 1
	done
}

# text <file>: a license file as a deb822 continuation, blank lines as " .".
text() {
	[ -s "$1" ] || die "license file missing or empty: $1"
	sed 's/^[[:space:]]*$/./; s/^/ /' "$1"
}

# section <files> <license> <text-file>...: one Files paragraph of the Debian
# copyright file, its license texts separated by " .".
section() {
	files=$1 license=$2
	shift 2
	printf '\nFiles: %s\nCopyright: see the license text\nLicense: %s\n' "$files" "$license"
	sep=
	for f in "$@"; do
		[ -z "$sep" ] || echo "$sep"
		sep=' .'
		text "$f"
	done
}

# write_copyright <sha> <built>: upstream's LICENSE.md, then one paragraph per
# vendored C library in <built> (the crates whose build left a static archive);
# an archive from a crate with no entry here fails, so nothing ships unlicensed.
write_copyright() {
	cat <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: wezterm
Upstream-Contact: https://github.com/wezterm/wezterm
Source: https://github.com/wezterm/wezterm/tree/$1
Comment: wezterm and wezterm-mux-server built from that commit, with the C
 libraries of the paragraphs after the first linked in statically; each text
 is copied from the source the build compiled.
 The Rust crates and their license texts: /usr/share/asb-wezterm/third-party-crates
EOF
	section '*' MIT /build/LICENSE.md
	for c in $2; do
		[ "$c" = mlua-sys ] || d=$(one "$CARGO_HOME"/registry/src/*/"$c"-[0-9]*)
		case $c in
		libssh-rs-sys)
			section "${d##*/}/vendored/*" 'LGPL-2.1 and BSD-2-Clause' "$d/vendored/COPYING" "$d/vendored/BSD"
			;;
		libssh2-sys) section "${d##*/}/libssh2/*" BSD-3-Clause "$d/libssh2/COPYING" ;;
		libgit2-sys) section "${d##*/}/libgit2/*" 'GPL-2 with linking exception' "$d/libgit2/COPYING" ;;
		libz-sys) section "${d##*/}/src/zlib/*" Zlib "$d/src/zlib/LICENSE" ;;
		zstd-sys) section "${d##*/}/zstd/*" BSD-3-Clause "$d/zstd/LICENSE" ;;
		mlua-sys)
			# mlua-sys compiles lua-src's Lua 5.4, whose license ends lua.h.
			find /build/target/release/build/mlua-sys-*/out -name 'liblua5.4.a' | grep -q . ||
				die "mlua-sys built no liblua5.4.a: update the Lua entry"
			d=$(one "$CARGO_HOME"/registry/src/*/lua-src-[0-9]*)
			h=$(one "$d"/lua-5.4.*/lua.h)
			sed -n '/^\* Copyright (C) 1994-/,/^\*\*\*\*\*/p' "$h" | sed '$d; s/^\* \{0,1\}//' >/tmp/lua-license
			l=${h%/lua.h}
			section "${d##*/}/${l##*/}/*" MIT /tmp/lua-license
			;;
		ring)
			section "${d##*/}/*" 'ISC and Apache-2.0' "$d/LICENSE" "$d/LICENSE-other-bits" \
				"$d/LICENSE-BoringSSL" "$d/third_party/fiat/LICENSE"
			;;
		*) die "$c built a static C library with no license entry: add one to write_copyright" ;;
		esac
	done
}

# allows_mit <spdx>: <spdx> is MIT alone or an OR list (or the old a/b form)
# offering MIT, so the MIT text alone satisfies it.
allows_mit() {
	case $1 in *AND* | *WITH* | *'('*) return 1 ;; esac
	case " $(printf '%s' "$1" | sed 's|/| OR |g') OR " in *' MIT OR '*) return 0 ;; esac
	return 1
}

# mit_text: the SPDX MIT text without its copyright line, which such a crate lacks.
mit_text() {
	cat <<'EOF'
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
}

# notices <v> <file>: writes the third-party crates file and sets crates to
# the number listed. the graph is the locked closure of the two packages from
# resolve.nodes (dev edges dropped); a compiled package missing from it, or a
# crate with no license file whose license does not offer MIT, fails.
notices() {
	cargo metadata --locked --format-version=1 --filter-platform=aarch64-unknown-linux-gnu >/tmp/meta.json
	jq -r '
		(.resolve.nodes | map({key: .id, value: [.deps[] | select(any(.dep_kinds[]; .kind != "dev")) | .pkg]})
			| from_entries) as $deps
		| def closure: . as $s | ($s + [$s[] | $deps[.][]] | unique)
			| if length == ($s | length) then . else closure end;
		[.packages[] | select(.source == null and (.name == "wezterm" or .name == "wezterm-mux-server")) | .id] as $roots
		| if ($roots | length) == 2 then . else error("want wezterm and wezterm-mux-server, found \($roots)") end
		| ($roots | closure) as $ids
		| .packages[] | select(.id | IN($ids[]))
		| [.name, .version, (if .source != null or (.license // "MIT") != "MIT" then "y" else "n" end),
			(.source // "the wezterm workspace"), (.license_file // "-"), (.manifest_path | rtrimstr("/Cargo.toml")),
			(.license // (if .license_file then "license-file \(.license_file)" else "-" end)),
			(.authors | join(", ") | if . == "" then "-" else . end)] | @tsv
	' /tmp/meta.json >/tmp/crates
	fp=/build/target/release/.fingerprint
	find "$fp" -mindepth 1 -maxdepth 1 -type d | sed 's|.*/||; s/-[0-9a-f]\{16\}$//' | LC_ALL=C sort -u >/tmp/compiled
	# the pipeline hides a find failure, so an empty or unparsed list fails here.
	grep -qx wezterm-mux-server /tmp/compiled || die "$fp names no wezterm-mux-server: cannot check for omissions"
	cut -f1 /tmp/crates | LC_ALL=C sort -u >/tmp/graph
	miss=$(LC_ALL=C comm -23 /tmp/compiled /tmp/graph | tr '\n' ' ')
	[ -z "$miss" ] || die "compiled but missing from the crate graph: $miss"

	tab=$(printf '\t')
	crates=0
	while IFS=$tab read -r name ver list src lf dir lic auth; do
		[ "$list" = y ] || continue
		crates=$((crates + 1))
		printf '\n==== %s %s ====\nLicense: %s\nSource: %s\n' "$name" "$ver" "$lic" "$src"
		{
			[ "$lf" = - ] || printf '%s\n' "$dir/$lf"
			find "$dir" -maxdepth 1 -type f \( -iname 'licen[cs]e*' -o -iname 'copying*' \
				-o -iname 'notice*' -o -iname 'unlicense*' -o -iname 'copyright*' \)
		} | LC_ALL=C sort -u >/tmp/license-files
		if [ ! -s /tmp/license-files ]; then
			allows_mit "$lic" || die "$name $ver ships no license file and '$lic' does not offer MIT: bundle its text"
			printf '\n---- no license file in the crate (Cargo.toml authors: %s); the MIT License text ----\n\n' "$auth"
			mit_text
			continue
		fi
		while read -r f; do
			[ -s "$f" ] || die "$name $ver: license file missing or empty: $f"
			printf '\n---- %s ----\n\n' "${f#"$dir"/}"
			cat "$f"
		done </tmp/license-files
	done </tmp/crates >/tmp/notices-body
	cat - /tmp/notices-body >"$2" <<EOF
asb-wezterm $1: third-party Rust crates

The crates in the locked dependency graph of upstream wezterm's wezterm and
wezterm-mux-server packages for aarch64-unknown-linux-gnu, each with the
license its Cargo.toml declares and the license files it ships, copied from
the sources this build compiled. The graph takes normal and build dependencies
with the features the whole workspace enables, so it also names crates that
run only at build time or that the two binaries do not use.

The wezterm workspace's own crates are covered by upstream's LICENSE.md (MIT),
the first paragraph of /usr/share/doc/asb-wezterm/copyright, and are listed
here only when their Cargo.toml declares more than MIT. The C libraries some
crates compile in have their own paragraphs in that file.

A crate that ships no license file is followed by the standard MIT License
text, which its declared license offers.

$crates crates.
EOF
}

build() {
	v=$1 sha=$2
	[ "$(dpkg --print-architecture)" = arm64 ] || die "not an arm64 VM"
	apt-get update --error-on=any
	apt-get install -y --no-install-recommends build-essential pkg-config libssl-dev \
		dpkg-dev curl ca-certificates time jq

	# dash has no pipefail, so rustup-init is checked as a file, not piped.
	CARGO_HOME=/root/.cargo RUSTUP_HOME=/root/.rustup
	export CARGO_HOME RUSTUP_HOME
	mkdir /tmp/rustup
	cd /tmp/rustup
	u=https://static.rust-lang.org/rustup/dist/aarch64-unknown-linux-gnu/rustup-init
	curl -fsSL -o rustup-init "$u"
	curl -fsSL -o rustup-init.sha256 "$u.sha256"
	sha256sum -c rustup-init.sha256
	chmod 0755 rustup-init
	./rustup-init -y --no-modify-path --profile=minimal --default-toolchain="$rust"
	PATH=$CARGO_HOME/bin:$PATH

	# target/ and the registry stay on the VM's disk: under /out they would
	# cross virtiofs into the repo tree.
	free_kb=$(df -Pk / | awk 'NR == 2 {print $4}')
	[ "$free_kb" -ge $((min_free_gb * 1024 * 1024)) ] ||
		die "$((free_kb / 1024 / 1024)) GiB free on /, need $min_free_gb"
	top=$(tar -tzf /out/src.tar.gz | sed -n 1p)
	[ "$top" = "wezterm-$sha/" ] || die "src.tar.gz top dir is '$top', want 'wezterm-$sha/'"
	mkdir /build
	tar -xzf /out/src.tar.gz -C /build --strip-components=1
	printf '%s\n' "$v" >/build/.tag
	cd /build

	sample_peak &
	sp=$!
	trap 'kill "$sp" 2>/dev/null || true' EXIT
	/usr/bin/time -v -o /tmp/time.txt cargo build --release --locked -p wezterm -p wezterm-mux-server
	kill "$sp" 2>/dev/null || true
	wall=$(sed -n 's/^[[:space:]]*Elapsed (wall clock) time (h:mm:ss or m:ss): //p' /tmp/time.txt)
	peak_mib=$(($(cat /tmp/peak-kb) / 1024))

	pkg=/build/pkg
	bin=$pkg/debian/usr/bin
	install -D -s -m 0755 -t "$bin" target/release/wezterm target/release/wezterm-mux-server
	PATH=$bin:$PATH
	[ "$(command -v wezterm)" = "$bin/wezterm" ] || die "the staged wezterm is not first on PATH"
	check_wezterm "$v"
	codec=$(probe_codec)
	want=$(sed -n 's/^pub const CODEC_VERSION: usize = \([0-9][0-9]*\);$/\1/p' codec/src/lib.rs)
	[ -n "$want" ] || die "no CODEC_VERSION in codec/src/lib.rs"
	[ "$codec" = "$want" ] || die "staged binaries speak codec $codec, the source says $want"

	built=$(find target/release/build -path '*/out/*' -name '*.a' |
		sed 's|^target/release/build/||; s|/.*||; s|-[0-9a-f]\{16\}$||' | LC_ALL=C sort -u | tr '\n' ' ')
	built=${built% }
	echo "wezterm-deb-vm: static C libraries from: $built"
	install -d "$pkg/debian/DEBIAN" "$pkg/debian/usr/share/asb-wezterm" "$pkg/debian/usr/share/doc/asb-wezterm"
	printf 'build=%s\ncodec=%s\n' "$v" "$codec" >"$pkg/debian/usr/share/asb-wezterm/wezterm-version"
	check_version_file "$pkg/debian/usr/share/asb-wezterm/wezterm-version" "$v"
	write_copyright "$sha" "$built" >"$pkg/debian/usr/share/doc/asb-wezterm/copyright"
	# outside /usr/share/doc, which ubuntu:24.04's dpkg excludes cut to copyright and changelogs.
	notices "$v" "$pkg/debian/usr/share/asb-wezterm/third-party-crates"
	echo "wezterm-deb-vm: license notices for $crates crates"

	# dpkg-shlibdeps reads debian/control from its cwd and needs a Source
	# field, which the binary control drops: upstream's ci/deploy.sh layout.
	cat >"$pkg/debian/control" <<EOF
Source: asb-wezterm
Package: asb-wezterm
Version: $v
Architecture: arm64
Maintainer: $maint
Conflicts: wezterm, wezterm-nightly
Section: utils
Priority: optional
Homepage: https://github.com/aromarom64/asb-wezterm
Description: wezterm CLI and mux server, without the GUI
 agent-sandbox's arm64 build of upstream wezterm's wezterm and
 wezterm-mux-server at commit $sha.
EOF
	out=$(cd "$pkg" && dpkg-shlibdeps -O -e debian/usr/bin/*)
	deps=$(printf '%s\n' "$out" | sed -n 's/^shlibs:Depends=//p')
	[ -n "$deps" ] || die "dpkg-shlibdeps printed no Depends: $out"
	mv "$pkg/debian/control" "$pkg/debian/DEBIAN/control"
	sed -i '/^Source:/d' "$pkg/debian/DEBIAN/control"
	printf 'Depends: %s\n' "$deps" >>"$pkg/debian/DEBIAN/control"
	cat "$pkg/debian/DEBIAN/control"

	deb=asb-wezterm_${v}_arm64.deb
	dpkg-deb --root-owner-group --build "$pkg/debian" "$pkg/$deb"
	files=$(dpkg-deb --fsys-tarfile "$pkg/$deb" | tar -t | grep -v '/$' | LC_ALL=C sort | tr '\n' ' ')
	[ "$files" = "./usr/bin/wezterm ./usr/bin/wezterm-mux-server ./usr/share/asb-wezterm/third-party-crates ./usr/share/asb-wezterm/wezterm-version ./usr/share/doc/asb-wezterm/copyright " ] ||
		die "unexpected deb payload: $files"

	cat >/out/build-info <<EOF
rust=$(rustc -V)
codec=$codec
wall=$wall
peak_mib=$peak_mib
vendored=$built
crates=$crates
EOF
	cp "$pkg/$deb" "/out/$deb"
}

smoke() {
	v=$1
	cd /out
	apt-get update --error-on=any
	apt-get install -y --no-install-recommends "./asb-wezterm_${v}_arm64.deb"
	[ "$(command -v wezterm)" = /usr/bin/wezterm ] || die "wezterm is not the deb's /usr/bin/wezterm"
	check_wezterm "$v"
	check_version_file /usr/share/asb-wezterm/wezterm-version "$v"
	test -s /usr/share/doc/asb-wezterm/copyright || die "the deb installed no copyright"
	test -s /usr/share/asb-wezterm/third-party-crates || die "the deb installed no third-party-crates"
}

case ${1:-} in
build) [ "$#" -eq 3 ] || die "usage: build <v> <sha>"; build "$2" "$3" ;;
smoke) [ "$#" -eq 2 ] || die "usage: smoke <v>"; smoke "$2" ;;
*) die "usage: wezterm-deb-vm.sh build <v> <sha> | smoke <v>" ;;
esac
