# vphone-cli — Device Interaction Guide

## SSH Port Mapping

| VM  | SSH Port |
|-----|----------|
| vm4 | 2234     |
| vm5 | 2235     |
| vm6 | 2236     |
| vm7 | 2237     |
| vm8 | 2238     |

Formula: `2230 + VM number`

---

## Boot a Device

```bash
make VM_DIR=vm8 boot
```

---

## SSH Access

```bash
# 1. Find UDID
./.limd/bin/idevice_id -l

# 2. Start tunnel
./.limd/bin/iproxy -u <UDID> <PORT> 22 &

# 3. Connect (password: alpine for both)
ssh root@127.0.0.1 -p <PORT>
ssh mobile@127.0.0.1 -p <PORT>
```

---

## Screenshot

```bash
./.limd/bin/idevicescreenshot -u <UDID> screenshot.png
```

---

## Install a Decrypted IPA Over SSH

```bash
scp -P <PORT> app.ipa root@127.0.0.1:/tmp/app.ipa
ssh root@127.0.0.1 -p <PORT> "appinst /tmp/app.ipa"
```

---

## Frida

```bash
frida-ps -U                          # processes on first device
frida-ps --device <UDID>             # specific device
frida -U -n "AppName" -l script.js   # attach with script
```

---

## Run a Shell Command on Device

```bash
ssh root@127.0.0.1 -p <PORT> "<command>"
```

---

## Check First-Boot Setup Progress

```bash
tail -f /var/log/vphone_jb_setup.log
```

---

## Provision a New Device

```bash
VPHONE_SUDO_PASSWORD='<mac-password>' ./provision_device.sh vm9
```

After provisioning: boot with `make VM_DIR=vm9 boot`, go through the iOS setup wizard (skip everything, avoid Japan/EU region), wait ~10 min for on-device setup to complete, then SSH is available.

---

## Pre-installed on Every Device

| Package         | Purpose                  |
|-----------------|--------------------------|
| OpenSSH         | SSH server (port 22)     |
| Frida server    | Dynamic instrumentation  |
| Sileo           | Package manager          |
| TrollStore Lite | IPA installer (GUI)      |
| appinst         | IPA installer (SSH/CLI)  |
| libkrw0-tfp0    | Kernel read/write        |

---

## Key Paths on Device

| Path | Description |
|------|-------------|
| `/var/jb` | Symlink to procursus bootstrap |
| `/var/jb/usr/bin` | JB binaries (apt, dpkg, etc.) |
| `/cores/` | Hook dylibs + setup scripts |
| `/var/log/vphone_jb_setup.log` | First-boot setup log |
| `/var/mobile/.vphone_jb_setup_done` | Marker — setup completed |
