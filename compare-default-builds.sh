#!/bin/bash
# Check that the default (systemd) build of each changed repository still
# produces Proxmox's packages (openrc-devuan.md, Part D, test 8).
#
# Builds the branch (feature/init-systems-refactoring, without the lsbservice
# profile) and its upstream base commit the same way, each from a copy of the
# repository, and compares the packages: file list (mode, owner, path, link
# target), control fields, maintainer scripts and conffiles. Differences that
# the local version brings are ignored (Version, Installed-Size, +devuanN in
# versions, the changelog and debian/SOURCE); files whose content changed are
# listed, as code changes go into both builds. Nothing is installed or added
# to repo/.
#
# usage: compare-default-builds.sh [repo...]   (default: all changed ones
#        except proxmox-rs, proxmox-perl-rs and pve-qemu, see below)
# output: build/compare/<repo>/{base,branch}/, build/compare/report.txt,
#         log build-logs/compare-<repo>.log
set -o pipefail

BASE=$(cd "$(dirname "$0")" && pwd)
OUT=$BASE/build/compare
LOGDIR=$BASE/build-logs
REPORT=$OUT/report.txt
NPROC=$(nproc)

# Not compared by default: proxmox-rs builds no packages (its crates go into
# libpve-rs-perl and proxmox-firewall), proxmox-perl-rs only differs in its
# changelog, and pve-qemu has no profile (its patch is meant for all builds)
# and takes hours to build.
REPOS=(
    pve-common pve-manager pve-cluster pve-ha-manager qemu-server pve-container
    pve-storage pve-firewall pve-network pve-lxc-syscalld lxc ifupdown2 frr
    corosync-pve ksm-control-daemon proxmox-kernel-helper proxmox-ve
    proxmox-firewall
)
# Rust packages, built from their prepared build directory with crates.io
# like build.sh does (proxmox-firewall also against the local crates)
declare -A CARGO_BUILD=([pve-lxc-syscalld]=1 [proxmox-firewall]=1)
# base commit when it isn't the merge base with upstream/master
declare -A BASE_REF=([pve-qemu]=7fccdcf)

