# asb-wezterm

arm64 Debian packages of upstream [wezterm](https://github.com/wezterm/wezterm)'s
command-line `wezterm` and `wezterm-mux-server`, without the GUI, built for the
`asb-core` image of agent-sandbox.

They exist because upstream's linux/arm64 nightly packages stopped at
2026-01-17 ([wezterm/wezterm#7716](https://github.com/wezterm/wezterm/issues/7716)),
and a wezterm client and mux server only talk to each other when they speak the
same mux codec. Each package is built from the upstream commit of the wezterm
on the agent-sandbox host, so the sandbox's mux server speaks the host's codec.

## Package

- name `asb-wezterm`, architecture `arm64`
- file `asb-wezterm_<build>_arm64.deb`, where `<build>` is the upstream build
  string `wezterm --version` prints, e.g. `20261026-082628-e68a8ec2`
- contents: `/usr/bin/wezterm` and `/usr/bin/wezterm-mux-server` (stripped),
  `/usr/share/asb-wezterm/wezterm-version` (`build=` and `codec=` lines),
  `/usr/share/asb-wezterm/third-party-crates` (the Rust crates' license
  notices) and `/usr/share/doc/asb-wezterm/copyright`; no `wezterm-gui`, no
  X11, Wayland or fontconfig dependencies
- `Conflicts: wezterm, wezterm-nightly`; `Depends` comes from `dpkg-shlibdeps`
  (for `20261026-082628-e68a8ec2`: `libc6`, `libgcc-s1`, `libssl3t64`)
- built on `ubuntu:24.04` and test-installed on a clean `ubuntu:24.04`

```
apt-get install --no-install-recommends ./asb-wezterm_<build>_arm64.deb
```

## Releases

Each release is tagged with the upstream build string and has one asset, the
deb. Releases are immutable (GitHub's immutable releases are on for this
repository): once published, a release's tag and asset never change, and no
build is ever re-uploaded. A rebuild of the same commit gives different bytes,
so a sha256 pin on a release holds only because its asset never changes.

Each release's notes record:

- the upstream commit, and the source tarball's URL and sha256
- the mux codec
- the Rust version
- the crates whose C libraries are linked in statically
- the build VM's CPUs and memory, the cargo wall time and the peak VM memory
- the agent-sandbox commit the build scripts came from
- the deb's sha256

To check a downloaded deb against its release, verify it with `gh` and compare
its sha256 with the `deb sha256` line of the release notes:

```
gh release verify-asset <build> asb-wezterm_<build>_arm64.deb --repo=aromarom64/asb-wezterm
shasum -a 256 asb-wezterm_<build>_arm64.deb
```

## Building

`scripts/` holds copies of agent-sandbox's two build scripts:
`wezterm-deb.sh` runs on the host and `wezterm-deb-vm.sh` runs inside the
build VM. They need an Apple silicon Mac with Apple's
[`container`](https://github.com/apple/container) CLI, plus `curl`, `git` and
`shasum`, and network access to GitHub, the Ubuntu archive,
static.rust-lang.org and crates.io. Run them from a git checkout:

```
BUILD=20261026-082628-e68a8ec2 sh scripts/wezterm-deb.sh
```

Environment variables:

- `BUILD`: the upstream build string; defaults to the host's `wezterm --version`.
  Its commit must be on upstream `main`.
- `CPUS`: the build VM's CPUs (default `6`)
- `MEMORY`: the build VM's memory (default `8g`)
- `DNS`: an IP address both VMs use as their DNS server, for a network whose
  default resolver does not work

The driver downloads the upstream source tarball of that commit into
`dist/wezterm/<build>/`, compiles both binaries in a throwaway `ubuntu:24.04`
VM with the Rust version pinned in `wezterm-deb-vm.sh`, checks the binaries'
version and mux codec, packages the deb, installs it on a second clean
`ubuntu:24.04` VM, and only then writes the deb's `.sha256` and `notes.md`
beside it. The `agent-sandbox commit` line in `notes.md` names the HEAD of
the checkout the scripts ran from, with `dirty` appended when it had
uncommitted changes. At the defaults a build takes about four minutes, two of
them in cargo, and peaks under 2 GiB of VM memory.

## Licenses

wezterm is MIT licensed (upstream `LICENSE.md`). The binaries also link these
C libraries statically, compiled from the sources their Rust crates vendor:

| library | crate | license |
|---|---|---|
| libssh | `libssh-rs-sys` | LGPL-2.1 and BSD-2-Clause |
| libssh2 | `libssh2-sys` | BSD-3-Clause |
| libgit2 | `libgit2-sys` | GPL-2 with linking exception |
| zlib | `libz-sys` | Zlib |
| zstd | `zstd-sys` | BSD-3-Clause |
| Lua 5.4 | `lua-src` (via `mlua-sys`) | MIT |
| ring | `ring` | ISC and Apache-2.0 |

Each deb's `/usr/share/doc/asb-wezterm/copyright` carries upstream's license
and the full license text of each of these libraries, copied from the sources
that build compiled.

The Rust crates compiled into the binaries are in each deb's
`/usr/share/asb-wezterm/third-party-crates`: every crate outside the wezterm
workspace in the locked dependency graph of `wezterm` and
`wezterm-mux-server`, build-time ones included, plus the workspace crates
whose license goes beyond upstream's MIT, each with its version, the license
its `Cargo.toml` declares and the license files it ships, copied from the
sources that build compiled. A crate that ships no license file, and whose
license offers MIT, is followed by the MIT License text. The file sits outside
`/usr/share/doc`, which minimal Ubuntu images cut to its `copyright` and
changelog files on install.

The build scripts in `scripts/` are MIT licensed (see `LICENSE`).
