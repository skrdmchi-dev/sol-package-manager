#!/usr/bin/env bash
set -uo pipefail

SOL_HOME="${SOL_HOME:-$HOME/.sol}"
LOCK="$SOL_HOME/sol.lock"
LOG="$SOL_HOME/sol.log"
PKGLOG_DIR="$SOL_HOME/logs"
CONF_DIR="$SOL_HOME"
DB="$CONF_DIR/packages.db"
RECIPES_DIR="$CONF_DIR/recipes"
FROZEN_FILE="$CONF_DIR/frozen.txt"
HOLDS_FILE="$CONF_DIR/holds.txt"
STATE_DIR="$SOL_HOME/state"
PROBE_CACHE="$STATE_DIR/probes"
BUILD_DIR="$SOL_HOME/build"
LIB="$SOL_HOME/lib"
PROBE_TTL=$((6*3600))
BUILD_TIMEOUT=5400
JOBS="${SOL_JOBS:-$(nproc)}"

mkdir -p "$SOL_HOME" "$STATE_DIR" "$BUILD_DIR" "$PKGLOG_DIR" "$PROBE_CACHE" "$LIB"

say()  { printf '\033[1;32m[sol]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[sol]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[sol]\033[0m %s\n' "$*" >&2; }

DO_FULL=0; DO_DRY=0; DO_LIST=0
ALLOW_MAJOR=0; NO_CACHE=0; ONLY=""; SKIP=""; FORCE=0

cmd_hold() {
    local n="$1"
    mkdir -p "$CONF_DIR"
    grep -qxF "$n" "$HOLDS_FILE" 2>/dev/null || echo "$n" >> "$HOLDS_FILE"
    say "$n held"
}
cmd_unhold() {
    local n="$1"
    [[ -f "$HOLDS_FILE" ]] || return 0
    sed -i "/^$(printf '%s' "$n" | sed 's/[][\.*^$/]/\\&/g')$/d" "$HOLDS_FILE"
    say "$n unheld"
}

case "${1:-}" in
    hold)   cmd_hold "${2:?name}"; exit 0 ;;
    unhold) cmd_unhold "${2:?name}"; exit 0 ;;
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
        --dry-run|--list-dry) DO_DRY=1 ;;
        --list) DO_LIST=1 ;;
        --allow-major) ALLOW_MAJOR=1 ;;
        --no-cache) NO_CACHE=1 ;;
        --force) FORCE=1 ;;
        --only=*) ONLY="${arg#--only=}" ;;
        --only) ;;
        --skip=*) SKIP="${arg#--skip=}" ;;
        --skip) ;;
        *) ;;
    esac
done

in_list() { 
    [[ -z "$1" ]] && return 1
    [[ ",$1," == *",$2,"* ]]
}
is_frozen() { grep -qxF "$1" "$FROZEN_FILE" 2>/dev/null; }
is_held()   { grep -qxF "$1" "$HOLDS_FILE" 2>/dev/null; }
ver_gt()    { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" != "$1" ]]; }
version_sane() { 
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)*([._-]?(p|patch|hotfix|pl)[0-9]+)?$ ]] || return 1
    [[ "$1" != *.* && "$2" == *.* ]] && return 1
    return 0
}
major_of()  { echo "${1%%.*}"; }

