#!/bin/bash
# Copy the local repository repo/ (the result of build.sh) to /srv/repo on the
# install machine and give it to _apt; optionally upgrade the machine from it
# (see openrc-devuan.md, "Installing on another machine").
#
# Usage: [REMOTE_MACHINE=root@pve2] update-repo.sh [--rsync] [--upgrade]
#   --rsync    copy with rsync --delete (mirrors repo/, removing debs no longer
#              in it; needs rsync on both machines), by default scp
#   --upgrade  run apt update && apt full-upgrade on the machine afterwards
# Run from the directory containing repo/.

set -euo pipefail

REMOTE_MACHINE=${REMOTE_MACHINE:-root@pve2}

RSYNC=0 UPGRADE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --rsync) RSYNC=1 ;;
        --upgrade) UPGRADE=1 ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "unknown option '$1', see --help" >&2; exit 2 ;;
    esac
    shift
done

[ -d repo ] || { echo "repo/ not found, run from the build directory" >&2; exit 1; }

ssh "$REMOTE_MACHINE" 'mkdir -p /srv/repo'
if [ "$RSYNC" = 1 ]; then
    rsync -a --delete repo/ "$REMOTE_MACHINE:/srv/repo/"
else
    scp -r repo/* "$REMOTE_MACHINE:/srv/repo/"
fi
ssh "$REMOTE_MACHINE" 'chown -R _apt:root /srv/repo'

if [ "$UPGRADE" = 1 ]; then
    ssh -t "$REMOTE_MACHINE" 'apt update && apt full-upgrade'
fi
