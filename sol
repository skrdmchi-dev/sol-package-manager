#!/usr/bin/env bash
set -uo pipefail

LOCK="/run/mlfs-update.lock"
LOG="/var/log/mlfs-update.log"
PKGLOG_DIR="/var/log/mlfs-update.d"
CONF_DIR="/etc/mlfs-update"
DB="$CONF_DIR/packages.db"
RECIPES_DIR="$CONF_DIR/packages.d"
FROZEN_FILE="$CONF_DIR/frozen.txt"
HOLDS_FILE="$CONF_DIR/holds.txt"
SANITY="$CONF_DIR/sanity.sh"
STATE_DIR="/var/lib/mlfs-update/state"
PROBE_CACHE="$STATE_DIR/probes"
BUILD_DIR="/var/lib/mlfs-update/build"
SNAP="/usr/sbin/mlfs-snapshot"
NIX="/nix/var/nix/profiles/default/bin/nix"
LIB="/usr/lib/mlfs-update"
PROBE_TTL=$((6*3600))
BUILD_TIMEOUT=5400
JOBS="$(nproc)"

source "$LIB/probe.sh"
source "$LIB/guard.sh"

say()  { printf '\033[1;32m[update]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[update]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[update]\033[0m %s\n' "$*" >&2; }

DO_FULL=0; DO_NVIDIA=0; DO_DRY=0; DO_LIST=0; DO_GAMING=0
ALLOW_MAJOR=0; NO_CACHE=0; ONLY=""; SKIP=""; DO_NIX=1; DO_FP=1; FORCE=0

cmd_hold() {
    local n="$1"
    mkdir -p "$CONF_DIR"; touch "$HOLDS_FILE"
    grep -qxF "$n" "$HOLDS_FILE" || echo "$n" >> "$HOLDS_FILE"
    say "$n held"
}
cmd_unhold() {
    local n="$1"
    [[ -f "$HOLDS_FILE" ]] || return 0
    sed -i "/^$(printf '%s' "$n" | sed 's/[][\.*^$/]/\\&/g')$/d" "$HOLDS_FILE"
    say "$n unheld"
}

case "${1:-}" in
    hold)   [[ $EUID -eq 0 ]] || { fail "sudo"; exit 1; }; cmd_hold "${2:?name}"; exit 0 ;;
    unhold) [[ $EUID -eq 0 ]] || { fail "sudo"; exit 1; }; cmd_unhold "${2:?name}"; exit 0 ;;
    regen-db) [[ $EUID -eq 0 ]] || { fail "sudo"; exit 1; }; exec /usr/sbin/mlfs-genpkgdb ;;
esac

if [[ "$(basename "$0")" == "sol" ]]; then
    case "${1:-}" in
        update)  shift ;;
        upgrade) shift; DO_DRY=1 ;;
        *) exit 0 ;;
    esac
fi

for arg in "$@"; do
    case "$arg" in
        --full) DO_FULL=1 ;;
        --nvidia) DO_NVIDIA=1 ;;
        --dry-run|--list-dry) DO_DRY=1 ;;
        --list) DO_LIST=1 ;;
        --gaming) DO_GAMING=1 ;;
        --allow-major) ALLOW_MAJOR=1 ;;
        --no-cache) NO_CACHE=1 ;;
        --no-nix) DO_NIX=0 ;;
        --no-flatpak) DO_FP=0 ;;
        --force) FORCE=1 ;;
        --only=*) ONLY="${arg#--only=}" ;;
        --only) ;;
        --skip=*) SKIP="${arg#--skip=}" ;;
        --skip) ;;
        *) ;;
    esac
done

