#import "StdPatch/StdPatch.h"
#import "Updates/Updates.h"
#import <mach-o/getsect.h>
#import <mach-o/ldsyms.h>

// Patching costs Dia the entitlement Apple Passwords requires of browsers, so diapatch runs requests in the unpatched Dia.

extern DPPatch DPPasskeys;

static NSString *const kExtensionID = @"ljonmeeapeagnkmjklinbocjbjepecce";  // from the key in extension/manifest.json

static NSString *const kFiles[] = { @"manifest.json", @"page.js", @"bridge.js", @"worker.js" };

static NSString *DPExtensionFolder(void) { return DPAppSupport(@"DiaPatches/passkeys-extension"); }

// Dia's Chromium looks for native messaging hosts in Chrome's folder.
static NSString *DPHostManifestPath(void) { return DPAppSupport(@"Google/Chrome/NativeMessagingHosts/com.diapatches.passkeys.json"); }

static NSError *gWriteError;

static BOOL DPWrite(NSData *data, NSString *path) {
    NSError *error;
    if ([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error]
        && [data writeToFile:path options:NSDataWritingAtomic error:&error])
        return YES;
    gWriteError = error;
    return NO;
}

static BOOL DPSetUpPasskeys(void) {
    gWriteError = nil;
    for (int i = 0; i < 4; i++) {
        NSString *section = [@"__pk_" stringByAppendingString:kFiles[i].stringByDeletingPathExtension];
        unsigned long size = 0;
        uint8_t *bytes = getsectiondata(&_mh_dylib_header, "__TEXT", section.UTF8String, &size);
        if (!bytes || !DPWrite([NSData dataWithBytes:bytes length:size], [DPExtensionFolder() stringByAppendingPathComponent:kFiles[i]])) return NO;
    }
    NSDictionary *manifest = @{
        @"name" : @"com.diapatches.passkeys",
        @"description" : @"DiaTweaks passkeys",
        @"path" : DPAppSupport(@"DiaPatches/bin/diapatch"),
        @"type" : @"stdio",
        @"allowed_origins" : @[ [NSString stringWithFormat:@"chrome-extension://%@/", kExtensionID] ],
    };
    return DPWrite([NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil], DPHostManifestPath());
}

static NSString *DPPasskeysProblem(DPPatch *patch) {
    if (gWriteError) return DPWriteProblem(DPExtensionFolder(), gWriteError);
    for (int i = 0; i < 4; i++) {
        NSString *file = [DPExtensionFolder() stringByAppendingPathComponent:kFiles[i]];
        if (![NSFileManager.defaultManager fileExistsAtPath:file]) return [NSString stringWithFormat:@"%@ is missing.", file];
    }
    return DPRelayProblem() ?: DPHostProblem(DPHostManifestPath(), @"com.diapatches.passkeys");
}

static BOOL gExtensionLoaded;

static void DPShowHelper(NSNotification *note) {
    NSRunningApplication *helper = [NSRunningApplication runningApplicationWithProcessIdentifier:[note.object intValue]];
    void (^show)(void) = ^{ [helper activateFromApplication:NSRunningApplication.currentApplication options:NSApplicationActivateAllWindows]; };
    if (![note.name hasSuffix:@"signIn"]) return show();
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Sign in to Dia once for passkeys";
    alert.informativeText = @"Passkeys open in a second copy of Dia, which needs you to sign in with your Dia email once. Your passkey carries on after.";
    NSUInteger browser = [NSApp.orderedWindows indexOfObjectPassingTest:^BOOL(NSWindow *window, NSUInteger i, BOOL *stop) { return window.visible && window.canBecomeMainWindow; }];
    if (browser == NSNotFound) return (void)([alert runModal], show());
    [alert beginSheetModalForWindow:NSApp.orderedWindows[browser] completionHandler:^(NSModalResponse _) { show(); }];
}

static void DPInstallPasskeys(void) {
    if (!DPPasskeys.on) {
        [NSFileManager.defaultManager removeItemAtPath:DPExtensionFolder() error:nil];
        [NSFileManager.defaultManager removeItemAtPath:DPHostManifestPath() error:nil];
        return;
    }
    if (!DPSetUpPasskeys()) return;
    DPLoadExtension(DPExtensionFolder());
    gExtensionLoaded = YES;
    for (NSString *name in @[ @"com.diapatches.passkeys.show", @"com.diapatches.passkeys.signIn" ])
        [NSDistributedNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { DPShowHelper(note); }];
}

static void DPApplyPasskeys(DPPatch *patch) {
    if (patch->on) DPSetUpPasskeys();
    if (patch->on == gExtensionLoaded || patch->on != DPSavedOn(patch) || (patch->on && DPPasskeysProblem(patch))) return;  // the self-test flips patches without saving
    NSAlert *alert = [NSAlert new];
    alert.messageText = patch->on ? @"Relaunch Dia to allow iCloud passkeys" : @"Relaunch Dia to stop using iCloud passkeys";
    [alert addButtonWithTitle:@"Relaunch"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] == NSAlertFirstButtonReturn) DPHandOffAndQuit(@[ @"apply" ]);
}

DP_PATCH(DPPasskeys) {
    .key = @"passkeys",
    .order = 100,
    .title = @"Allow iCloud Passkeys",
    .detail = @"Sign in to sites with passkeys saved in Apple Passwords. A patched Dia can’t reach them, so the original Dia that DiaTweaks keeps opens behind the Touch ID prompt, then quits. Experimental.",
    .symbol = @"person.badge.key.fill",
    .tint = @"systemGreenColor",
    .section = @"Passwords",
    .install = DPInstallPasskeys,
    .apply = DPApplyPasskeys,
    .ready = DPPasskeysProblem,
};