probe_pkg() {
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

pkg_url()     { echo "${P_URLTPL[$1]//@V@/$2}"; }
pkg_auxurls() { echo "${P_AUXTPL[$1]//@V@/$2}" | tr ',' ' '; }

fetch() {
    local u="$1" d="$2" b
    b="$(basename "$u")"
    curl -fsSL --max-time 600 -o "$d/$b" "$u"
}

build_pkg() {
    local name="$1" new="$2" old="${P_VER[$name]}"
    local work="$BUILD_DIR/$name" plog="$PKGLOG_DIR/$name.log"
    rm -rf "$work"; mkdir -p "$work" "$PKGLOG_DIR"
    (
        echo "== build $name $old -> $new =="
        cd "$work" || exit 1
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
            echo "AUX MISSING — skipping build"
            exit 11
        fi
        local tarball
        tarball="$(basename "$(pkg_url "$name" "$new")")"
        case "$tarball" in
            *.tar.*|*.tgz|*.zip) : ;;
            *) echo "unsupported archive type: $tarball"; exit 15 ;;
        esac
        local script s i=0 sdir
        IFS=',' read -ra _scripts <<< "${P_SCRIPTS[$name]}"
        for script in "${_scripts[@]}"; do
            [[ -f "$script" ]] || { echo "missing script $script"; exit 13; }
            i=$((i+1)); sdir="$work/s$i"; mkdir -p "$sdir"
            case "$tarball" in
                *.zip) python3 -m zipfile -e "$work/$tarball" "$sdir" || exit 12 ;;
                *) tar -xf "$work/$tarball" -C "$sdir" || exit 12 ;;
            esac
            for a in "$work"/*; do
                [[ "$a" == "$work/$tarball" || -d "$a" ]] && continue
                cp -f "$a" "$sdir/../" 2>/dev/null || true
            done
            s="$sdir/$(basename "$script")"
            sed -e "s/${old//./\\.}/$new/g" "$script" > "$s"
            chmod +x "$s"
            local edir
            edir="$(ls -d "$sdir"/*/ 2>/dev/null | head -1)"
            echo "-- running $(basename "$script))"
            ( cd "${edir:-$sdir}"; timeout "$BUILD_TIMEOUT" bash "$s" ) \
                || { echo "BUILD FAIL rc=$? ($script)"; exit 14; }
        done
        ldconfig
    ) > "$plog" 2>&1
}

run_tier() {
    local tiers="$1" name new old tier updated=() failed=() skipped=()
    for name in "${ORDER[@]}"; do
        tier="${P_TIER[$name]}"
        in_list "$tiers" "$tier" || continue
        [[ -n "$ONLY" ]] && ! in_list "$ONLY" "$name" && continue
        in_list "$SKIP" "$name" && { skipped+=("$name"); continue; }
        is_frozen "$name" && { skipped+=("$name(frozen)"); continue; }
        is_held "$name" && { skipped+=("$name(held)"); continue; }
        recipe_exists "$name" && continue
        old="${P_VER[$name]}"
        new="$(probe_pkg "$name" "${P_PROBE[$name]}:${P_ARG[$name]}")"
        [[ -z "$new" ]] && { skipped+=("$name(probe?)"); continue; }
        (( FORCE )) || { version_sane "$new" "$old" && ver_gt "$new" "$old"; } || continue
        if [[ "$tier" == "critical" && $ALLOW_MAJOR -eq 0 ]] \
            && [[ "$(major_of "$new")" != "$(major_of "$old")" ]]; then
            warn "$name $old -> $new crosses major — holding (use --allow-major)"
            skipped+=("$name(major)")
            continue
        fi
        say "$name: $old -> $new — building"
        if build_pkg "$name" "$new"; then
            updated+=("$name $old -> $new")
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

run_recipes() {
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

[[ -f "$DB" ]] || { fail "no packages.db — add packages to $DB first"; exit 1; }

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

say "=== sol $(date -Is) ==="
load_db
ORDER=($(awk -F'\t' '!/^#/{print $1}' "$DB"))
UPDATED_PKGS=(); FAILED_PKGS=()

curl -sf --max-time 10 -o /dev/null https://www.kernel.org \
    || { warn "no network — nothing to update"; exit 0; }

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
        critical) (( DO_FULL )) || continue ;;
    esac
    echo "$name"
done | xargs -P 8 -I{} bash -c '
    source "$LIB/probe.sh"
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

run_recipes
run_tier "leaf,lib"
(( DO_FULL )) && run_tier "critical"

say "=== done ==="
say "updated: ${#UPDATED_PKGS[@]}  failed: ${#FAILED_PKGS[@]}"
((${#FAILED_PKGS[@]})) && printf '   FAILED: %s\n' "${FAILED_PKGS[@]}"
say "log: $LOG"
exit 0
