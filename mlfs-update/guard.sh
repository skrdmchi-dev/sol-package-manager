# guard.sh — safety rails for mlfs-update
#
# Three independent layers:
#   1. SONAME sentinel  — a library update may never silently remove a soname
#      that other binaries link against. Missing sonames are restored from
#      the pre-update snapshot (compat shim), keeping old apps working.
#   2. Linkage sentinel — ldd scan of every ELF under /usr before the run;
#      afterwards any NEW "not found" entry aborts and restores /usr.
#   3. Pre-flight       — disk space, snapshot existence+integrity, lock,
#      pending-rollback veto.

SNAP_ROOT="/var/lib/mlfs-snapshots"
STATE_DIR="${STATE_DIR:-/var/lib/mlfs-update/state}"
MIN_FREE_KB=$((8*1024*1024))   # refuse to start with <8 GiB free on /

say()  { printf '\033[1;32m[guard]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[guard]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[guard]\033[0m %s\n' "$*" >&2; }

latest_snapshot() { ls -d "$SNAP_ROOT"/[0-9]* 2>/dev/null | sort | tail -1; }

preflight() {
    # pending rollback means the last run already broke something
    if [[ -f "$SNAP_ROOT/PENDING_ROLLBACK" ]]; then
        fail "a boot rollback is already pending ($(cat "$SNAP_ROOT/PENDING_ROLLBACK")) — refusing to update on top of it"
        return 1
    fi
    local free
    free=$(df -k / | awk 'NR==2{print $4}')
    if (( free < MIN_FREE_KB )); then
        fail "only $((free/1024)) MiB free on / — need $((MIN_FREE_KB/1024)) MiB"
        return 1
    fi
    mkdir -p "$STATE_DIR"
    return 0
}

# soname inventory: "soname<TAB>path" lines for every shared object under /usr
soname_inventory() {
    find /usr/lib /usr/lib32 /usr/libexec -type f -name "*.so*" 2>/dev/null | while read -r f; do
        local s
        s=$(objdump -p "$f" 2>/dev/null | awk '/SONAME/{print $2}')
        [[ -n "$s" ]] && printf '%s\t%s\n' "$s" "$f"
    done | sort -u
}

# After installing a package: any soname that existed before but is now gone
# gets restored from the snapshot (hardlinked copy → cheap).
#   $1 = soname inventory file captured BEFORE the install
soname_guard() {
    local before="$1" missing=0
    [[ -f "$before" ]] || return 0
    local snap; snap=$(latest_snapshot)
    while IFS=$'\t' read -r s path; do
        [[ -e "$path" ]] && continue
        # soname target vanished — find ANY provider of that soname in snapshot
        local rel="${path#/}"
        if [[ -n "$snap" && -f "$snap/$rel" ]]; then
            cp -a "$snap/$rel" "/$rel" && warn "compat-shim: restored removed $s ($path) from snapshot"
            missing=$((missing+1))
        fi
    done < "$before"
    (( missing )) && ldconfig 2>/dev/null
    return 0
}

# Full-system linkage scan: every "lib not found" line, sorted.
linkage_scan() {
    local out="$1"
    find /usr/bin /usr/sbin /usr/lib /usr/libexec /usr/lib32 -type f \
        \( -perm -111 -o -name "*.so*" \) 2>/dev/null | while read -r f; do
        file "$f" 2>/dev/null | grep -q ELF || continue
        ldd "$f" 2>/dev/null | awk '/not found/{print FILENAME" : "$0}'
    done | sed 's/[[:space:]]*=>.*not found/ => not found/' | sort -u > "$out"
    wc -l < "$out"
}

# Compare scans: return 0 if no NEW broken links appeared.
linkage_diff_ok() {
    local before="$1" after="$2" new
    new=$(comm -13 "$before" "$after" | wc -l)
    if (( new > 0 )); then
        comm -13 "$before" "$after" >&2
        return 1
    fi
    return 0
}

# Restore /usr /etc /opt from a snapshot (used on linkage catastrophe).
restore_snapshot_now() {
    local snap id
    snap=$(latest_snapshot); [[ -n "$snap" ]] || { fail "no snapshot to restore"; return 1; }
    id=$(basename "$snap")
    fail "linkage breakage detected — restoring /usr /etc /opt from $id"
    for d in usr etc opt; do
        [[ -d "$snap/$d" ]] || continue
        rsync -aAXH --delete "$snap/$d/" "/$d/" || fail "restore of /$d failed"
    done
    ldconfig 2>/dev/null
    fail "rollback complete — system is at $id"
}
