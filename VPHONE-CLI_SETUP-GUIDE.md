# vphone-cli Setup Guide

Getting a jailbroken virtual iPhone running on macOS using [vphone-cli](https://github.com/Lakr233/vphone-cli).

---

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4)
- macOS 15+ (Sequoia) or later
- Xcode installed (not just Command Line Tools)
- ~10GB free disk space for first VM (clones are virtually free via APFS CoW)
- Physical access to the Mac for two Recovery Mode reboots (one-time)

---

## Part 1 — Mac Prerequisites (one-time, requires two reboots)

### Reboot 1 — Disable SIP

1. Shut down your Mac
2. Hold the power button until "Loading startup options" appears
3. Click Options → Continue to enter Recovery Mode
4. Open Terminal from the Utilities menu
5. Run:
```bash
csrutil disable
csrutil allow-research-guests enable
```
6. Reboot normally

### Reboot 2 — Set AMFI Boot Args

1. Open Terminal and run:
```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1"
```
2. Reboot normally

### Verify

```bash
csrutil status
# System Integrity Protection status: disabled.

nvram boot-args
# amfi_get_out_of_my_way=1
```

---

## Part 2 — Install Dependencies

```bash
brew install aria2 ideviceinstaller wget gnu-tar openssl@3 ldid-procursus \
             sshpass keystone autoconf automake pkg-config libtool cmake
```

---

## Part 2b — Python Dependencies (for device.py automation)

```bash
pip3 install frida sshpass
```

- `frida` — connects to frida-server on device via SSH tunnel for screenshots and accessibility dumps
- `sshpass` — non-interactive SCP for pulling screenshots off the device

---

