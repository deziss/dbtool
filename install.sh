#!/usr/bin/env bash
#
# install.sh — install or update dbtool on this machine.
#
# Safe to re-run: the script, the example configs and the systemd units are
# refreshed, while an existing dbtool.yml / dbtool.env is never touched.
#
#   sudo ./install.sh                 # install or update
#   sudo ./install.sh --systemd       # ...and install + enable the nightly timer
#   PREFIX=/opt/dbtool BIN=/usr/local/bin/dbtool CONF=/etc/dbtool ./install.sh
#
set -Eeuo pipefail

PREFIX="${PREFIX:-/opt/dbtool}"
BIN="${BIN:-/usr/local/bin/dbtool}"
CONF="${CONF:-/etc/dbtool}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WITH_SYSTEMD=false
[[ ${1:-} == --systemd ]] && WITH_SYSTEMD=true

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$SRC/dbtool.sh" ]] || die "run this from a dbtool checkout (no dbtool.sh next to install.sh)"
bash -n "$SRC/dbtool.sh" || die "dbtool.sh does not parse — refusing to install it"

OLD=""
[[ -x "$PREFIX/dbtool.sh" ]] && OLD="$("$PREFIX/dbtool.sh" --version 2>/dev/null || true)"
NEW="$(sed -n 's/^readonly DBTOOL_VERSION="\([^"]*\)".*/\1/p' "$SRC/dbtool.sh" | head -1)"

install -d -m 0755 "$PREFIX" "$CONF"
install -m 0755 "$SRC/dbtool.sh" "$PREFIX/dbtool.sh"
ln -sfn "$PREFIX/dbtool.sh" "$BIN"

# templates are always refreshed; real config and secrets never are
install -m 0644 "$SRC/dbtool.example.yml"  "$CONF/dbtool.example.yml"
install -m 0644 "$SRC/dbtool.example.json" "$CONF/dbtool.example.json"
install -m 0600 "$SRC/dbtool.env.example"  "$CONF/dbtool.env.example"

FRESH=false
if [[ ! -f "$CONF/dbtool.yml" ]]; then
    install -m 0640 "$SRC/dbtool.example.yml" "$CONF/dbtool.yml"; FRESH=true
fi
if [[ ! -f "$CONF/dbtool.env" ]]; then
    install -m 0600 "$SRC/dbtool.env.example" "$CONF/dbtool.env"; FRESH=true
fi

if $WITH_SYSTEMD; then
    install -m 0644 "$SRC/systemd/dbtool-backup.service" /etc/systemd/system/dbtool-backup.service
    install -m 0644 "$SRC/systemd/dbtool-backup.timer"   /etc/systemd/system/dbtool-backup.timer
    systemctl daemon-reload
    systemctl enable --now dbtool-backup.timer
    say "systemd timer enabled — check: systemctl list-timers dbtool-backup.timer"
    say "ReadWritePaths in the unit must match defaults.backup_dir in your config"
fi

if [[ -n $OLD && $OLD != "$NEW" ]]; then say "updated dbtool v$OLD -> v$NEW"
elif [[ -n $OLD ]];                then say "reinstalled dbtool v$NEW"
else                                    say "installed dbtool v$NEW"; fi

if $FRESH; then
    say "edit $CONF/dbtool.yml and $CONF/dbtool.env, then run:  dbtool test --deep"
else
    say "config left untouched. Verify with:  dbtool test --deep"
fi