in_list() { # in_list "a,b" "$name"
    [[ -z "$1" ]] && return 1
    [[ ",$1," == *",$2,"* ]]
}
is_frozen() { grep -qxF "$1" "$FROZEN_FILE" 2>/dev/null; }
is_held()   { grep -qxF "$1" "$HOLDS_FILE" 2>/dev/null; }
ver_gt()    { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" != "$1" ]]; }

# reject garbage probed versions: prerelease suffixes (rc/beta/alpha/pre/dev)
# and dotless blobs (date-tags like ibus "20080901", stripped tags like gs
# "10080") when the installed version is properly dotted.
version_sane() { # version_sane <new> <old>
    # strict shape: dotted numerics only (optional p/patch/hotfix suffix).
    # kills prereleases, "-video" style tag junk, and anything non-version.
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)*([._-]?(p|patch|hotfix|pl)[0-9]+)?$ ]] || return 1
    # dotless blob vs dotted installed ver — date-tags like ibus "20080901"
    [[ "$1" != *.* && "$2" == *.* ]] && return 1
    return 0
}
major_of()  { echo "${1%%.*}"; }

# ---------- probe cache -----------------------------------------------------
probe_pkg() { # probe_pkg <name> <spec> -> prints latest or ""
    local name="$1" spec="$2" cache="$PROBE_CACHE/$name" v
    if (( ! NO_CACHE )) && [[ -f "$cache" ]]; then
        if (( $(date +%s) - $(stat -c %Y "$cache") < PROBE_TTL )); then
            cat "$cache"; return 0
        fi
    fi
    v="$(run_probe "$spec" 2>/dev/null | head -1)"
    if [[ -n "$v" ]]; then
        mkdir -p "$PROBE_CACHE"; echo "$v" > "$cache"
    fi
    echo "$v"
}

# ---------- db loading ------------------------------------------------------
declare -A P_VER P_TIER P_PROBE P_ARG P_URLTPL P_AUXTPL P_SCRIPTS
load_db() {
    local line
    while IFS= read -r line; do
        local n v t p a u au s
        IFS=$'\x1f' read -r n v t p a u au s <<< "${line//$'\t'/$'\x1f'}"
        [[ "$n" =~ ^#|^$ ]] && continue
        P_VER[$n]="$v"; P_TIER[$n]="$t"; P_PROBE[$n]="$p"; P_ARG[$n]="$a"
        P_URLTPL[$n]="$u"; P_AUXTPL[$n]="$au"; P_SCRIPTS[$n]="$s"
    done < "$DB"
}
recipe_exists() { [[ -f "$RECIPES_DIR/$1.sh" ]]; }

# ---------- build executor --------------------------------------------------
pkg_url()     { echo "${P_URLTPL[$1]//@V@/$2}"; }
pkg_auxurls() { echo "${P_AUXTPL[$1]//@V@/$2}" | tr ',' ' '; }

fetch() { # fetch <url> <destdir>
    local u="$1" d="$2" b
    b="$(basename "$u")"
    curl -fsSL --max-time 600 -o "$d/$b" "$u"
}

# run one db row through build+install with all guards.
# returns: 0 ok/current, 1 build failed, 2 probe unknown, 3 blocked(policy)
build_pkg() { # build_pkg <name> <newver>
    local name="$1" new="$2" old="${P_VER[$name]}"
    local work="$BUILD_DIR/$name" plog="$PKGLOG_DIR/$name.log"
    rm -rf "$work"; mkdir -p "$work" "$PKGLOG_DIR"
    (
        echo "== build $name $old -> $new =="
        cd "$work" || exit 1

        # download tarball + aux
        fetch "$(pkg_url "$name" "$new")" "$work" || { echo "DOWNLOAD FAIL"; exit 10; }
        local aux missing_aux=0 a b
        for a in $(pkg_auxurls "$name" "$new"); do
            b="$(basename "$a")"
            curl -fsSL --max-time 120 -o "$work/$b" "$a" 2>/dev/null || {
                warn "aux fetch failed: $b"
                missing_aux=1
            }
        done
        if (( missing_aux )); then
            # aux files are usually REQUIRED patches — without them the build
            # script's ../<patch> references break or, worse, silently produce
            # an unpatched package. Skip rather than risk it.
            echo "AUX MISSING — skipping build (safe veto)"
            exit 11
        fi

        local tarball
        tarball="$(basename "$(pkg_url "$name" "$new")")"
        case "$tarball" in
            *.tar.*|*.tgz|*.zip) : ;;
            *) echo "unsupported archive type: $tarball"; exit 15 ;;
        esac

        # each buildscript gets its own clean extract (64-bit, then lib32)
        local script s i=0 sdir
        IFS=',' read -ra _scripts <<< "${P_SCRIPTS[$name]}"
        for script in "${_scripts[@]}"; do
            [[ -f "$script" ]] || { echo "missing script $script"; exit 13; }
            i=$((i+1)); sdir="$work/s$i"; mkdir -p "$sdir"
            case "$tarball" in
                *.zip) python3 -m zipfile -e "$work/$tarball" "$sdir" || exit 12 ;;
                *.run) ;;
                *) tar -xf "$work/$tarball" -C "$sdir" || exit 12 ;;
            esac
            # stage aux files beside the extract (scripts use ../foo.patch)
            for a in "$work"/*; do
                [[ "$a" == "$work/$tarball" || -d "$a" ]] && continue
                cp -f "$a" "$sdir/../" 2>/dev/null || true
            done
            s="$sdir/$(basename "$script")"
            sed -e "s/${old//./\\.}/$new/g" "$script" > "$s"
            chmod +x "$s"
            local edir
            edir="$(ls -d "$sdir"/*/ 2>/dev/null | head -1)"
            echo "-- running $(basename "$script")"
            [[ -f /etc/profile.d/xorg.sh ]] && . /etc/profile.d/xorg.sh
            ( cd "${edir:-$sdir}"; timeout "$BUILD_TIMEOUT" bash "$s" ) \
                || { echo "BUILD FAIL rc=$? ($script)"; exit 14; }
        done
        ldconfig
    ) > "$plog" 2>&1
}