info() { printf '\n=== %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -gt 0 ] && REPOS=("$@")
mkdir -p "$OUT" "$LOGDIR"

# the default builds' build dependencies may include packages Devuan can't
# install (e.g. systemd); the build machine has what the builds actually use
mkdir -p ~/.config/dpkg
[ -e ~/.config/dpkg/buildpackage.conf ] && die "~/.config/dpkg/buildpackage.conf exists, remove it first"
echo "no-check-builddeps" > ~/.config/dpkg/buildpackage.conf
trap 'rm -f ~/.config/dpkg/buildpackage.conf' EXIT

local_crates_patch() { # <workspace dir>... (as in build.sh)
    local ws crate_dir name
    echo '[patch.crates-io]'
    for ws in "$@"; do
        for crate_dir in "$ws"/*/; do
            [ -f "$crate_dir/Cargo.toml" ] || continue
            name=$(sed -n '/^\[package\]/,/^\[/s/^name *= *"\(.*\)"/\1/p' "$crate_dir/Cargo.toml" | head -1)
            [ -n "$name" ] && echo "$name = { path = \"${crate_dir%/}\" }"
        done
    done
}

# copy the repository at <commit> (committed state, with its submodules) to <dir>
checkout_copy() { # <repo> <commit> <dir>
    local repo=$1 commit=$2 dir=$3
    rm -rf "$dir"; mkdir -p "$(dirname "$dir")"
    cp -a "$BASE/$repo" "$dir"
    git -C "$dir" checkout -q --force --detach "$commit" || return 1
    git -C "$dir" submodule -q update --init --recursive || return 1
    git -C "$dir" clean -q -xdff
    git -C "$dir" submodule -q foreach --recursive 'git clean -q -xdff'
}

build_make() { # <src dir> <deb dir> <log>
    local src=$1 debs=$2 log=$3 stamp
    stamp=$(mktemp); sleep 1
    (cd "$src" && DEB_BUILD_PROFILES=nocheck DEB_BUILD_OPTIONS="nocheck parallel=$NPROC" \
        BUILD_PARALLEL=$NPROC make deb) </dev/null >>"$log" 2>&1
    local rc=$?
    find "$src" -maxdepth 2 -name '*.deb' -newer "$stamp" ! -name '*-dbgsym_*' -exec mv -t "$debs" {} +
    rm -f "$stamp"
    return $rc
}

build_cargo() { # <repo> <src dir> <deb dir> <log>
    local repo=$1 src=$2 debs=$3 log=$4 name version dir
    name=$(sed -n 's/^Source: *//p' "$src/debian/control" | head -1)
    version=$(dpkg-parsechangelog -l "$src/debian/changelog" -S Version)
    make -C "$src" "$name-$version" </dev/null >>"$log" 2>&1 || return 1
    # outside the repository copy: cargo also reads parent directories'
    # .cargo/config.toml, which points at the Debian crate registry
    dir=$(dirname "$src")/build/$name-$version
    rm -rf "$(dirname "$dir")"; mkdir -p "$(dirname "$dir")"
    mv "$src/$name-$version" "$dir"
    rm -rf "$dir/.cargo"
    if [ "$repo" = proxmox-firewall ]; then
        mkdir -p "$dir/.cargo"
        local_crates_patch "$BASE"/proxmox-rs "$BASE"/proxmox-ve-rs > "$dir/.cargo/config.toml"
        sed -i 's|^target/${env:DEB_HOST_RUST_TYPE}/release/|target/release/|' \
            "$dir/debian/$name.install"
    fi
    sed -i -e '/prepare-debian .*cargo_registry/d' \
           -e 's|^export CARGO_HOME = .*|# CARGO_HOME: the default (~/.cargo), crates from crates.io|' \
           "$dir/debian/rules"
    (cd "$dir" && PATH=/usr/local/bin:/usr/bin:/bin DEB_BUILD_PROFILES=nocheck \
        DEB_BUILD_OPTIONS="nocheck parallel=$NPROC" dpkg-buildpackage -b -us -uc -d) </dev/null >>"$log" 2>&1
    local rc=$?
    find "$(dirname "$dir")" -maxdepth 1 -name '*.deb' ! -name '*-dbgsym_*' -exec mv -t "$debs" {} +
    return $rc
}

build_variant() { # <repo> <variant> <commit>
    local repo=$1 variant=$2 commit=$3 log=$LOGDIR/compare-$1.log
    local dir=$OUT/$repo/$variant
    echo "=== $(date -Is) $repo $variant ($commit)" >>"$log"
    checkout_copy "$repo" "$commit" "$dir/src" >>"$log" 2>&1 || { echo "checkout failed"; return 1; }
    rm -rf "$dir/debs"; mkdir -p "$dir/debs"
    if [ -n "${CARGO_BUILD[$repo]:-}" ]; then
        build_cargo "$repo" "$dir/src" "$dir/debs" "$log"
    else
        build_make "$dir/src" "$dir/debs" "$log"
    fi || { echo "build failed, see $log"; return 1; }
    ls "$dir"/debs/*.deb >/dev/null 2>&1 || { echo "no packages built, see $log"; return 1; }
}

# --- comparison --------------------------------------------------------------

# a package's normalized description: control fields, file list, maintainer
# scripts, conffiles; the local version is removed everywhere
describe() { # <deb> <section: control|files|scripts>
    local deb=$1 tmp
    case $2 in
        control)
            dpkg-deb -f "$deb" | grep -vE '^(Version|Installed-Size):' ;;
        files)
            dpkg-deb -c "$deb" | awk '{ p = $6; for (i = 7; i <= NF; i++) p = p " " $i; print $1, $2, p }' \
                | sed -e 's| \./| /|' | grep -vE ' /usr/share/doc/[^/]+/(changelog[^ ]*|SOURCE)$' | sort -k3 ;;
        scripts)
            tmp=$(mktemp -d)
            dpkg-deb -e "$deb" "$tmp/c"
            for f in preinst postinst prerm postrm config triggers conffiles templates shlibs symbols; do
                [ -f "$tmp/c/$f" ] && { echo "### $f"; cat "$tmp/c/$f"; }
            done
            rm -rf "$tmp" ;;
    esac | sed -E 's/\+devuan[0-9]+//g'
}

compare_repo() { # <repo>
    local repo=$1 b=$OUT/$1/base/debs n=$OUT/$1/branch/debs deb pkg other section d
    local -A base_pkgs branch_pkgs
    local result="identical" tmp
    for deb in "$b"/*.deb; do base_pkgs[$(dpkg-deb -f "$deb" Package)]=$deb; done
    for deb in "$n"/*.deb; do branch_pkgs[$(dpkg-deb -f "$deb" Package)]=$deb; done
    {
        echo "##### $repo"
        for pkg in $(printf '%s\n' "${!base_pkgs[@]}" "${!branch_pkgs[@]}" | sort -u); do
            if [ -z "${base_pkgs[$pkg]:-}" ] || [ -z "${branch_pkgs[$pkg]:-}" ]; then
                echo "## $pkg: only in $([ -n "${base_pkgs[$pkg]:-}" ] && echo base || echo branch)"
                result="differs"; continue
            fi
            deb=${base_pkgs[$pkg]}; other=${branch_pkgs[$pkg]}
            for section in control files scripts; do
                d=$(diff -u --label "base" --label "branch" <(describe "$deb" $section) <(describe "$other" $section))
                [ -n "$d" ] && { echo "## $pkg: $section"; echo "$d"; result="differs"; }
            done
            # content changes, e.g. code changes going into both builds
            tmp=$(mktemp -d)
            dpkg-deb -x "$deb" "$tmp/base"; dpkg-deb -x "$other" "$tmp/branch"
            d=$(diff -rq --no-dereference "$tmp/base" "$tmp/branch" 2>&1 \
                | grep -vE '/usr/share/doc/[^/]+/(changelog[^ ]*|SOURCE) ' \
                | sed -e "s|$tmp/base||" -e "s| and $tmp/branch[^ ]*||" -e 's/^Files /content: /' -e 's/ differ$//')
            rm -rf "$tmp"
            [ -n "$d" ] && { echo "## $pkg: changed content (files in both)"; echo "$d" | grep '^content:'; }
        done
        echo "#### $repo: $result"
        echo
    } >>"$REPORT"
    echo "$result"
}

# --- main --------------------------------------------------------------------

: >"$REPORT"
declare -A RESULT
for repo in "${REPOS[@]}"; do
    [ -d "$BASE/$repo/.git" ] || { RESULT[$repo]="not found"; continue; }
    head=$(git -C "$BASE/$repo" rev-parse HEAD)
    base=${BASE_REF[$repo]:-$(git -C "$BASE/$repo" merge-base HEAD upstream/master)} \
        || { RESULT[$repo]="no upstream/master"; continue; }
    info "$repo: base ${base:0:10}, branch ${head:0:10}"
    : >"$LOGDIR/compare-$repo.log"
    if ! r=$(build_variant "$repo" base "$base") || ! r=$(build_variant "$repo" branch "$head"); then
        RESULT[$repo]="ERROR: $r"; echo "  ${RESULT[$repo]}"; continue
    fi
    RESULT[$repo]=$(compare_repo "$repo")
    echo "  ${RESULT[$repo]}"
done

info "Summary (details in ${REPORT#$BASE/})"
for repo in "${REPOS[@]}"; do printf '%-22s %s\n' "$repo" "${RESULT[$repo]}"; done | tee -a "$REPORT"
