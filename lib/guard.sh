preflight() {
    if [[ ! -d "$BUILD_DIR" ]]; then
        mkdir -p "$BUILD_DIR"
    fi
    if ! command -v curl >/dev/null 2>&1; then
        fail "curl not found — install it first"
        exit 1
    fi
    if ! command -v tar >/dev/null 2>&1; then
        fail "tar not found — install it first"
        exit 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        fail "python3 not found — install it first"
        exit 1
    fi
    local free
    free=$(df --output=avail "$BUILD_DIR" | tail -1 | tr -d ' ')
    free=$((free / 1024 / 1024))
    if (( free < 5 )); then
        fail "less than 5GB free in $BUILD_DIR — aborting"
        exit 1
    fi
}

soname_inventory() {
    lddconfig -p -N 2>/dev/null | awk '{print $1}' | sort -u
}

soname_guard() {
    local before="$1"
    if [[ ! -f "$before" ]]; then
        return 0
    fi
    soname_inventory > "$STATE_DIR/sonames-after"
    local broken missing=0
    while read -r lib; do
        if ! grep -qF "$lib" "$before"; then
            broken=$((broken + 1))
        fi
    done < "$STATE_DIR/sonames-after"
    if (( broken > 0 )); then
        warn "$broken new sonames appeared — library changes detected"
    fi
}

linkage_scan() {
    local out="$1"
    if command -v ldd >/dev/null 2>&1; then
        find /usr/local/bin /usr/local/lib -type f 2>/dev/null | while read -r f; do
            ldd "$f" 2>/dev/null | awk '/not found/{print $1}'
        done | sort -u > "$out"
    fi
}

linkage_diff_ok() {
    local before="$1" after="$2"
    if [[ ! -f "$before" || ! -f "$after" ]]; then
        return 0
    fi
    local missing
    missing=$(comm -13 "$before" "$after")
    if [[ -n "$missing" ]]; then
        warn "linkage broken: $missing"
        return 1
    fi
    return 0
}

restore_snapshot_now() {
    warn "restoring from pre-update state..."
    if [[ -d "$STATE_DIR/pre-update" ]]; then
        cp -a "$STATE_DIR/pre-update/"* /usr/local/ 2>/dev/null || true
    fi
}
