#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <stdarg.h>
#import <unistd.h>

static NSString *const kTweakDir = @"/var/jb/Library/MobileSubstrate/DynamicLibraries";
static NSString *const kLogDir = @"/var/jb/var/mobile/Library/TweakLoader";
static NSString *const kLogPath = @"/var/jb/var/mobile/Library/TweakLoader/tweakloader.log";

static void TLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    if (!message.length) return;

    [[NSFileManager defaultManager] createDirectoryAtPath:kLogDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSString *line = [NSString stringWithFormat:@"%@ [TweakLoader] %@\n",
                      [NSDate.date description],
                      message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;

    int fd = open(kLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    (void)write(fd, data.bytes, data.length);
    close(fd);
}

static NSString *TLExecutableName(void) {
    NSString *argv0 = NSProcessInfo.processInfo.arguments.firstObject;
    if (argv0.length) return argv0.lastPathComponent;
    return NSProcessInfo.processInfo.processName ?: @"unknown";
}

static NSString *TLExecutablePath(void) {
    NSString *argv0 = NSProcessInfo.processInfo.arguments.firstObject;
    return argv0 ?: @"";
}

static BOOL TLShouldRunInCurrentProcess(void) {
    NSString *execPath = TLExecutablePath();
    if (!execPath.length) return NO;

    // vphone's hook runtime injects broadly, including launch-critical daemons
    // like xpcproxy, logd, notifyd, sshd, shells, and helper tools. Restrict the
    // user tweak loader to app binaries only so it does not destabilize boot or
    // process launch paths.
    if ([execPath containsString:@".app/"]) return YES;

    return NO;
}

static BOOL TLArrayContainsString(id obj, NSString *value) {
    if (![obj isKindOfClass:[NSArray class]] || !value.length) return NO;
    for (id item in (NSArray *)obj) {
        if ([item isKindOfClass:[NSString class]] &&
            [(NSString *)item isEqualToString:value]) {
            return YES;
        }
    }
    return NO;
}

// Check if a framework is loaded by scanning dyld images directly.
// At constructor time NSBundle hasn't registered framework bundles yet,
// so NSBundle.allFrameworks/bundleWithIdentifier: won't find them.
// dyld image names are always available.
static BOOL TLIsFrameworkImageLoaded(NSString *bundleID) {
    // Derive framework name from the last component of the bundle ID.
    // "com.apple.UIKit" -> "UIKit.framework/"
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    NSString *last = parts.lastObject;
    if (!last.length) return NO;

    NSString *needle = [NSString stringWithFormat:@"/%@.framework/", last];
    const char *cneedle = needle.UTF8String;

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, cneedle)) return YES;
    }
    return NO;
}

static BOOL TLBundlesFilterMatches(NSArray *bundles) {
    // Match against mainBundle first (app bundle ID)
    NSString *mainID = NSBundle.mainBundle.bundleIdentifier;
    if (mainID.length && TLArrayContainsString(bundles, mainID)) return YES;

    // Match against loaded dyld images (Substrate-compatible).
    // This handles filters like "com.apple.UIKit" which refer to a framework
    // loaded in the process, not the app's own bundle ID.
    for (NSString *bid in bundles) {
        if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
        if (TLIsFrameworkImageLoaded(bid)) return YES;
    }
    return NO;
}

static BOOL TLFilterMatches(NSDictionary *plist, NSString *bundleID, NSString *executableName) {
    NSDictionary *filter = [plist isKindOfClass:[NSDictionary class]] ? plist[@"Filter"] : nil;
    if (![filter isKindOfClass:[NSDictionary class]]) {
        return YES;
    }

    // Substrate semantics: Bundles and Executables are OR'd — match either one.
    BOOL hasBundles = NO, hasExecutables = NO;
    BOOL bundleMatch = NO, execMatch = NO;

    id bundles = filter[@"Bundles"];
    if ([bundles isKindOfClass:[NSArray class]] && [(NSArray *)bundles count] > 0) {
        hasBundles = YES;
        bundleMatch = TLBundlesFilterMatches((NSArray *)bundles);
    }

    id executables = filter[@"Executables"];
    if ([executables isKindOfClass:[NSArray class]] && [(NSArray *)executables count] > 0) {
        hasExecutables = YES;
        execMatch = (executableName.length && TLArrayContainsString(executables, executableName));
    }

    // No filter keys present — load unconditionally
    if (!hasBundles && !hasExecutables) return YES;

    // OR semantics: match if either filter key matches
    return bundleMatch || execMatch;
}

static void TLLoadTweaks(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *execPath = TLExecutablePath();
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *executableName = TLExecutableName();

    if (!TLShouldRunInCurrentProcess()) {
        return;
    }

    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:kTweakDir error:nil];
    if (!files.count) {
        TLLog(@"No tweak files found for bundle=%@ exec=%@ path=%@",
              bundleID, executableName, execPath);
        return;
    }

    TLLog(@"Scanning %lu tweak entries for bundle=%@ exec=%@ path=%@",
          (unsigned long)files.count, bundleID, executableName, execPath);

    for (NSString *filename in files) {
        if (![filename.pathExtension isEqualToString:@"plist"]) continue;

        NSString *plistPath = [kTweakDir stringByAppendingPathComponent:filename];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (![plist isKindOfClass:[NSDictionary class]]) {
            TLLog(@"Skipping unreadable plist %@", plistPath);
            continue;
        }

        if (!TLFilterMatches(plist, bundleID, executableName)) {
            TLLog(@"Filter rejected %@ for bundle=%@ exec=%@", filename, bundleID, executableName);
            continue;
        }

        NSString *baseName = filename.stringByDeletingPathExtension;
        NSString *dylibPath = [[kTweakDir stringByAppendingPathComponent:baseName]
            stringByAppendingPathExtension:@"dylib"];

        if (![fm isExecutableFileAtPath:dylibPath]) {
            TLLog(@"Skipping %@ because dylib is missing or not executable", dylibPath);
            continue;
        }

        void *handle = dlopen(dylibPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        if (handle) {
            TLLog(@"Loaded %@", dylibPath);
        } else {
            const char *err = dlerror();
            TLLog(@"Failed to load %@: %s", dylibPath, err ?: "unknown error");
        }
    }
}

__attribute__((constructor))
static void TweakLoaderInit(void) {
    @autoreleasepool {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            TLLoadTweaks();
        });
    }
}
