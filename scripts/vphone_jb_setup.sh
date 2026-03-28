#!/bin/bash
# vphone_jb_setup.sh — First-boot JB finalization script.
#
# Deployed to /cores/ during cfw_install_jb.sh (ramdisk phase).
# Runs automatically via LaunchDaemon on first normal boot.
# Idempotent — safe to re-run on subsequent boots.
#
# Logs to /var/log/vphone_jb_setup.log for host-side monitoring
# via vphoned file browser.

set -uo pipefail

LOG="/var/log/vphone_jb_setup.log"
DONE_MARKER="/var/mobile/.vphone_jb_setup_done"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

# Redirect all output to log
exec > >(tee -a "$LOG") 2>&1

log "=== vphone_jb_setup.sh starting ==="

# ── Check done marker ────────────────────────────────────────
if [ -f "$DONE_MARKER" ]; then
    log "Already completed (marker exists), exiting."
    exit 0
fi

# ── Skip setup wizard (write plist before Setup Assistant checks it) ──
PURPLE_PREFS="/var/mobile/Library/Preferences"
PURPLE_PLIST="$PURPLE_PREFS/com.apple.purplebuddy.plist"
if [ ! -f "$PURPLE_PLIST" ]; then
    mkdir -p "$PURPLE_PREFS"
    chown 501:501 "$PURPLE_PREFS"
    cat > "$PURPLE_PLIST" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>SetupDone</key>
    <true/>
    <key>SetupLastFinishedPhase</key>
    <integer>99</integer>
</dict>
</plist>
PLIST_EOF
    chown 501:501 "$PURPLE_PLIST"
    chmod 0644 "$PURPLE_PLIST"
    log "Setup wizard plist written — killing Setup Assistant to re-check..."
    killall -9 "Setup Assistant" 2>/dev/null || true
    sleep 1
fi

# ── Environment ──────────────────────────────────────────────
export TERM=xterm-256color
export DEBIAN_FRONTEND=noninteractive

# Discover PATH dynamically
P=""
for d in \
    /var/jb/usr/bin /var/jb/bin /var/jb/sbin /var/jb/usr/sbin \
    /iosbinpack64/bin /iosbinpack64/usr/bin /iosbinpack64/sbin /iosbinpack64/usr/sbin \
    /usr/bin /usr/sbin /bin /sbin; do
    [ -d "$d" ] && P="$P:$d"
done
export PATH="${P#:}"
log "PATH=$PATH"

# ── Find boot manifest hash ─────────────────────────────────
BOOT_HASH=""
for d in /private/preboot/*/; do
    b="${d%/}"; b="${b##*/}"
    if [ "${#b}" = 96 ]; then
        BOOT_HASH="$b"
        break
    fi
done
[ -n "$BOOT_HASH" ] || die "Could not find 96-char boot manifest hash"
log "Boot hash: $BOOT_HASH"

JB_TARGET="/private/preboot/$BOOT_HASH/jb-vphone/procursus"
[ -d "$JB_TARGET" ] || die "Procursus not found at $JB_TARGET"
log "JB_TARGET=$JB_TARGET"

# ═══════════ 0/7 REPLACE LAUNCHCTL ═════════════════════════════
# Procursus launchctl crashes (missing _launch_active_user_switch symbol).
# iosbinpack64's launchctl talks to launchd fine and always exits 0,
# which is enough for dpkg postinst/prerm script compatibility.
log "[0/8] Linking iosbinpack64 launchctl into procursus..."
IOSBINPACK_LAUNCHCTL=""
for p in /iosbinpack64/bin/launchctl /iosbinpack64/usr/bin/launchctl; do
    [ -f "$p" ] && IOSBINPACK_LAUNCHCTL="$p" && break
done