## Part 3 — Clone the Repo and Apply Patches

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
```

Then apply the patches from this folder:

```bash
cd vphone-cli-patch
./run_patches.sh ~/vphone-cli
```

`run_patches.sh` takes the path to the cloned repo as a required argument. It copies all patched files into the correct locations and ensures scripts are executable.

After patching, rebuild the vphone-cli app so the new Swift files are compiled in:

```bash
cd ~/vphone-cli
make
```

### What the patches change

**Build / provisioning scripts**

| File | What was changed |
|------|-----------------|
| `scripts/setup_tools.sh` | Adds `-isysroot $(xcrun --show-sdk-path)` to trustcache and insert_dylib builds — required on macOS 26 / recent Xcode |
| `scripts/setup_venv.sh` | Adds `CFLAGS="-isysroot ..."` to pip install and fixes the keystone dylib build with the same sysroot fix |
| `scripts/cfw_install.sh` | Minor fixes for compatibility |
| `scripts/cfw_install_jb.sh` | Removes `seputil --gigalocker-init` (hangs in VM); injects `com.vphone.sshd` LaunchDaemon so sshd starts on every boot |
| `scripts/vphone_jb_setup.sh` | Full first-boot setup: installs OpenSSH, Sileo, TrollStore Lite, appinst, Frida server; sets root password; configures sshd; sets JB PATH |
| `scripts/vphone_sshd_start.sh` | New — deployed to `/cores/`, started by launchd on every boot to keep sshd alive |
| `scripts/boot_proxy.sh` | New — auto-discovers device UDID on boot, starts iproxy on correct port, auto-taps Trust dialog |
| `provision_device.sh` | Fully automated provisioning script; new devices default to 2GB RAM |
| `clone_vm.sh` | New — instant VM cloning via APFS CoW with fresh identity generation |
| `CLAUDE.local.md` | Device interaction reference |

**Swift source (vphone-cli app)**

| File | What was changed |
|------|-----------------|
| `sources/vphone-cli/VPhoneAppDelegate.swift` | Passes VM directory name to touch server |
| `sources/vphone-cli/VPhoneTouchServer.swift` | Socket path now per-VM (`/tmp/vphone-touch-vm1.sock`) — multiple VMs no longer conflict |
| `sources/vphone-cli/VPhoneWindowController.swift` | Passes VM name into touch server init |
| `sources/vphone-cli/VPhoneVirtualMachineView.swift` | Minor fix for drag-and-drop IPA install compatibility |

**Python UI automation (`device.py`)**

No UDID required — everything routes by SSH port. See full command reference below.

**Frida agents (`agent/`)**

| File | Purpose |
|------|---------|
| `agent/screenshot.ts` / `screenshot_agent.js` | Takes GPU-composited screenshots via `_UICreateScreenUIImage()` — captures Metal layers that standard methods miss |
| `agent/accessibility.ts` / `accessibility_agent.js` | UIKit accessibility tree walker (UILabel, UIButton, UIView with AX labels + positions) |

The `.js` files are pre-compiled and used directly. The `.ts` sources are included if you need to recompile (`npm install && npx frida-compile agent/screenshot.ts -o agent/screenshot_agent.js`).

---

## Part 4 — Build Tools

```bash
make setup_tools
```

Should end with:
```
All tools installed.
```

---

## Part 5 — Provision a Device

Run the provision script. It handles everything automatically — VM creation, firmware download, patching, restore, ramdisk, jailbreak install, and first boot.

```bash
VPHONE_SUDO_PASSWORD='your-mac-password' ./provision_device.sh
```

To provision a specific named VM:
```bash
VPHONE_SUDO_PASSWORD='your-mac-password' ./provision_device.sh vm2
```

The script auto-names VMs (`vm2`, `vm3`, etc.) if no name is given.

**This takes 20-40 minutes.** New VMs provision with 2GB RAM by default.

### After provisioning

**1. Boot the device:**
```bash
make VM_DIR=vm2 boot
```

iproxy starts automatically on the correct port — no manual tunnel setup needed.

**2. Go through the iOS setup wizard:**
- Select language and region
- **Do NOT select Japan or EU region** (breaks system app installs)
- Skip WiFi, Face ID, passcode, Apple ID — skip everything optional
- Reach the home screen

**3. Wait 5-10 minutes** for `vphone_jb_setup.sh` to run in the background (installs OpenSSH, Frida, Sileo, TrollStore).

**4. SSH is now available:**
```bash
ssh root@127.0.0.1 -p 2232   # password: alpine
```

Port formula: `2230 + VM number` (vm2=2232, vm3=2233, vm8=2238, vm22=2252)

---

## Cloning a Device (fast — no provisioning needed)

The fastest way to get a new device is to clone an existing provisioned one. Uses APFS copy-on-write so the clone costs virtually no extra disk space initially.

```bash
./clone_vm.sh vm1 vm2
make VM_DIR=vm2 boot
```

- Clones in seconds
- New UDID generated automatically on first boot
- **No setup wizard** — NVRAM state is preserved from source VM
- iproxy auto-starts on the correct port
- Trust dialog auto-tapped

---

## Subsequent Boots

```bash
make VM_DIR=vm2 boot
```

iproxy starts automatically. SSH is available at `root@127.0.0.1 -p <port>` immediately.

---

## Port Reference

| VM | SSH Port |
|----|----------|
| vm1 | 2231 |
| vm2 | 2232 |
| vm3 | 2233 |
| vm8 | 2238 |
| vm22 | 2252 |

Formula: `2230 + VM number`

---

## device.py — Automation Command Reference

All commands use `--ssh-port` to target a specific device. No UDID needed.

```bash
# Tap
python3 device.py --ssh-port 2231 tap 215 400          # tap by coordinates
python3 device.py --ssh-port 2231 tap 'Settings'       # OCR search and tap
python3 device.py --ssh-port 2231 tap_label 'Safari'   # tap by accessibility label

# Swipe
python3 device.py --ssh-port 2231 swipe down
python3 device.py --ssh-port 2231 swipe down_long
python3 device.py --ssh-port 2231 swipe down_short
python3 device.py --ssh-port 2231 swipe up
python3 device.py --ssh-port 2231 swipe up_long
python3 device.py --ssh-port 2231 swipe up_short
python3 device.py --ssh-port 2231 swipe right
python3 device.py --ssh-port 2231 swipe left
python3 device.py --ssh-port 2231 swipe X1 Y1 X2 Y2   # custom coordinates

