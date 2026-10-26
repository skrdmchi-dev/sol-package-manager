# probe.sh — upstream version probers for mlfs-update
# Each prober prints a bare version string to stdout, or nothing on failure.

PROBE_TIMEOUT="${PROBE_TIMEOUT:-20}"

_curl() { curl -fsSL --max-time "$PROBE_TIMEOUT" --retry 1 -A "mlfs-update/2" "$@"; }

_strip_tag() { sed -E 's/^[^0-9]*//; s/_/./g' ; }

# --- github:{owner}/{repo} — latest Release ---------------------------------
probe_github() {
    _curl "https://api.github.com/repos/$1/releases/latest" \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[^"]*"([^"]+)".*/\1/' \
        | _strip_tag
}

# --- gh-tags:{owner}/{repo} — repos that tag but have no Releases ------------
probe_gh_tags() {
    _curl "https://api.github.com/repos/$1/tags?per_page=30" \
        | grep -oE '"name"[^,]*' | sed -E 's/.*"([^"]+)".*/\1/' \
        | _strip_tag | grep -E '^[0-9]+(\.[0-9]+)*$' | head -1
}

# --- gl-tags:{host}/{urlenc-path} — gitlab tags API --------------------------
probe_gl_tags() {
    _curl "https://$1/api/v4/projects/$2/repository/tags?per_page=30" \
        | grep -oE '"name"[^,]*' | sed -E 's/.*"([^"]+)".*/\1/' \
        | _strip_tag | grep -E '^[0-9]+(\.[0-9]+)*$' | head -1
}

# --- sf:{project}:{fname-regex-with-@V@} — sourceforge best_release ----------
probe_sf() {
    local proj="${1%%:*}" re="${1#*:}" fname gref
    fname="$(_curl "https://sourceforge.net/projects/$proj/best_release.json" \
        | grep -oE '"filename"[^,]*' | sed -E 's/.*"([^"]+)".*/\1/')" || return 1
    gref="$(printf '%s' "$re" | sed -e 's/\./\\./g' -e 's/(@V@)/([0-9][0-9A-Za-z._+-]*)/')"
    printf '%s' "$fname" | grep -oE "$gref" | sed -E "s/$gref/\1/"
}

# --- gnome:{project} ----------------------------------------------------------
probe_gnome() {
    local p="$1" majors major ver
    majors="$(_curl "https://download.gnome.org/sources/$p/" \
        | grep -oE 'href="[0-9]+(\.[0-9]+)?/"' | grep -oE '[0-9]+(\.[0-9]+)?' \
        | sort -V | uniq)" || return 1
    [[ -n "$majors" ]] || return 1
    for major in $(echo "$majors" | tac); do
        ver="$(_curl "https://download.gnome.org/sources/$p/$major/" \
            | grep -oE "$p-[0-9][0-9.]*\.tar\.(xz|gz|bz2|zst)" \
            | sed -E "s/^$p-//; s/\.tar\..*//" | sort -V | tail -1)" || continue
        [[ -n "$ver" ]] && { echo "$ver"; return 0; }
    done
    return 1
}

# --- gnu:{project} -------------------------------------------------------------
probe_gnu() {
    _curl "https://ftp.gnu.org/gnu/$1/" \
        | grep -oE "$1-[0-9][0-9.]*\.tar\.(xz|gz|bz2|lz|zst)" \
        | sed -E "s/^$1-//; s/\.tar\..*//" | sort -V | tail -1
}

# --- dir:{index-url}:{regex-with-(@V@)} ----------------------------------------
probe_dir() {
    local index="${1%%:*}" re="${1#*:}" files gref
    files="$(_curl "$index")" || return 1
    gref="$(printf '%s' "$re" | sed -e 's/\./\\./g' -e 's/(@V@)/([0-9][0-9A-Za-z._+-]*)/')"
    printf '%s' "$files" | grep -oE "$gref" | sed -E "s/$gref/\1/" | sort -V | tail -1
}

run_probe() {
    local spec="$1"
    case "$spec" in
        github:*)      probe_github   "${spec#github:}" ;;
        gh-tags:*)     probe_gh_tags  "${spec#gh-tags:}" ;;
        gl-tags:*)     probe_gl_tags  "${spec#gl-tags:}" ;;
        sf:*)          probe_sf       "${spec#sf:}" ;;
        gnome:*)       probe_gnome    "${spec#gnome:}" ;;
        gnu:*)         probe_gnu      "${spec#gnu:}" ;;
        dir:*)         probe_dir      "${spec#dir:}" ;;
        *)             return 3 ;;
    esac
}
