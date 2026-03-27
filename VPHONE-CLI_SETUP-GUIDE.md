# vphone-cli Setup Guide

Getting a jailbroken virtual iPhone running on macOS using [vphone-cli](https://github.com/Lakr233/vphone-cli).

---

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4)
- macOS 15+ (Sequoia) or later
- Xcode installed (not just Command Line Tools)
- ~35GB free disk space per VM
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
pip3 install frida pymobiledevice3 sshpass
```

- `frida` — attaches to SpringBoard for screenshots and touch injection
- `pymobiledevice3` — lockdown/USB access to the VM (used by `dump_elements`)
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
| `provision_device.sh` | New — fully automated provisioning script replacing the manual two-terminal workflow |
| `CLAUDE.local.md` | New — Claude Code instructions for device interaction |

**Swift source (vphone-cli app)**

| File | What was changed |
|------|-----------------|
| `sources/vphone-cli/VPhoneTouchServer.swift` | **New file** — Unix socket server at `/tmp/vphone-touch.sock`; accepts newline-delimited JSON commands (`tap`, `swipe`, `home`, `app_launch`, `app_terminate`) and drives touch/app control on the VM without needing the GUI window focused |
| `sources/vphone-cli/VPhoneWindowController.swift` | Passes `control` into `VPhoneTouchServer.start()` so `app_launch`/`app_terminate` commands have access to `VPhoneControl` |
| `sources/vphone-cli/VPhoneVirtualMachineView.swift` | Minor fix for drag-and-drop IPA install compatibility |

**Python UI automation (`device.py`)**

New file — high-level automation API for the VM. Import it or run it as a CLI:

```bash
python3 device.py tap 215 400          # tap at coordinates
python3 device.py tap 'Settings'       # OCR search and tap
python3 device.py tap_label 'Safari'   # find by accessibility label and tap (works for icon-only elements)
python3 device.py tap_label 'Back'     # works for Back button, dock icons, CC controls, etc.
python3 device.py dump_elements        # list all visible elements with positions (accessibility tree, dynamic process detection)
python3 device.py dump_ocr             # fast OCR-only dump — all visible text with x,y coordinates (no Frida attach, Vision only)
python3 device.py swipe down           # scroll using preset
python3 device.py swipe up_long
python3 device.py home
python3 device.py launch_app com.apple.mobilesafari
python3 device.py close_app com.apple.mobilesafari
python3 device.py screenshot screen.png
```

Requires Python packages (see Part 2b below).

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
VPHONE_SUDO_PASSWORD='12345678' ./provision_device.sh
```

To provision a specific named VM:
```bash
VPHONE_SUDO_PASSWORD='your-mac-password' ./provision_device.sh vm2
```

The script auto-names VMs (`vm2`, `vm3`, etc.) if no name is given.

**This takes 20-40 minutes.** When complete the script exits and prints instructions — the device is NOT booted automatically.

### After provisioning

**1. Boot the device:**
```bash
make VM_DIR=vm2 boot
```

**2. Go through the iOS setup wizard:**
- Select language and region
- **Do NOT select Japan or EU region** (breaks system app installs)
- Skip WiFi, Face ID, passcode, Apple ID — skip everything optional
- Reach the home screen

**3. Wait 5-10 minutes** for `vphone_jb_setup.sh` to run in the background (installs OpenSSH, Frida, Sileo, TrollStore).

**4. Start the SSH tunnel and connect:**
```bash
# Start tunnel (UDID shown in provisioning output)
./.limd/bin/iproxy -u <UDID> 2232 22

# Connect
ssh mobile@127.0.0.1 -p 2232
ssh root@127.0.0.1 -p 2232    # password: alpine
```

The exact commands with your UDID and port are printed at the end of the provision script.

---

## Subsequent Boots

After initial setup, just run:
```bash
make VM_DIR=vm2 boot
```

No re-jailbreaking needed — patches are baked into the firmware.

---

## Running Multiple Devices

Each VM is ~32GB on disk and uses 4GB RAM. With 18GB total RAM, run two VMs at a time.

Boot both:
```bash
make VM_DIR=vm2 boot   # terminal 1
make VM_DIR=vm3 boot   # terminal 2
```

SSH into each (each gets its own port):
```bash
ssh root@127.0.0.1 -p 2232   # vm2
ssh root@127.0.0.1 -p 2233   # vm3
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `fw_patch_jb` fails with `no patches found` | Run `make fw_prepare` then retry |
| `restore_get_shsh` says no device | Start `make boot_dfu` first |
| `ramdisk_send` says unable to connect | Start fresh `make boot_dfu` — previous session ended |
| Black screen after ElleKit install | Normal — reboot with `make boot` |
| Frida pairing error | Run `pkill -f frida` then retry |
| SSH gives `UNIX authentication refused` | Run `vphone_jb_setup.sh` not yet complete — wait 5-10 min after reaching home screen |

---

## What `provision_device.sh` Does

The provision script replaces what previously required two terminals and manual coordination. Here's what it runs:

| Step | Command | What it does |
|------|---------|--------------|
| 1 | `vm_new` | Creates the VM directory, disk image, and config |
| 2 | `fw_prepare` | Downloads the iOS IPSW (~10GB, cached after first run) and merges cloudOS |
| 3 | `fw_patch_jb` | Patches iBSS, iBEC, kernelcache and other firmware components for jailbreak |
| 4 | `boot_dfu` + `restore` | Boots VM in DFU mode and restores the patched firmware |
| 5 | `ramdisk_build` + `ramdisk_send` | Builds a custom ramdisk and boots into it |
| 6 | `cfw_install_jb` | Over SSH to the ramdisk: installs procursus bootstrap, BaseBin hooks, launchdhook, TweakLoader, and deploys first-boot setup daemon |

Script exits and prints instructions. Boot, wizard, and SSH are manual steps (see above).

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