# ---------- stages ----------------------------------------------------------
do_nix() {
    [[ -x "$NIX" ]] || { warn "nix missing — skipping"; return 0; }
    say "nix system profile upgrade..."
    if NIXPKGS_ALLOW_UNFREE=1 "$NIX" profile upgrade --all --impure; then
        say "nix upgraded"
    else
        warn "nix upgrade failed — fix with: sudo nix profile rollback"
    fi
}

do_flatpak() {
    local FP
    FP="$(command -v flatpak 2>/dev/null || true)"
    [[ -z "$FP" && -x /nix/var/nix/profiles/per-user/root/profile/bin/flatpak ]] \
        && FP=/nix/var/nix/profiles/per-user/root/profile/bin/flatpak
    [[ -z "$FP" ]] && FP="$(ls /nix/store/*flatpak-*/bin/flatpak 2>/dev/null | head -1)"
    [[ -n "$FP" ]] || { warn "flatpak missing — skipping"; return 0; }
    say "flatpak update ($FP)..."
    "$FP" update --noninteractive -y 2>&1 | tail -3
    "$FP" uninstall --unused --noninteractive -y 2>&1 | tail -2
    # GL extension must match installed driver version
    local drv; drv="$(modinfo -F version nvidia 2>/dev/null | tr '.' '-' )"
    [[ -n "$drv" ]] || drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | tr '.' '-')"
    if [[ -n "$drv" && ! -d "/var/lib/flatpak/extension/org.freedesktop.Platform.GL.nvidia-${drv}" ]]; then
        warn "flatpak GL extension missing for driver $drv — flatpaks have no GPU (see mlfs-context.md)"
    fi
}

