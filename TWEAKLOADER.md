# TweakLoader — Substrate-Compatible Tweak Injection for vphone

## What It Is

TweakLoader is a lean dylib that loads user tweaks from `/var/jb/Library/MobileSubstrate/DynamicLibraries/` into matching processes at launch. It replaces the role that MobileSubstrate/Substitute/Ellekit's built-in loader would normally play, but is purpose-built for the vphone JB runtime where those full frameworks aren't available.

It is compiled from source during `cfw_install_jb.sh` (JB-4 phase) and installed to `/var/jb/usr/lib/TweakLoader.dylib`. The BaseBin `systemhook.dylib` injects it into every spawned process.

## Why It's Needed

The vphone JB stack uses a minimal BaseBin (systemhook + launchdhook + libellekit) that handles process injection and hook dispatch, but does **not** include a tweak loader. Without TweakLoader, substrate-style `.dylib` + `.plist` tweaks sitting in `DynamicLibraries/` would never get loaded.

## How It Works

1. `systemhook.dylib` injects TweakLoader into every process via `DYLD_INSERT_LIBRARIES`
2. TweakLoader's `__attribute__((constructor))` fires at process start
3. It checks if the process is an app (path contains `.app/`) — skips daemons, shells, and boot-critical processes to avoid destabilizing the system
4. It enumerates `.plist` files in `/var/jb/Library/MobileSubstrate/DynamicLibraries/`
5. For each plist, it checks the `Filter` dictionary against the current process
6. If the filter matches, it `dlopen`s the corresponding `.dylib`

## Filter Matching (Substrate-Compatible)

Standard substrate tweaks use a filter plist with `Bundles` and/or `Executables` keys:

```xml
<key>Filter</key>
<dict>
    <key>Bundles</key>
    <array>
        <string>com.apple.UIKit</string>
    </array>
</dict>
```

### vphone TweakLoader enhancements over the upstream PR

The upstream TweakLoader (PR #173) only checked `NSBundle.mainBundle.bundleIdentifier` for bundle matching. This failed for framework-based filters like `com.apple.UIKit` because:

1. **NSBundle not registered at constructor time** — at `__attribute__((constructor))` time, framework bundles like UIKit aren't registered with `NSBundle.allFrameworks` yet, even though the dylib is loaded
2. **AND vs OR semantics** — the upstream used AND logic for `Bundles` + `Executables`, but real Substrate uses OR (match either)

Our version fixes both:

- **dyld image scanning** — instead of NSBundle APIs, we scan `_dyld_image_count()` / `_dyld_get_image_name()` directly and match framework names derived from bundle IDs (e.g. `com.apple.UIKit` → look for `/UIKit.framework/` in loaded images). This works at any point during process startup
- **OR semantics** — `Bundles` and `Executables` filter keys are OR'd, matching real Substrate behavior

## Installing a Tweak (.deb)

```bash
# Copy to device
scp -P <PORT> tweak.deb root@127.0.0.1:/tmp/tweak.deb

# Install
ssh root@127.0.0.1 -p <PORT> "/var/jb/usr/bin/dpkg -i /tmp/tweak.deb"

# Respring to load
ssh root@127.0.0.1 -p <PORT> "killall -9 SpringBoard"
```

## Signing Requirements

Tweaks installed via deb need to be signed with the VM's signing certificate to pass code page validation. For fat binaries (arm64 + arm64e), sign each slice separately then recombine:

```bash
# Pull from device
scp -P <PORT> root@127.0.0.1:/var/jb/Library/MobileSubstrate/DynamicLibraries/Tweak.dylib /tmp/Tweak.dylib

# Thin, sign each arch, recombine
lipo /tmp/Tweak.dylib -thin arm64 -output /tmp/Tweak_a64.dylib
lipo /tmp/Tweak.dylib -thin arm64e -output /tmp/Tweak_a64e.dylib
ldid -S -M "-K<vm-dir>/cfw_input/signcert.p12" /tmp/Tweak_a64.dylib
ldid -S -M "-K<vm-dir>/cfw_input/signcert.p12" /tmp/Tweak_a64e.dylib
lipo -create /tmp/Tweak_a64.dylib /tmp/Tweak_a64e.dylib -output /tmp/Tweak_signed.dylib

# Push back
scp -P <PORT> /tmp/Tweak_signed.dylib root@127.0.0.1:/var/jb/Library/MobileSubstrate/DynamicLibraries/Tweak.dylib
```

Note: the `-K` flag must be joined with the path (no space) — `"-Kpath/to/signcert.p12"`, not `-K path/to/signcert.p12`.

## Architecture Requirements

The vphone VM runs arm64e processes. Tweaks must be compiled as fat binaries (`-arch arm64 -arch arm64e`) or arm64e-only to load into system processes like SpringBoard. arm64-only tweaks will only load into third-party arm64 apps.

## Logging

TweakLoader writes to `/var/jb/var/mobile/Library/TweakLoader/tweakloader.log`. Check this file to verify tweaks are loading:

```bash
ssh root@127.0.0.1 -p <PORT> "cat /var/jb/var/mobile/Library/TweakLoader/tweakloader.log"
```

Typical log output:
```
[TweakLoader] Scanning 2 tweak entries for bundle=com.apple.springboard exec=SpringBoard ...
[TweakLoader] Loaded /var/jb/Library/MobileSubstrate/DynamicLibraries/MyTweak.dylib
```

## Source

`scripts/tweakloader/TweakLoader.m` — single-file Objective-C, compiled during CFW install with:

```bash
xcrun --sdk iphoneos clang -arch arm64 -arch arm64e -miphoneos-version-min=15.0 \
    -dynamiclib -fobjc-arc -O3 -framework Foundation -o TweakLoader.dylib TweakLoader.m
```