if [ -n "$IOSBINPACK_LAUNCHCTL" ]; then
    if [ -f "$JB_TARGET/usr/bin/launchctl" ] && [ ! -L "$JB_TARGET/usr/bin/launchctl" ] && [ ! -f "$JB_TARGET/usr/bin/launchctl.procursus" ]; then
        mv "$JB_TARGET/usr/bin/launchctl" "$JB_TARGET/usr/bin/launchctl.procursus"
        log "  procursus original saved as launchctl.procursus"
    fi
    ln -sf "$IOSBINPACK_LAUNCHCTL" "$JB_TARGET/usr/bin/launchctl"
    mkdir -p "$JB_TARGET/bin"
    ln -sf "$IOSBINPACK_LAUNCHCTL" "$JB_TARGET/bin/launchctl"
    log "  linked usr/bin/launchctl + bin/launchctl -> $IOSBINPACK_LAUNCHCTL"
else
    log "  WARNING: iosbinpack64 launchctl not found"
fi

# ═══════════ 1/7 SYMLINK /var/jb ═════════════════════════════
log "[1/8] Creating /private/var/jb symlink..."
CURRENT_LINK=$(readlink /private/var/jb 2>/dev/null || true)
if [ "$CURRENT_LINK" = "$JB_TARGET" ]; then
    log "  Symlink already correct"
else
    ln -sf "$JB_TARGET" /private/var/jb
    log "  /var/jb -> $JB_TARGET"
fi

# ═══════════ 2/7 FIX OWNERSHIP / PERMISSIONS ═════════════════
log "[2/8] Fixing mobile Library ownership..."
mkdir -p /var/jb/var/mobile/Library/Preferences
chown -R 501:501 /var/jb/var/mobile/Library
chmod 0755 /var/jb/var/mobile/Library
chown -R 501:501 /var/jb/var/mobile/Library/Preferences
chmod 0755 /var/jb/var/mobile/Library/Preferences
log "  Ownership set"

# ═══════════ 3/7 RUN prep_bootstrap.sh ═══════════════════════
log "[3/8] Running prep_bootstrap.sh..."
if [ -f /var/jb/prep_bootstrap.sh ]; then
    NO_PASSWORD_PROMPT=1 /var/jb/prep_bootstrap.sh || log "  prep_bootstrap.sh exited with $?"
    log "  prep_bootstrap.sh completed"
else
    log "  prep_bootstrap.sh already ran (deleted itself), skipping"
fi

# Re-discover PATH after prep_bootstrap
P=""
for d in \
    /var/jb/usr/bin /var/jb/bin /var/jb/sbin /var/jb/usr/sbin \
    /iosbinpack64/bin /iosbinpack64/usr/bin /iosbinpack64/sbin /iosbinpack64/usr/sbin \
    /usr/bin /usr/sbin /bin /sbin; do
    [ -d "$d" ] && P="$P:$d"
done
export PATH="${P#:}"
log "  PATH=$PATH"

# ═══════════ 4/7 CREATE MARKER FILES ═════════════════════════
log "[4/8] Creating marker files..."
for marker in .procursus_strapped .installed_dopamine; do
    if [ -f "/var/jb/$marker" ]; then
        log "  $marker already exists"
    else
        : > "/var/jb/$marker"
        chown 0:0 "/var/jb/$marker"
        chmod 0644 "/var/jb/$marker"
        log "  $marker created"
    fi
done

# ═══════════ 5/7 INSTALL SILEO ═══════════════════════════════
log "[5/8] Installing Sileo..."
SILEO_DEB_PATH="/private/preboot/$BOOT_HASH/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb"

if dpkg -s org.coolstar.sileo >/dev/null 2>&1; then
    log "  Sileo already installed"
else
    if [ -f "$SILEO_DEB_PATH" ]; then
        dpkg -i "$SILEO_DEB_PATH" || log "  dpkg -i sileo exited with $?"
        log "  Sileo installed"
    else
        log "  WARNING: Sileo deb not found at $SILEO_DEB_PATH"
    fi
fi

uicache -a 2>/dev/null || true
log "  uicache refreshed"

# ═══════════ 6/7 APT SETUP ══════════════════════════════════
log "[6/8] Running apt setup..."

