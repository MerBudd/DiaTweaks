#import "StdPatch/StdPatch.h"
#include <libproc.h>

// The extension asks for Apple's host by name, and Chromium prefers a user's copy of a host over the system's.

extern DPPatch DPICloudPasswords;

static NSString *const kAppleHost = @"/Library/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json";

// Dia reads hosts from Chrome's folder, not its own.
static NSString *DPHostManifestPath(NSString *name) { return DPAppSupport([NSString stringWithFormat:@"Google/Chrome/NativeMessagingHosts/%@.json", name]); }

static NSDictionary *DPHostAt(NSString *path) {
    NSDictionary *host = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] ?: NSData.data options:0 error:nil];
    return [host isKindOfClass:NSDictionary.class] ? host : nil;
}

static NSError *gWriteError;

// Another app's manifest stays, unless it sends its extension straight to Apple's helper, as Better Passwords' does,
// which can't start from a patched Dia. The relay starts that helper for any browser, so it stands in while this is on,
// and the other app's manifest is kept aside to put back after.
static NSError *DPRegisterHost(NSString *name, NSString *description, NSArray<NSString *> *origins, BOOL on) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *path = DPHostManifestPath(name), *relay = DPAppSupport(@"DiaPatches/bin/diapatch");
    NSString *kept = DPAppSupport([NSString stringWithFormat:@"DiaPatches/%@.json", name]);
    NSDictionary *host = DPHostAt(path);
    NSError *error;
    if ([files fileExistsAtPath:path] && ![host[@"path"] isEqual:relay]) {
        if (!on || ![host[@"path"] isEqual:DPHostAt(kAppleHost)[@"path"]]) return nil;
        [files removeItemAtPath:kept error:nil];
        if (![files moveItemAtPath:path toPath:kept error:&error]) return error;
    }
    if (!on) {
        [files removeItemAtPath:path error:nil];
        [files moveItemAtPath:kept toPath:path error:nil];
        return nil;
    }
    NSDictionary *manifest = @{ @"name" : name, @"description" : description, @"path" : relay, @"type" : @"stdio", @"allowed_origins" : origins };
    BOOL written = [files createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error]
        && [[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil] writeToFile:path options:NSDataWritingAtomic error:&error];
    return written ? nil : error;
}

static void DPRegisterHosts(BOOL on) {
    gWriteError = DPRegisterHost(@"com.apple.passwordmanager", @"DiaTweaks relay to iCloud Passwords",
                                 @[ @"chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/", @"chrome-extension://mfbcdcnpokpoajjciilocoachedjkima/" ], on);
    NSError *betterPasswords = DPRegisterHost(@"io.github.fanckush.betterpasswords.bridge", @"DiaTweaks relay for Better Passwords to iCloud Passwords",
                                              @[ @"chrome-extension://ocongmkplhijgajnipnhhggfcjfdilgj/" ], on);
    gWriteError = gWriteError ?: betterPasswords;
}

static NSString *DPICloudPasswordsProblem(DPPatch *patch) {
    NSDictionary *apple = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:kAppleHost] ?: NSData.data options:0 error:nil];
    if (![apple isKindOfClass:NSDictionary.class] || ![apple[@"path"] isKindOfClass:NSString.class] || ![NSFileManager.defaultManager isExecutableFileAtPath:apple[@"path"]])
        return @"This Mac doesn’t have Apple’s iCloud Passwords helper, which comes with macOS 14 and later.";
    if (gWriteError) return [NSString stringWithFormat:@"Couldn’t set up iCloud Passwords: %@", gWriteError.localizedDescription];
    return DPRelayProblem() ?: DPHostProblem(DPHostManifestPath(@"com.apple.passwordmanager"), @"com.apple.passwordmanager");
}

// A hand-off's original Dia outlives this one by seconds, and Dia refuses to start while it runs. This runs before Dia checks.
static void DPStopOriginalDia(void) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    NSString *pristine = DPAppSupport(@"DiaPatches/pristine/Dia.app/Contents/MacOS/Dia").stringByResolvingSymlinksInPath;
    int capacity = proc_listallpids(NULL, 0) + 64;
    pid_t pids[capacity];
    int count = proc_listallpids(pids, capacity * (int)sizeof *pids);
    for (int i = 0; i < count; i++) {
        if (proc_pidpath(pids[i], path, sizeof path) <= 0 || (strcmp(path, pristine.fileSystemRepresentation) && ![@(path) hasPrefix:@"/Applications/.DiaTweaks/"])) continue;
        kill(pids[i], SIGKILL);
        for (int tries = 0; tries < 50 && kill(pids[i], 0) == 0; tries++) usleep(20000);
    }
}

static void DPInstallICloudPasswords(void) {
    DPStopOriginalDia();
    DPRegisterHosts(DPICloudPasswords.on);
}

static void DPApplyICloudPasswords(DPPatch *patch) { DPRegisterHosts(patch->on); }

DP_PATCH(DPICloudPasswords) {
    .key = @"icloudPasswords",
    .order = 101,
    .title = @"Allow iCloud Passwords",
    .detail = @"AutoFill passwords from Apple Passwords with the iCloud Passwords or Better Passwords extension. A patched Dia can’t start Apple’s helper, so each time the extension connects, the original Dia that DiaTweaks keeps opens for a moment, without windows, to start it. Experimental.",
    .symbol = @"apple.passwords key.fill",
    .tint = @"systemGreenColor",
    .section = @"Passwords",
    .install = DPInstallICloudPasswords,
    .apply = DPApplyICloudPasswords,
    .ready = DPICloudPasswordsProblem,
};