# Navigation
python3 device.py --ssh-port 2231 home

# Apps
python3 device.py --ssh-port 2231 launch_app com.apple.mobilesafari
python3 device.py --ssh-port 2231 close_app com.apple.mobilesafari

# Inspection
python3 device.py --ssh-port 2231 screenshot screen.png        # saves to current dir
python3 device.py --ssh-port 2231 dump_elements                # accessibility tree + OCR
python3 device.py --ssh-port 2231 dump_ocr                     # OCR only, no Frida attach
```

Frida connects via SSH tunnel automatically — no DDI or device pairing required.

---

## Running Multiple Devices

Each VM uses ~2GB RAM. Boot as many as your Mac has headroom for.

```bash
make VM_DIR=vm1 boot   # terminal 1 — SSH on 2231
make VM_DIR=vm2 boot   # terminal 2 — SSH on 2232
```

Target specific devices with `--ssh-port`:
```bash
python3 device.py --ssh-port 2231 tap 'Settings'   # vm1
python3 device.py --ssh-port 2232 tap 'Settings'   # vm2
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `fw_patch_jb` fails with `no patches found` | Run `make fw_prepare` then retry |
| `restore_get_shsh` says no device | Start `make boot_dfu` first |
| `ramdisk_send` says unable to connect | Start fresh `make boot_dfu` — previous session ended |
| Black screen after ElleKit install | Normal — reboot with `make boot` |
| SSH gives `UNIX authentication refused` | `vphone_jb_setup.sh` not yet complete — wait 5-10 min after reaching home screen |
| Frida protocol error | Frida version mismatch — run `apt-get install -y re.frida.server` on device and `pip3 install --upgrade frida` on Mac |
| Screenshot from wrong device | Ensure `--ssh-port` matches the VM you intend to target |

---

## What `provision_device.sh` Does

| Step | Command | What it does |
|------|---------|--------------|
| 1 | `vm_new` | Creates the VM directory, disk image (2GB RAM), and config |
| 2 | `fw_prepare` | Downloads the iOS IPSW (~10GB, cached after first run) and merges cloudOS |
| 3 | `fw_patch_jb` | Patches iBSS, iBEC, kernelcache and other firmware components for jailbreak |
| 4 | `boot_dfu` + `restore` | Boots VM in DFU mode and restores the patched firmware |
| 5 | `ramdisk_build` + `ramdisk_send` | Builds a custom ramdisk and boots into it |
| 6 | `cfw_install_jb` | Over SSH to the ramdisk: installs procursus bootstrap, BaseBin hooks, launchdhook, TweakLoader, and deploys first-boot setup daemon |

### What `vphone_jb_setup.sh` does (runs on-device at first boot)

This script is deployed to `/cores/` during the ramdisk phase and runs automatically via a LaunchDaemon on first boot. It's idempotent — safe to re-run.

| Step | What it does |
|------|--------------|
| 0 | Replaces procursus `launchctl` with iosbinpack64 version (procursus one crashes) |
| 1 | Creates `/var/jb` symlink to the procursus preboot directory |
| 2 | Fixes ownership on `/var/mobile/Library` |
| 3 | Runs `prep_bootstrap.sh` to initialise procursus |
| 4 | Creates `.procursus_strapped` and `.installed_dopamine` marker files |
| 5 | Installs Sileo (package manager) |
| 6 | Adds Havoc apt repo, runs `apt update`, installs `libkrw0-tfp0`, runs `apt upgrade` |
| 7 | Installs TrollStore Lite |
| 7b | Installs `appinst` (CLI IPA installer for SSH use) |
| 8 | Installs OpenSSH, sets `PermitRootLogin yes`, sets root password, starts sshd |
| 9 | Adds Frida apt repo and installs `re.frida.server` |
| 10 | Writes `/var/root/.bashrc` and `.bash_profile` to source the JB PATH on SSH login |
