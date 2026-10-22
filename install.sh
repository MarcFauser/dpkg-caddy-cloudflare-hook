#!/bin/bash
# Installs dpkg-caddy-cloudflare-hook on a Debian or Ubuntu server, or removes it with
# --uninstall. Run as root from the repository folder; running it again is harmless.
set -euo pipefail

NAME="dpkg-caddy-cloudflare-hook"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$HERE/usr/local/sbin/$NAME"
CONF_SRC="$HERE/etc/dpkg/dpkg.cfg.d/$NAME"
SCRIPT_DST="/usr/local/sbin/$NAME"
CONF_DST="/etc/dpkg/dpkg.cfg.d/$NAME"

if [ "$(id -u)" -ne 0 ]
then
    echo "$NAME: run this as root" >&2
    exit 1
fi

if ! command -v dpkg >/dev/null 2>&1
then
    echo "$NAME: dpkg not found; this is for Debian and Ubuntu" >&2
    exit 1
fi

if [ "${1:-}" = "--uninstall" ]
then
    rm -f -- "$CONF_DST" "$SCRIPT_DST"
    echo "$NAME: removed $CONF_DST and $SCRIPT_DST"
    exit 0
fi

if [ ! -f "$SCRIPT_SRC" ] || [ ! -f "$CONF_SRC" ]
then
    echo "$NAME: files not found next to install.sh; run it from the repository folder" >&2
    exit 1
fi

# The hook file goes in last: dpkg must never see a hook whose script is not there yet.
install -D -m 755 -- "$SCRIPT_SRC" "$SCRIPT_DST"
install -D -m 644 -- "$CONF_SRC" "$CONF_DST"

echo "$NAME: installed $("$SCRIPT_DST" --version | awk '{ print $2 }')"
echo "  $SCRIPT_DST"
echo "  $CONF_DST"

# Run it once now: silent when Caddy is not installed or already has the module,
# otherwise it adds the module and restarts Caddy right away.
"$SCRIPT_DST"
echo "$NAME: check done"