run_tier() { # run_tier <tierlist>
    local tiers="$1" name new old tier updated=() failed=() skipped=()
    for name in "${ORDER[@]}"; do
        tier="${P_TIER[$name]}"
        in_list "$tiers" "$tier" || continue
        [[ -n "$ONLY" ]] && ! in_list "$ONLY" "$name" && continue
        in_list "$SKIP" "$name" && { skipped+=("$name"); continue; }
        is_frozen "$name" && { skipped+=("$name(frozen)"); continue; }
        is_held "$name" && { skipped+=("$name(held)"); continue; }
        recipe_exists "$name" && continue   # hand recipes run in their own stage
        old="${P_VER[$name]}"
        new="$(probe_pkg "$name" "${P_PROBE[$name]}:${P_ARG[$name]}")"
        [[ -z "$new" ]] && { skipped+=("$name(probe?)"); continue; }
        (( FORCE )) || { version_sane "$new" "$old" && ver_gt "$new" "$old"; } || continue
        # policy: critical packages stay on the same major unless allowed
        if [[ "$tier" == "critical" && $ALLOW_MAJOR -eq 0 ]] \
            && [[ "$(major_of "$new")" != "$(major_of "$old")" ]]; then
            warn "$name $old -> $new crosses major — holding (use --allow-major)"
            skipped+=("$name(major)")
            continue
        fi
        say "$name: $old -> $new — building"
        local soname_before="$STATE_DIR/sonames-$name.before"
        [[ "$tier" =~ lib|critical|gaming ]] && soname_inventory > "$soname_before"
        if build_pkg "$name" "$new"; then
            soname_guard "$soname_before"
            updated+=("$name $old -> $new")
            # make db authoritative for next run
            sed -i "s/^$(printf '%s' "$name" | sed 's/[][\.*^$/]/\\&/g')\t[^\t]*/$name\t$new/" "$DB"
            echo "$new" > "$STATE_DIR/$name.version"
        else
            rc=$?
            failed+=("$name")
            warn "$name build failed (rc=$rc) — see $PKGLOG_DIR/$name.log"
        fi
    done
    say "tier[$tiers]: updated ${#updated[@]} failed ${#failed[@]} skipped ${#skipped[@]}"
    ((${#updated[@]})) && printf '   %s\n' "${updated[@]}"
    ((${#failed[@]}))  && printf '   FAILED: %s\n' "${failed[@]}" >&2
    UPDATED_PKGS+=("${updated[@]}")
    FAILED_PKGS+=("${failed[@]}")
}

run_recipes() { # legacy packages.d/*.sh overrides — same API as v1
    shopt -s nullglob
    for recipe in "$RECIPES_DIR"/*.sh; do
        local rname; rname="$(basename "$recipe" .sh)"
        in_list "$SKIP" "$rname" && continue
        is_frozen "$rname" && continue
        is_held "$rname" && continue
        [[ -n "$ONLY" ]] && ! in_list "$ONLY" "$rname" && continue
        (
            set -euo pipefail
            source "$recipe"
            inst="$(installed_version 2>/dev/null || echo none)"
            latest="$(latest_version 2>/dev/null || echo none)"
            [[ "$latest" == "none" || "$inst" == "$latest" ]] && exit 0
            echo "$inst|$latest"
        ) > "$STATE_DIR/$rname.ver" 2>/dev/null || continue
        IFS='|' read -r inst latest < "$STATE_DIR/$rname.ver" 2>/dev/null || continue
        [[ -n "$latest" ]] || continue
        say "$rname: $inst -> $latest — building (recipe)"
        if (
            set -euo pipefail
            source "$recipe"
            work="$(mktemp -d "$BUILD_DIR/$rname.XXXXXX")"; cd "$work"
            curl -fsSL -o src.tar "$(tarball_url "$latest")"
            mkdir src && tar -xf src.tar -C src --strip-components=1; cd src
            build "$latest"
            ldconfig
            declare -F smoke >/dev/null && smoke "$latest"
        ) > "$PKGLOG_DIR/$rname.log" 2>&1; then
            UPDATED_PKGS+=("$rname $inst -> $latest")
        else
            FAILED_PKGS+=("$rname"); warn "$rname recipe failed"
        fi
    done
}

do_nvidia() { # the manual driver stage — opt-in only
    local name="nvidia" old="${P_VER[nvidia]:-615.71.09}" new
    new="$(probe_pkg nvidia "${P_PROBE[nvidia]}:${P_ARG[nvidia]}")"
    [[ -z "$new" ]] && { warn "nvidia: cannot probe latest driver"; return 1; }
    ver_gt "$new" "$old" || { say "nvidia $old is current"; return 0; }
    say "nvidia: $old -> $new — driver update"
    # kernel headers must exist for the running kernel
    if [[ ! -f "/lib/modules/$(uname -r)/build/Makefile" ]]; then
        fail "kernel headers missing for $(uname -r) — cannot build nvidia module"
        return 1
    fi
    local work="$BUILD_DIR/nvidia" run="$work/NVIDIA-Linux-x86_64-$new.run"
    mkdir -p "$work"
    curl -fsSL --max-time 900 -o "$run" \
        "https://us.download.nvidia.com/XFree86/Linux-x86_64/$new/NVIDIA-Linux-x86_64-$new.run" \
        || { fail "nvidia runfile download failed"; return 1; }
    sh "$run" --check >/dev/null 2>&1 || warn "runfile self-check failed — continuing anyway"
    say "installing driver (kernel module + userland)..."
    if ! ( cd "$work" && sh "$run" -z -j "$JOBS" -k "$(uname -r)" --no-peermem \
        --override-file-type-destination=OPENCL_WRAPPER_LIB:/tmp/nvidia \
        --override-file-type-destination=OPENCL_WRAPPER_SYMLINK:/tmp/nvidia ) \
        > "$PKGLOG_DIR/nvidia.log" 2>&1; then
        fail "nvidia installer failed — see $PKGLOG_DIR/nvidia.log"
        return 1
    fi
    # smoke: module file exists with the new version
    local modv; modv="$(modinfo -F version nvidia 2>/dev/null || true)"
    if [[ "$modv" != "$new" ]]; then
        warn "nvidia module reports $modv (expected $new) — may need reboot"
    fi
    ldconfig
    # rebuild flatpak GL extension for the new version
    local dash="${new//./-}" ext
    for branch in 25.08 26.08; do
        ext="/var/lib/flatpak/extension/org.freedesktop.Platform.GL.nvidia-${dash}/x86_64/$branch"
        mkdir -p "$ext/lib" "$ext/lib/gbm" \
                 "$ext/share/vulkan/icd.d" "$ext/share/glvnd/egl_vendor.d" \
                 "$ext/share/egl/egl_external_platform.d"
        cp -a /usr/lib/libnvidia-*.so* /usr/lib/libEGL_nvidia.so* \
              /usr/lib/libGLX_nvidia.so* "$ext/lib/" 2>/dev/null
        cp -a /usr/lib/gbm/nvidia-drm_gbm.so "$ext/lib/gbm/" 2>/dev/null
        cp -a /usr/share/vulkan/icd.d/nvidia_icd*.json "$ext/share/vulkan/icd.d/" 2>/dev/null
        cp -a /usr/share/glvnd/egl_vendor.d/10_nvidia.json "$ext/share/glvnd/egl_vendor.d/" 2>/dev/null
        cp -a /usr/share/egl/egl_external_platform.d/*nvidia* "$ext/share/egl/egl_external_platform.d/" 2>/dev/null
    done
    say "flatpak GL extension rebuilt for $new"
    sed -i "s/^nvidia\t[^\t]*/nvidia\t$new/" "$DB"
    say "nvidia $new installed — REBOOT required to load the new module"
}

# ---------- main ------------------------------------------------------------
[[ $EUID -eq 0 ]] || { fail "run as root (sudo mlfs-update)"; exit 1; }
[[ -f "$DB" ]] || { fail "no packages.db — run: sudo mlfs-genpkgdb"; exit 1; }

if (( DO_LIST )); then
    load_db
    printf '%-28s %-10s %-14s %s\n' NAME INSTALLED TIER PROBE
    for n in "${!P_VER[@]}"; do
        printf '%-28s %-10s %-14s %s\n' "$n" "${P_VER[$n]}" "${P_TIER[$n]}" "${P_PROBE[$n]}"
    done | sort
    exit 0
fi

exec 9>"$LOCK"; flock -n 9 || { fail "already running"; exit 1; }
mkdir -p "$STATE_DIR" "$BUILD_DIR" "$PKGLOG_DIR" "$PROBE_CACHE"
exec > >(tee -a "$LOG") 2>&1

say "=== mlfs-update $(date -Is) ==="
load_db
ORDER=($(awk -F'\t' '!/^#/{print $1}' "$DB"))
UPDATED_PKGS=(); FAILED_PKGS=()

preflight || exit 1
curl -sf --max-time 10 -o /dev/null https://www.kernel.org \
    || { warn "no network — nothing to update"; exit 0; }

# ---- probe phase: figure out what WOULD update -----------------------------
say "probing upstream (${#ORDER[@]} packages)..."
PENDING=()
for name in "${ORDER[@]}"; do
    tier="${P_TIER[$name]}"
    [[ "$tier" == "manual" ]] && continue
    is_frozen "$name" && continue
    is_held "$name" && continue
    [[ -n "$ONLY" ]] && ! in_list "$ONLY" "$name" && continue
    in_list "$SKIP" "$name" && continue
    recipe_exists "$name" && continue
    case "$tier" in
        leaf|lib) ;;
        critical|gaming) (( DO_FULL || DO_GAMING )) || continue ;;
    esac
    echo "$name"
done | xargs -P 8 -I{} bash -c '
    source /usr/lib/mlfs-update/probe.sh
    n="{}"; cache="'"$PROBE_CACHE"'/$n"
    if [[ -f "$cache" && $(( $(date +%s) - $(stat -c %Y "$cache") )) -lt '"$PROBE_TTL"' ]]; then
        v="$(cat "$cache")"
    else
        spec="$(awk -F"\t" -v n="$n" "\$1==n{print \$4\":\"\$5}" '"$DB"')"
        v="$(run_probe "$spec" 2>/dev/null | head -1)"
        [[ -n "$v" ]] && echo "$v" > "$cache"
    fi
    echo -e "$n\t$v"
' > "$STATE_DIR/pending-probe.tsv" 2>/dev/null

while IFS=$'\t' read -r n v; do
    { [[ -n "$v" ]] && version_sane "$v" "${P_VER[$n]:-0}" && ver_gt "$v" "${P_VER[$n]:-0}"; } \
    || { (( FORCE )) && [[ "$ONLY" == "$n" ]] && v="${P_VER[$n]}"; } \
    || continue
    PENDING+=("$n:$v")
done < "$STATE_DIR/pending-probe.tsv"

say "pending updates: ${#PENDING[@]}"
((${#PENDING[@]})) && printf '   %s\n' "${PENDING[@]}"

if (( DO_DRY )); then
    say "--dry-run — nothing changed"
    exit 0
fi

# ---- snapshot BEFORE touching anything --------------------------------------
say "pre-update snapshot..."
"$SNAP" create "pre-update" || { fail "snapshot failed — aborting"; exit 1; }
SNAP_DIR="$(latest_snapshot)"
[[ -d "$SNAP_DIR/usr" ]] || { fail "snapshot integrity check failed"; exit 1; }

say "baseline linkage scan..."
linkage_scan "$STATE_DIR/linkage.before" >/dev/null

(( DO_NIX )) && do_nix
(( DO_FP )) && do_flatpak
run_recipes
run_tier "leaf,lib"
(( DO_FULL ))            && run_tier "critical"
(( DO_FULL || DO_GAMING )) && run_tier "gaming"
(( DO_NVIDIA ))          && do_nvidia

# ---- post-flight ------------------------------------------------------------
say "post-update linkage scan..."
linkage_scan "$STATE_DIR/linkage.after" >/dev/null
if ! linkage_diff_ok "$STATE_DIR/linkage.before" "$STATE_DIR/linkage.after"; then
    restore_snapshot_now
    exit 1
fi

say "sanity checks..."
if [[ -x "$SANITY" ]] && ! "$SANITY"; then
    fail "sanity failed — flagging snapshot for boot-time restore"
    "$SNAP" last --boot || warn "flag failed"
    rm -f "$STATE_DIR/last-ok"
    exit 1
fi

touch "$STATE_DIR/last-ok"

# boot-verify: if the next boot never reaches graphical.target, bootguard
# auto-restores this run's pre-update snapshot (A/B-style boot counting).
if ((${#UPDATED_PKGS[@]})) && [[ -n "${SNAP_DIR:-}" ]]; then
    echo "$(basename "$SNAP_DIR") 0" > "$STATE_DIR/boot-verify"
    say "boot-verify armed: next boot must reach graphical.target or auto-rollback"
fi

"$SNAP" prune

say "=== done ==="
say "updated: ${#UPDATED_PKGS[@]}  failed: ${#FAILED_PKGS[@]}"
((${#FAILED_PKGS[@]})) && printf '   FAILED: %s\n' "${FAILED_PKGS[@]}"
say "log: $LOG — rollback: sudo snapshot last"
exit 0