# Determine apt sources directory
HAVOC_LIST="/var/jb/etc/apt/sources.list.d/havoc.list"
if [ -d /etc/apt/sources.list.d ] && [ ! -d /var/jb/etc/apt/sources.list.d ]; then
    HAVOC_LIST="/etc/apt/sources.list.d/havoc.list"
fi

if ! grep -rIl 'havoc.app' /etc/apt /var/jb/etc/apt 2>/dev/null | grep -q .; then
    mkdir -p "$(dirname "$HAVOC_LIST")"
    printf '%s\n' 'deb https://havoc.app/ ./' > "$HAVOC_LIST"
    log "  Havoc source added: $HAVOC_LIST"
else
    log "  Havoc source already present"
fi

apt-get -o Acquire::AllowInsecureRepositories=true \
    -o Acquire::AllowDowngradeToInsecureRepositories=true \
    update -qq 2>&1 || log "  apt update exited with $?"
log "  apt update done"

apt-get -o APT::Get::AllowUnauthenticated=true \
    install -y -qq libkrw0-tfp0 2>/dev/null || true
log "  libkrw0-tfp0 done"

apt-get -o APT::Get::AllowUnauthenticated=true \
    upgrade -y -qq 2>/dev/null || true
log "  apt upgrade done"

# ═══════════ 7/7 INSTALL TROLLSTORE LITE ═════════════════════
log "[7/8] Installing TrollStore Lite..."
if dpkg -s com.opa334.trollstorelite >/dev/null 2>&1; then
    log "  TrollStore Lite already installed"
else
    apt-get -o APT::Get::AllowUnauthenticated=true \
        install -y -qq com.opa334.trollstorelite 2>&1
    trollstore_rc=$?
    if [ "$trollstore_rc" -ne 0 ]; then
        die "TrollStore Lite apt install failed with exit code $trollstore_rc"
    fi
    if dpkg -s com.opa334.trollstorelite >/dev/null 2>&1; then
        log "  TrollStore Lite installed"
    else
        die "TrollStore Lite install completed without registering package"
    fi
fi

uicache -a 2>/dev/null || true
log "  uicache refreshed"

# Ensure trollstorehelper is on PATH — location varies by TrollStore Lite version
if ! command -v trollstorehelper >/dev/null 2>&1; then
    tsh=$(find /private/preboot -name trollstorehelper -not -path "*/TrollStoreLite.app/*" 2>/dev/null | head -1)
    if [[ -n "$tsh" ]]; then
        cp "$tsh" /var/jb/usr/bin/trollstorehelper
        chmod +x /var/jb/usr/bin/trollstorehelper
        log "  trollstorehelper copied to PATH from $tsh"
    else
        log "  WARNING: trollstorehelper not found — IPA installs via clone_vm.sh will fail"
    fi
else
    log "  trollstorehelper already on PATH"
fi

# ═══════════ 7b INSTALL APPINST ══════════════════════════════
log "[7b] Installing appinst..."
if dpkg -s appinst >/dev/null 2>&1; then
    log "  appinst already installed"
else
    apt-get -o APT::Get::AllowUnauthenticated=true \
        install -y -qq appinst 2>&1 || log "  appinst apt install exited with $?"
    if dpkg -s appinst >/dev/null 2>&1; then
        log "  appinst installed"
    else
        log "  WARNING: appinst install may have failed"
    fi
fi

# ═══════════ 8/9 INSTALL AND CONFIGURE OPENSSH ════════════════
log "[8/9] Installing OpenSSH..."
if dpkg -s openssh >/dev/null 2>&1; then
    log "  OpenSSH already installed"
else
    apt-get -o APT::Get::AllowUnauthenticated=true \
        install -y -qq openssh 2>&1 || log "  openssh apt install exited with $?"
    if dpkg -s openssh >/dev/null 2>&1; then
        log "  OpenSSH installed"
    else
        log "  WARNING: OpenSSH install may have failed — check dpkg output above"
    fi
fi

