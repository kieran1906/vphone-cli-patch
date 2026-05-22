# Quickstart: Clone, Boot & Interact

Spin up a new vphone from an existing VM, install an app, and interact with the device.

---

## 1. Clone

```bash
# Clone vm2 → vm5 (instant — APFS copy-on-write, no extra disk used)
./clone_vm.sh vm2 vm5
```

This copies the full disk image and clears the machine identifier so a fresh UDID is generated on first boot.

---

## 2. Clone + auto-install apps

`clone_vm.sh` can boot the clone, install packages, and wipe browser state in one shot:

```bash
# Clone, boot, install a local IPA, wipe Safari
./clone_vm.sh vm2 vm5 --ipas "/path/to/app.ipa"

# Same but from a URL
./clone_vm.sh vm2 vm5 --ipas "https://example.com/app.ipa"

# Mix local paths and URLs — works for both --ipas and --tweaks
./clone_vm.sh vm2 vm5 \
  --tweaks "https://example.com/tweak1.deb /local/tweak2.deb" \
  --ipas "/path/to/app1.ipa https://example.com/app2.ipa"

# Clone only (no install, no boot — just the disk copy)
./clone_vm.sh vm2 vm5
```

When `--tweaks` or `--ipas` are provided, clone_vm.sh will:
1. APFS-clone the source VM
2. Boot the new VM automatically
3. Wait for SSH to come up
4. Download and install each `.deb` via `dpkg`
5. Download and install each `.ipa` via `trollstorehelper`
6. Wipe all browser/identity state (Safari history, cookies, WebKit storage, keychain web creds, DNS cache)
7. Run `uicache` to refresh the app grid

IPAs are installed via TrollStore (pre-installed on every device). Tweaks are installed via dpkg/apt.

---

## 3. Boot an existing clone

For VMs that are already cloned and set up, use `boot_vm.sh`:

```bash
# Basic boot
./boot_vm.sh vm5

# With residential proxy
./boot_vm.sh vm5 --proxy-mode socks5 --proxy-line 'host:port:user:pass'

# Kitchen sink: proxy + block WebRTC + set timezone + wipe Safari on start
./boot_vm.sh vm5 --proxy-mode socks5 --proxy-line 'host:port:user:pass' \
  --webrtc-disable --timezone America/New_York --clear-safari
```

### boot_vm.sh flags

| Flag | What it does |
|------|-------------|
| `--proxy-mode socks5\|http` | Proxy type — `socks5` (default) or `http` (e.g. iproyal) |
| `--proxy-line host:port:user:pass` | Upstream proxy credentials. Starts a local forwarder on the Mac and configures the device to route through it |
| `--clear-safari` | Wipes Safari history, cookies, WebKit storage, keychain web creds, Spotlight web index, keyboard learned words, Siri suggestions, Biome activity streams, and DuetExpertCenter caches. Kills and restarts Safari + mDNSResponder |
| `--webrtc-disable` | Writes a managed preference to disable WebRTC in Safari (prevents STUN IP leak through the proxy) |
| `--timezone TZ` | Sets the device timezone (e.g. `America/New_York`, `Europe/London`) |

`boot_vm.sh` handles: VM start, SSH wait, proxy setup, Frida SSH tunnel, and prints connection info when ready. Ctrl+C cleanly shuts everything down.

---

## 4. Install an IPA at boot (GUI method)

The vphone-cli binary has a built-in `--install-ipa` flag that auto-installs over the guest control channel (vsock) once the VM finishes booting:

```bash
# Direct binary usage (after make build)
./build/vphone-cli boot --config vm5/config.plist --install-ipa /path/to/app.ipa
```

This uses the in-VM `vphoned` daemon — no SSH needed. Works with `.ipa` and `.tipa` files. The app appears on the home screen once the install completes.

---

## 5. Install an IPA manually over SSH

If the device is already running:

```bash
# SCP the file to the device, then install with appinst
scp -P 2235 app.ipa root@127.0.0.1:/tmp/app.ipa
ssh root@127.0.0.1 -p 2235 "appinst /tmp/app.ipa"
```

`appinst` is pre-installed on every device. Password is `alpine`.

---

## 6. Device interaction (device.py)

`device.py` is the main automation tool. It talks to the VM over a Unix socket (no window focus needed) and uses Frida for screenshots and accessibility queries.

```bash
# Set which device to talk to (port = 2230 + VM number)
python3 device.py --ssh-port 2235 COMMAND
```

### Tap

```bash
# Tap by coordinates (430x932 iOS logical point space)
python3 device.py --ssh-port 2235 tap 215 466

# Tap by visible text (takes a screenshot, runs OCR, taps the match)
python3 device.py --ssh-port 2235 tap 'Settings'
python3 device.py --ssh-port 2235 tap 'Allow'

# Tap by accessibility label (queries the UI tree via Frida, no screenshot needed)
python3 device.py --ssh-port 2235 tap_label 'Safari'
python3 device.py --ssh-port 2235 tap_label 'Back'
```

### Swipe

Named presets so you don't need to remember coordinates:

```bash
python3 device.py --ssh-port 2235 swipe down          # scroll down (medium)
python3 device.py --ssh-port 2235 swipe down_long      # scroll down (large)
python3 device.py --ssh-port 2235 swipe down_short     # scroll down (small)
python3 device.py --ssh-port 2235 swipe up             # scroll up (medium)
python3 device.py --ssh-port 2235 swipe up_long         # scroll up (large)
python3 device.py --ssh-port 2235 swipe up_long_bottom  # swipe up from home bar (dismiss lock screen)
python3 device.py --ssh-port 2235 swipe right           # back gesture
python3 device.py --ssh-port 2235 swipe left            # swipe left

# Or raw coordinates
python3 device.py --ssh-port 2235 swipe 215 700 215 200
```

### Home button

```bash
python3 device.py --ssh-port 2235 home
```

### Launch and close apps

```bash
python3 device.py --ssh-port 2235 launch_app com.apple.mobilesafari
python3 device.py --ssh-port 2235 close_app com.apple.mobilesafari
```

Common bundle IDs:

| App | Bundle ID |
|-----|-----------|
| Safari | `com.apple.mobilesafari` |
| Settings | `com.apple.Preferences` |
| App Store | `com.apple.AppStore` |
| Files | `com.apple.DocumentsApp` |
| Photos | `com.apple.mobileslideshow` |

### Screenshot

```bash
python3 device.py --ssh-port 2235 screenshot              # saves screenshot.png
python3 device.py --ssh-port 2235 screenshot /tmp/shot.png # custom path
```

Uses a Frida agent to capture the screen via `_UICreateScreenUIImage`, then SCPs it back to the Mac.

### Inspect the screen

```bash
# List all visible UI elements (accessibility labels + positions)
python3 device.py --ssh-port 2235 dump_elements

# OCR-only scan (faster, no Frida attach — just screenshot + Vision)
python3 device.py --ssh-port 2235 dump_ocr
```

`dump_elements` queries SpringBoard and the foreground app via Frida accessibility agents, then optionally adds OCR results. Useful for finding the right label to pass to `tap_label`.

### Using device.py as a Python library

```python
import device

device.SSH_PORT = 2235

device.tap(215, 466)                            # tap coordinates
device.tap_text('Continue')                      # OCR tap
device.tap_label('Safari')                       # accessibility tap
device.swipe('down')                             # scroll preset
device.home()                                    # home button
device.launch_app('com.apple.mobilesafari')      # open app
device.close_app('com.apple.mobilesafari')       # kill app
device.screenshot('screen.png')                  # save screenshot
elements = device.dump_elements()                # get UI tree
```

---

## 7. Standalone mouse injection (mac_tap.py)

`mac_tap.py` injects CGEvent clicks directly into the VM window. Simpler than `device.py` but requires the VM window to be visible on screen.

```bash
python3 mac_tap.py tap 215 466           # tap at iOS coordinates
python3 mac_tap.py swipe 215 700 215 200 # swipe
python3 mac_tap.py home                  # home button (right-click)
python3 mac_tap.py info                  # show window bounds
```

For most use cases, prefer `device.py` — it works with the window hidden or minimized.

---

## 8. Trust pairing (automated)

Trust pairing is handled automatically — you shouldn't need to do anything manually:

- **On every boot**, `boot_proxy.sh` auto-taps the Trust dialog button via `device.py` ~4 seconds after the device appears. This works even if the pair record is missing.
- **When cloning**, the source VM's pair record is cloned with the disk image, so the Trust dialog usually never appears at all.
- **`trust_pair.sh`** pre-seeds the lockdownd pair record properly (both device-side and Mac-side) so the dialog is permanently suppressed. Only needed if you're having pairing issues:

```bash
./scripts/trust_pair.sh 2235   # port = 2230 + VM number
```

The pairing assets live in `~/.vphone/pairing/` and are reused across all clones.

---

## 9. Provision from scratch (no source VM)

```bash
VPHONE_SUDO_PASSWORD='xxx' ./provision_device.sh vm5
```

Full pipeline: create VM, download firmware, patch, restore, ramdisk, install CFW+JB. Much slower than cloning. After it finishes: boot, go through the iOS setup wizard (skip everything, avoid Japan/EU region), wait ~10 min for on-device JB setup to complete.

---

## Port reference

Formula: base port + VM number (e.g. vm5 = 5)

| Port type | Base | vm2  | vm3  | vm4  | vm5  | vm8  | vm9  |
|-----------|------|------|------|------|------|------|------|
| SSH       | 2230 | 2232 | 2233 | 2234 | 2235 | 2238 | 2239 |
| Proxy     | 12320| 12322| 12323| 12324| 12325| 12328| 12329|
| Frida     | 27040| 27042| 27043| 27044| 27045| 27048| 27049|

## Pre-installed on every device

| Package | Purpose |
|---------|---------|
| OpenSSH | SSH server (port 22) |
| Frida server | Dynamic instrumentation |
| Sileo | Package manager |
| TrollStore Lite | IPA installer (GUI + trollstorehelper CLI) |
| appinst | IPA installer (SSH/CLI) |
| libkrw0-tfp0 | Kernel read/write |
