#!/bin/bash
# shellcheck disable=SC2024  # logs belong to the user: sudo's output is redirected as that user
# Build the Proxmox VE packages for Devuan (sysvinit/OpenRC) from the
# repositories in the current directory, as cloned by prepare-build.sh, into the
# local repository repo/, in dependency order (see openrc-devuan.md, Part C).
#
# Building installs build dependencies, including packages built here (e.g.
# pve-cluster, whose daemon pmxcfs needs the hostname to resolve to a
# non-loopback address). Two dependency cycles are bootstrapped by installing
# one package with dpkg --force-depends, fixed up by apt after the build:
#   pve-cluster: its build needs libpve-access-control, which depends on it
#   pve-network: its build needs pve-firewall, which depends on it
#
# Usage: build.sh [--from <step>] [--only <step>] [--install] [--list]
#   --from <step>  start at this step (e.g. to resume after a failure)
#   --only <step>  build only this step
#   --install      install pve-manager (and so everything) afterwards
#   --list         list the steps
#
# Versions come from the repositories' debian/changelog (+devuan<N>); bump them
# for a rebuild with changes, apt doesn't replace a package with another one of
# the same version. Logs: build-logs/<repo>.log and build-logs/build.log.

set -euo pipefail

BASE=$(pwd)
R=$BASE/repo
BUILD_REPO=$R/build-repo.sh
LOG=$BASE/build-logs/build.log
NPROC=$(nproc)

STEPS=(
    libpve-rs-perl pve-common pve-qemu pve-cluster pve-firewall pve-network
    pve-storage ifupdown2 lxc pve-lxc-syscalld pve-ha-manager qemu-server
    pve-container pve-manager
)

FROM='' ONLY='' INSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM=$2; shift ;;
        --only) ONLY=$2; shift ;;
        --install) INSTALL=1 ;;
        --list) printf '%s\n' "${STEPS[@]}"; exit 0 ;;
        -h|--help) sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "unknown option '$1', see --help" >&2; exit 2 ;;
    esac
    shift
done
for s in "$FROM" "$ONLY"; do
    if [ -n "$s" ] && ! printf '%s\n' "${STEPS[@]}" | grep -qxF "$s"; then
        echo "unknown step '$s', see --list" >&2; exit 2
    fi
done

mkdir -p "$BASE/build-logs" "$BASE/build"
info() { printf '\n=== %s\n' "$*" | tee -a "$LOG"; }
die() { echo "ERROR: $*" | tee -a "$LOG" >&2; exit 1; }

[ -x "$BUILD_REPO" ] || die "$BUILD_REPO missing, run prepare-build.sh first"

refresh_repo() {
    "$R/update-index.sh"
    sudo apt-get update -q >/dev/null || die "apt-get update failed"
}