# Allow root login — procursus openssh defaults to prohibit-password
# $JB_TARGET is the absolute preboot path (e.g. /private/preboot/<hash>/jb-vphone/procursus)
# /var/jb is a symlink to it but may not be visible here; use the raw path first.
SSHD_CONFIG=""
for p in \
    "$JB_TARGET/etc/ssh/sshd_config" \
    /var/jb/etc/ssh/sshd_config \
    /procursus/etc/ssh/sshd_config \
    /etc/ssh/sshd_config; do
    [ -f "$p" ] && SSHD_CONFIG="$p" && break
done

if [ -n "$SSHD_CONFIG" ]; then
    if grep -q "PermitRootLogin" "$SSHD_CONFIG"; then
        sed -i 's/.*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    else
        echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
    fi
    log "  PermitRootLogin yes set in $SSHD_CONFIG"
else
    log "  WARNING: sshd_config not found, PermitRootLogin not set"
fi

# Set root password — pipe new+confirm to passwd (root needs no old password)
printf 'alpine\nalpine\nalpine\n' | passwd root 2>/dev/null && \
    log "  root password set" || \
    log "  WARNING: passwd root failed — root SSH may not work"

# Generate SSH host keys (openssh postinst may not have done this)
SSHD_BIN=""
for p in "$JB_TARGET/usr/sbin/sshd" /var/jb/usr/sbin/sshd; do
    [ -f "$p" ] && SSHD_BIN="$p" && break
done
if [ -n "$SSHD_BIN" ]; then
    ssh-keygen -A 2>/dev/null || log "  WARNING: ssh-keygen -A failed"
    log "  SSH host keys generated"
fi

# Start sshd directly for this boot — com.vphone.sshd LaunchDaemon handles
# subsequent reboots via KeepAlive.
if [ -n "$SSHD_BIN" ]; then
    pkill -f "$SSHD_BIN" 2>/dev/null || true
    sleep 1
    "$SSHD_BIN"
    log "  sshd started: $SSHD_BIN"
else
    log "  WARNING: sshd binary not found"
fi

# ═══════════ 9/10 INSTALL FRIDA SERVER ═══════════════════════
log "[9/10] Installing Frida server..."

# Add Frida apt source if not present
FRIDA_LIST="$JB_TARGET/etc/apt/sources.list.d/frida.list"
if ! grep -rIl 'build.frida.re' /etc/apt /var/jb/etc/apt 2>/dev/null | grep -q .; then
    mkdir -p "$(dirname "$FRIDA_LIST")"
    printf '%s\n' 'deb https://build.frida.re ./' > "$FRIDA_LIST"
    log "  Frida source added: $FRIDA_LIST"
    apt-get -o Acquire::AllowInsecureRepositories=true \
        -o Acquire::AllowDowngradeToInsecureRepositories=true \
        update -qq 2>&1 || log "  apt update (frida) exited with $?"
else
    log "  Frida source already present"
fi

if dpkg -s re.frida.server >/dev/null 2>&1; then
    log "  Frida server already installed"
else
    apt-get -o APT::Get::AllowUnauthenticated=true \
        install -y -qq re.frida.server 2>&1 || log "  frida-server apt install exited with $?"
    if dpkg -s re.frida.server >/dev/null 2>&1; then
        log "  Frida server installed"
    else
        log "  WARNING: Frida server install may have failed — check dpkg output above"
    fi
fi

# ═══════════ 10/10 SHELL PROFILES FOR SSH ═══════════════════════
log "[10/10] Setting up shell profiles for SSH..."
# .bashrc  — non-login interactive shells (dropbear default)
# .bash_profile — login shells (some SSH configurations)
# Both source /var/jb/etc/profile to get the full JB PATH.
for profile in /var/root/.bashrc /var/root/.bash_profile; do
    if [ ! -f "$profile" ]; then
        printf '%s\n' '# Source JB environment' '[ -r /var/jb/etc/profile ] && . /var/jb/etc/profile' > "$profile"
        log "  $profile created"
    else
        log "  $profile already exists, skipping"
    fi
done

# ═══════════ DONE ════════════════════════════════════════════
: > "$DONE_MARKER"
log "=== vphone_jb_setup.sh complete ==="
