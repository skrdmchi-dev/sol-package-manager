PROBE_TIMEOUT="${PROBE_TIMEOUT:-20}"

_curl() { curl -fsSL --max-time "$PROBE_TIMEOUT" --retry 1 -A "sol/1" "$@"; }

_strip_tag() { sed -E 's/^[^0-9]*//; s/_/./g' ; }

probe_github() {
    _curl "https://api.github.com/repos/$1/releases/latest" \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[^"]*"([^"]+)".*/\1/' \
        | _strip_tag
}

probe_gh_tags() {
    _curl "https://api.github.com/repos/$1/tags?per_page=30" \
        | grep -oE '"name"[^,]*' | sed -E 's/.*"([^"]+)".*/\1/' \
        | _strip_tag | grep -E '^[0-9]+(\.[0-9]+)*$' | head -1
}

probe_gl_tags() {
    _curl "https://$1/api/v4/projects/$2/repository/tags?per_page=30" \
        | grep -oE '"name"[^,]*' | sed -E 's/.*"([^"]+)".*/\1/' \
        | _strip_tag | grep -E '^[0-9]+(\.[0-9]+)*$' | head -1
}

probe_http() {
    _curl "$1" | grep -oE 'href="[^"]*[-_][0-9]+[.][0-9]' \
        | sed -E 's/.*[-_]([0-9]+[.][0-9]+).*/\1/' | head -1
}

run_probe() {
    local spec="$1" handler rest
    handler="${spec%%:*}"
    rest="${spec#*:}"
    case "$handler" in
        github:*) probe_github "${rest#github:}" ;;
        gh-tags:*) probe_gh_tags "${rest#gh-tags:}" ;;
        gl-tags:*) 
            local host="${rest#gl-tags:/*}"; local path="${host#*/}"
            probe_gl_tags "${host%%/*}" "$path" ;;
        http:*) probe_http "${rest#http:}" ;;
        *) echo "unknown probe type: $handler"; return 1 ;;
    esac
}