# The packages prepare-build.sh fetched from Proxmox into repo/ must be visible
# to apt, or the builds fail on missing build dependencies.
check_fetched() {
    local prepare missing=() p
    prepare=$(dirname "$(readlink -f "$0")")/prepare-build.sh
    [ -f "$prepare" ] || die "$prepare missing"
    mapfile -t fetched < <(bash -c 'f=$1; set --; source "$f" >/dev/null; printf "%s\n" "${PROXMOX_PACKAGES[@]}"' _ "$prepare")
    [ ${#fetched[@]} -gt 0 ] || die "no package list in $prepare"
    for p in "${fetched[@]}"; do
        [ -n "$(apt-cache policy "$p" 2>/dev/null | sed -n 's/^ *Candidate: //p' | grep -v '(none)')" ] || missing+=("$p")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "not available to apt: ${missing[*]}; run prepare-build.sh again"
    fi
    echo "all ${#fetched[@]} packages from Proxmox available" | tee -a "$LOG"
}

# Dependencies from a control file's build dependencies (or a package's
# Depends), one per line, alternatives separated by '|'.
build_deps() { # <debian/control> <build profiles>
    DEB_BUILD_PROFILES="$2" perl -MDpkg::Control::Info -MDpkg::Deps -e '
        my $s = Dpkg::Control::Info->new($ARGV[0])->get_source;
        for my $f (qw(Build-Depends Build-Depends-Indep Build-Depends-Arch)) {
            my $d = deps_parse($s->{$f} // "", build_dep => 1,
                build_profiles => [split(/ /, $ENV{DEB_BUILD_PROFILES})], reduce_profiles => 1,
                reduce_arch => 1, host_arch => "amd64", build_arch => "amd64") or next;
            for my $x ($d->get_deps) {
                my @a = $x->isa("Dpkg::Deps::OR") ? $x->get_deps : ($x);
                print join("|", map { $_->{package} =~ s/:(native|any)$//r } @a), "\n";
            }
        }' "$1"
}
package_deps() { # <.deb>
    dpkg-deb -f "$1" Pre-Depends Depends | sed -n 's/^[A-Za-z-]*: //p' | perl -MDpkg::Deps -ne '
        my $d = deps_parse($_, reduce_arch => 1, host_arch => "amd64") or next;
        for my $x ($d->get_deps) {
            my @a = $x->isa("Dpkg::Deps::OR") ? $x->get_deps : ($x);
            print join("|", map { $_->{package} =~ s/:(native|any)$//r } @a), "\n";
        }'
}

# Install what's installable of the given dependencies (stdin), one by one;
# the others (Rust crates, packages not built yet) are skipped.
install_some() { # [exclude regex]
    local exclude=${1:-^$} dep alt
    while read -r dep; do
        for alt in ${dep//|/ }; do
            [[ $alt =~ $exclude ]] && continue
            sudo apt-get install -y -q --no-install-recommends "$alt" >>"$LOG" 2>&1 && break
        done
    done
}

# The local repository's .deb of <package> with the highest version (by
# Debian version comparison, not file name).
newest_deb() { # <package>
    local f v best='' best_v=''
    for f in "$R/$1"_*.deb; do
        [ -e "$f" ] || continue
        v=$(dpkg-deb -f "$f" Version)
        if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$best_v"; then
            best=$f best_v=$v
        fi
    done
    echo "$best"
}

# A package whose dependencies can't be installed yet: install what's
# installable of them, then the package itself with dpkg --force-depends.
bootstrap_install() { # <package>
    local deb
    deb=$(newest_deb "$1")
    [ -n "$deb" ] || die "no $1 in $R"
    package_deps "$deb" | install_some
    echo "bootstrap: dpkg -i --force-depends $(basename "$deb")" | tee -a "$LOG"
    sudo dpkg -i --force-depends "$deb" >>"$LOG" 2>&1 || die "installing $deb failed"
}

# Resolve the bootstrapped packages' dependencies with the packages just built.
fix_up() {
    refresh_repo
    sudo apt-get -f install -y -q >>"$LOG" 2>&1 || die "apt-get -f install failed, see $LOG"
    sudo dpkg --audit | tee -a "$LOG"
}

# pmxcfs (pve-cluster), installed as a build dependency, refuses to start if
# the hostname resolves to a loopback address only.
check_hostname() {
    local ip
    ip=$(getent hosts "$(hostname)" | awk '{print $1}' | head -1)
    case "$ip" in
        ''|127.*|::1) die "$(hostname) resolves to '${ip:-nothing}'; pve-cluster needs a non-loopback address, fix /etc/hosts" ;;
    esac
}

repo_build() { # <repo> [env assignments]
    local repo=$1; shift
    if ! env "$@" "$BUILD_REPO" "$BASE/$repo" | tee -a "$LOG"; then
        die "$repo failed, see build-logs/$repo.log; resume with --from $repo"
    fi
}

# Build a package from its prepared build directory: patched debian/rules (no
# Debian crate registry, default CARGO_HOME) and dpkg-buildpackage -d, as the
# librust-* build dependencies are replaced by crates.io and local crates.
cargo_dir_build() { # <name> <build dir> <log name>
    local name=$1 dir=$2 log=$BASE/build-logs/$3.log
    sed -i -e '/prepare-debian .*cargo_registry/d' \
           -e 's|^export CARGO_HOME = .*|# CARGO_HOME: the default (~/.cargo), crates from crates.io|' "$dir/debian/rules"
    echo "=== $(date -Is) building $name in $dir" >>"$log"
    (cd "$dir" && PATH=/usr/local/bin:/usr/bin:/bin dpkg-buildpackage -b -us -uc -d) </dev/null >>"$log" 2>&1 \
        || die "$name failed, see build-logs/$3.log"
}

step_pve-common() { repo_build pve-common WITH_TESTS=1; }

# libpve-rs-perl, built against the local proxmox-rs (with its Devuan
# changes), proxmox-ve-rs and perlmod crates instead of the published ones.
# Built first, without its tests: Proxmox's libproxmox-rs-perl, which
# pve-common's build needs, depends on libpve-rs-perl, and the tests are the
# only part of this build that needs libproxmox-rs-perl (its
# Proxmox::Lib::SslProbe), so the build needs no package from that cycle.
step_libpve-rs-perl() {
    local src=$BASE/proxmox-perl-rs/pve-rs version dir
    echo perlmod-bin | install_some
    build_deps "$src/debian/control" nocheck | install_some '^librust-|^dh-cargo$|^cargo$|^rustc$|^libproxmox-rs-perl$'
    version=$(dpkg-parsechangelog -l "$src/debian/changelog" -S Version)
    # built outside the repository: cargo also reads the .cargo/config.toml of
    # parent directories, and pve-rs/'s points at the Debian crate registry
    dir=$BASE/build/libpve-rs-perl-$version
    rm -rf "$dir" "$src/libpve-rs-perl-$version"
    make -C "$src" "libpve-rs-perl-$version" </dev/null >>"$BASE/build-logs/proxmox-perl-rs.log" 2>&1 \
        || die "preparing the libpve-rs-perl build directory failed"
    mv "$src/libpve-rs-perl-$version" "$dir"
    {
        echo '[patch.crates-io]'
        for crate_dir in "$BASE"/proxmox-rs/*/ "$BASE"/proxmox-ve-rs/*/ "$BASE"/perlmod/*/; do
            [ -f "$crate_dir/Cargo.toml" ] || continue
            name=$(sed -n '/^\[package\]/,/^\[/s/^name *= *"\(.*\)"/\1/p' "$crate_dir/Cargo.toml" | head -1)
            [ -n "$name" ] && echo "$name = { path = \"${crate_dir%/}\" }"
        done
    } > "$dir/.cargo/config.toml"
    DEB_BUILD_OPTIONS=nocheck cargo_dir_build libpve-rs-perl "$dir" proxmox-perl-rs
    cp "$BASE"/build/libpve-rs-perl*_"$version"_*.deb "$R/"
    refresh_repo
    echo "=== libpve-rs-perl: built $version" | tee -a "$LOG"
}

step_pve-qemu() { repo_build pve-qemu BUILD_PARALLEL="$NPROC"; }

step_pve-cluster() {
    check_hostname
    local control=$BASE/pve-cluster/debian/control
    # with its tests, they generate IPCC.so/IPCConst.pm
    build_deps "$control" pkg.pve-cluster.lsbservice | install_some '^libpve-access-control$'
    bootstrap_install libpve-access-control
    repo_build pve-cluster WITH_TESTS=1 BUILD_PARALLEL=1 SKIP_BUILD_DEPS=1
    fix_up
}

step_pve-firewall() { repo_build pve-firewall; }

step_pve-network() {
    local control=$BASE/pve-network/debian/control
    build_deps "$control" "nocheck pkg.pve-network.lsbservice" | install_some '^pve-firewall$'
    bootstrap_install pve-firewall
    repo_build pve-network SKIP_BUILD_DEPS=1
    fix_up
}

step_pve-storage() { repo_build pve-storage; }
step_ifupdown2() { repo_build ifupdown2; }
step_lxc() { repo_build lxc BUILD_PARALLEL="$NPROC"; }

# pve-lxc-syscalld: its own .cargo config points at the Debian crate registry,
# and cargo also reads it from parent directories, so the build directory is
# moved out of the repository to build/.
step_pve-lxc-syscalld() {
    local src=$BASE/pve-lxc-syscalld version dir
    build_deps "$src/debian/control" "nocheck pkg.pve-lxc-syscalld.lsbservice" | install_some '^librust-|^dh-cargo$|^cargo$|^rustc$'
    version=$(dpkg-parsechangelog -l "$src/debian/changelog" -S Version)
    dir=$BASE/build/pve-lxc-syscalld-$version
    rm -rf "$dir" "$src/pve-lxc-syscalld-$version"
    make -C "$src" "pve-lxc-syscalld-$version" </dev/null >>"$BASE/build-logs/pve-lxc-syscalld.log" 2>&1 \
        || die "preparing the pve-lxc-syscalld build directory failed"
    mv "$src/pve-lxc-syscalld-$version" "$dir"
    rm -rf "$dir/.cargo"
    DEB_BUILD_PROFILES="nocheck pkg.pve-lxc-syscalld.lsbservice" DEB_BUILD_OPTIONS=nocheck \
        cargo_dir_build pve-lxc-syscalld "$dir" pve-lxc-syscalld
    cp "$BASE"/build/pve-lxc-syscalld*_"$version"_*.deb "$R/"
    refresh_repo
    echo "=== pve-lxc-syscalld: built $version" | tee -a "$LOG"
}

step_pve-ha-manager() { repo_build pve-ha-manager; }

# its build dependency pve-qemu-kvm (>= 11.1~) is only needed by the tests
step_qemu-server() { repo_build qemu-server RELAX_BUILD_DEPS=1; }

step_pve-container() { repo_build pve-container; }
step_pve-manager() { repo_build pve-manager BUILD_PARALLEL=1; }

# allow sourcing the functions, e.g. for testing
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

info "Checking the local repository"
refresh_repo
check_fetched

started=0
[ -z "$FROM" ] && started=1
for step in "${STEPS[@]}"; do
    [ "$step" = "$FROM" ] && started=1
    [ $started = 1 ] || continue
    [ -n "$ONLY" ] && [ "$step" != "$ONLY" ] && continue
    info "$(date -Is) step $step"
    "step_$step"
done

if [ $INSTALL = 1 ]; then
    check_hostname
    info "Installing pve-manager"
    refresh_repo
    sudo apt-get install -y pve-manager 2>&1 | tee -a "$LOG"
    sudo dpkg --audit
fi

info "Done; packages in $R"
