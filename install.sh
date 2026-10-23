#!/bin/bash
# Installs dpkg-caddy-cloudflare-hook on a Debian or Ubuntu server, or removes it with
# --uninstall. Run as root from the repository folder; running it again is harmless.
set -euo pipefail

NAME="dpkg-caddy-cloudflare-hook"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$HERE/usr/local/sbin/$NAME"
CONF_SRC="$HERE/etc/dpkg/dpkg.cfg.d/$NAME"
SERVICE_SRC="$HERE/etc/systemd/system/$NAME-retry.service"
TIMER_SRC="$HERE/etc/systemd/system/$NAME-retry.timer"
MOTD_SRC="$HERE/etc/update-motd.d/90-$NAME"
SCRIPT_DST="/usr/local/sbin/$NAME"
CONF_DST="/etc/dpkg/dpkg.cfg.d/$NAME"
SERVICE_DST="/etc/systemd/system/$NAME-retry.service"
TIMER_DST="/etc/systemd/system/$NAME-retry.timer"
MOTD_DST="/etc/update-motd.d/90-$NAME"
STATE_DIR="/var/lib/$NAME"

# systemd is the init system (sd_booted): only then can units be reloaded or stopped.
systemd_running()
{
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

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
    if [ -f "$STATE_DIR/pending" ]
    then
        echo "$NAME: note: a fallback was active ($(cat -- "$STATE_DIR/pending")); /usr/bin/caddy stays as it is" >&2
    fi
    # The dpkg hook file goes first, so that dpkg never calls a script that is gone.
    rm -f -- "$CONF_DST"
    if systemd_running
    then
        systemctl disable --now "$NAME-retry.timer" >/dev/null 2>&1 || true
    fi
    rm -f -- "$TIMER_DST" "$SERVICE_DST" "$MOTD_DST" "$SCRIPT_DST"
    if systemd_running
    then
        systemctl daemon-reload
    fi
    rm -rf -- "$STATE_DIR"
    echo "$NAME: removed $CONF_DST, $SCRIPT_DST, $SERVICE_DST, $TIMER_DST, $MOTD_DST and $STATE_DIR"
    exit 0
fi

for src in "$SCRIPT_SRC" "$CONF_SRC" "$SERVICE_SRC" "$TIMER_SRC" "$MOTD_SRC"
do
    if [ ! -f "$src" ]
    then
        echo "$NAME: $src not found; run install.sh from the repository folder" >&2
        exit 1
    fi
done

# The dpkg hook file goes in last: dpkg must never see a hook whose script is not there yet.
# The timer is installed but not enabled; the hook enables it only during a fallback.
install -D -m 755 -- "$SCRIPT_SRC" "$SCRIPT_DST"
install -D -m 644 -- "$SERVICE_SRC" "$SERVICE_DST"
install -D -m 644 -- "$TIMER_SRC" "$TIMER_DST"
install -D -m 755 -- "$MOTD_SRC" "$MOTD_DST"
if systemd_running
then
    systemctl daemon-reload
fi
install -D -m 644 -- "$CONF_SRC" "$CONF_DST"

echo "$NAME: installed $("$SCRIPT_DST" --version | awk '{ print $2 }')"
for dst in "$SCRIPT_DST" "$SERVICE_DST" "$TIMER_DST" "$MOTD_DST" "$CONF_DST"
do
    echo "  $dst"
done

# Run it once now: silent when Caddy is not installed or already has the module,
# otherwise it adds the module and restarts Caddy right away.
"$SCRIPT_DST"
echo "$NAME: check done"
