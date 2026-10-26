#!/bin/bash
# mlfs-update boot guard — A/B-style boot counting.
# Written by mlfs-update after any run that installed packages:
#   boot-verify contains "<snapshot-id> <boots>"
# Each early boot increments boots. If a boot reaches graphical.target,
# mlfs-bootok.service deletes the file. If we see boots>=1 surviving,
# the previous boot never got to the desktop -> restore the pre-update
# snapshot immediately (still very early in boot).
set -uo pipefail

F=/var/lib/mlfs-update/state/boot-verify
PENDING=/var/lib/mlfs-snapshots/PENDING_ROLLBACK

[[ -f "$F" ]] || exit 0
read -r snap boots < "$F" || { rm -f "$F"; exit 0; }
[[ -d "/var/lib/mlfs-snapshots/$snap" ]] || { rm -f "$F"; exit 0; }
boots=$(( ${boots:-0} + 1 ))

if (( boots > 1 )); then
    echo "[bootguard] previous post-update boot never reached graphical.target — restoring $snap" \
        | tee /dev/kmsg
    rm -f "$F"
    echo "$snap" > "$PENDING"
    exec /usr/sbin/mlfs-snapshot boot-apply
fi

echo "$snap $boots" > "$F"
echo "[bootguard] post-update boot $boots — will auto-rollback if graphical.target not reached" \
    | tee /dev/kmsg
exit 0
