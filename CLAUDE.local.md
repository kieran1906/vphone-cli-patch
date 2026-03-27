# vphone-cli — Device Interaction Guide

## Port Formula

`SSH port = 2230 + VM number`

| VM | SSH Port |
|----|----------|
| vm1 | 2231 |
| vm2 | 2232 |
| vm3 | 2233 |
| vm8 | 2238 |
| vm22 | 2252 |

No UDID needed — everything routes by SSH port.

---

## Boot a Device

```bash
make VM_DIR=vm1 boot
```

iproxy starts automatically on the correct port. SSH is available immediately after boot.

---

## Clone a Device (fast, no provisioning)

```bash
./clone_vm.sh vm1 vm2   # APFS CoW — instant, virtually free disk
make VM_DIR=vm2 boot    # new UDID auto-generated, no setup wizard, Trust auto-tapped
```

---

## SSH Access

```bash
ssh root@127.0.0.1 -p 2231    # vm1 (password: alpine)
ssh root@127.0.0.1 -p 2232    # vm2
```

No manual iproxy needed — boot handles it.

---

## device.py — Automation

All commands take `--ssh-port` to target a specific device.

```bash
# Tap
python3 device.py --ssh-port 2231 tap 215 400
python3 device.py --ssh-port 2231 tap 'Settings'
python3 device.py --ssh-port 2231 tap_label 'Back'

# Swipe presets: down, down_long, down_short, up, up_long, up_short, right, right_short, left, left_short
python3 device.py --ssh-port 2231 swipe down
python3 device.py --ssh-port 2231 swipe X1 Y1 X2 Y2

# Navigation
python3 device.py --ssh-port 2231 home

# Apps
python3 device.py --ssh-port 2231 launch_app com.apple.mobilesafari
python3 device.py --ssh-port 2231 close_app com.apple.mobilesafari

# Inspection
python3 device.py --ssh-port 2231 screenshot screen.png   # saves to cwd
python3 device.py --ssh-port 2231 dump_elements           # accessibility tree + OCR
python3 device.py --ssh-port 2231 dump_ocr                # OCR only, faster
```

Frida connects via SSH tunnel automatically — no DDI or device pairing required.

---

## Screenshot

```bash
python3 device.py --ssh-port 2231 screenshot screen_vm1.png
```

Saves to current working directory unless absolute path given.

---

## Install a Decrypted IPA Over SSH

```bash
scp -P 2231 app.ipa root@127.0.0.1:/tmp/app.ipa
ssh root@127.0.0.1 -p 2231 "appinst /tmp/app.ipa"
```

---

## Run a Shell Command on Device

```bash
ssh root@127.0.0.1 -p 2231 "<command>"
```

---

## Frida

```bash
frida-ps --device <UDID>             # list processes (find UDID via idevice_id -l)
frida -U -n "AppName" -l script.js   # attach with script
```

Or use `device.py` which handles Frida over SSH tunnel internally.

---

## Check First-Boot Setup Progress

```bash
ssh root@127.0.0.1 -p 2231 "tail -f /var/log/vphone_jb_setup.log"
```

---

## Find UDID (if needed)

```bash
./.limd/bin/idevice_id -l
```

---

## Pre-installed on Every Device

| Package | Purpose |
|---------|---------|
| OpenSSH | SSH server (port 22) |
| Frida server | Dynamic instrumentation |
| Sileo | Package manager |
| TrollStore Lite | IPA installer (GUI) |
| appinst | IPA installer (SSH/CLI) |
| libkrw0-tfp0 | Kernel read/write |

---

## Key Paths on Device

| Path | Description |
|------|-------------|
| `/var/jb` | Symlink to procursus bootstrap |
| `/var/jb/usr/bin` | JB binaries (apt, dpkg, etc.) |
| `/cores/` | Hook dylibs + setup scripts |
| `/var/log/vphone_jb_setup.log` | First-boot setup log |
| `/var/mobile/.vphone_jb_setup_done` | Marker — setup completed |
