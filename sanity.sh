#!/usr/bin/env bash
# sanity.sh — post-update health checks for mlfs-update.
# Any hard failure => updater flags a boot-time snapshot restore.
# Checks: shell tools, dynamic linker, critical binary linkage,
# desktop stack, nvidia module, and MLFS-specific quirks.

set -u
fail=0
bad() { echo "[sanity] FAIL: $*" >&2; fail=1; }
ok()  { echo "[sanity] ok: $*"; }

# --- basic toolchain/userland -------------------------------------------------
bash -c 'true'                   || bad "bash"
ldconfig -p >/dev/null           || bad "ldconfig"
getent passwd root >/dev/null    || bad "getent/passwd"
systemctl --version >/dev/null   || bad "systemctl"
dbus-daemon --version >/dev/null || bad "dbus-daemon"
sudo -V >/dev/null               || bad "sudo"
curl --version >/dev/null        || bad "curl"

# --- linkage on critical binaries (any "not found" = broken update) -----------
check_ldd() {
    local f="$1"
    [[ -e "$f" ]] || return 0
    if ldd "$f" 2>/dev/null | grep -q "not found"; then
        bad "broken linkage: $f"
    fi
}
for f in \
    /usr/bin/gnome-shell /usr/bin/gdm /usr/bin/Xwayland /usr/bin/gjs \
    /usr/bin/pipewire /usr/bin/wireplumber /usr/bin/pipewire-pulse \
    /usr/bin/dbus-daemon /usr/bin/NetworkManager /usr/bin/nmcli \
    /usr/bin/sudo /usr/bin/pkexec /usr/bin/su /usr/bin/login \
    /usr/bin/systemctl /usr/bin/loginctl /usr/bin/bluetoothctl \
    /usr/bin/gnome-control-center /usr/bin/nautilus /usr/bin/flatpak \
    /usr/sbin/gdm /usr/sbin/NetworkManager /usr/sbin/gdm3 \
    /usr/lib/libmutter-18.so.0 /usr/lib/libcogl*.so* /usr/lib/libpipewire-0.3.so*
do
    check_ldd "$f"
done

# --- desktop session services --------------------------------------------------
systemctl is-enabled gdm.service >/dev/null 2>&1 || bad "gdm not enabled"
systemctl --user --global is-enabled pipewire.service  >/dev/null 2>&1 \
    || warn_note="pipewire user unit not enabled globally"

# --- nvidia -------------------------------------------------------------------
if ! modinfo -F version nvidia >/dev/null 2>&1; then
    bad "nvidia kernel module missing"
fi

# --- MLFS quirks that must never regress --------------------------------------
# /usr/bin/bwrap must NOT be setuid (glycin sandbox breaks icon loading)
if find /usr/bin/bwrap -perm -4000 2>/dev/null | grep -q .; then
    bad "/usr/bin/bwrap is setuid — must be -rwxr-xr-x"
fi
# cert bundle chain used by NIX_SSL_CERT_FILE etc.
[[ -e /etc/pki/tls/certs/ca-bundle.crt ]] || bad "ca-bundle.crt missing"
# modprobe path used by extensions/polkit rules
[[ -x /usr/sbin/modprobe || -x /usr/bin/modprobe ]] || bad "modprobe missing"
# pkexec must be able to pam_open_session (Private Mode depends on it)
[[ -f /etc/pam.d/polkit-1 ]] || bad "/etc/pam.d/polkit-1 missing"
[[ -s /etc/shells ]] || bad "/etc/shells missing/empty"

exit $fail
