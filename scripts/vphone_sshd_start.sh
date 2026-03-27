#!/bin/sh
# vphone_sshd_start.sh — Started by launchd on every boot to keep sshd running.
# Deployed to /cores/ during cfw_install_jb.
SSHD=""
for p in /private/preboot/*/jb-vphone/procursus/usr/sbin/sshd; do
    [ -f "$p" ] && SSHD="$p" && break
done
# Exit 1 if not installed yet — launchd KeepAlive will retry
[ -n "$SSHD" ] || exit 1
exec "$SSHD" -D
