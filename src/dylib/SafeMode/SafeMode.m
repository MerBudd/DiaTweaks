#import "SafeMode/SafeMode.h"
#import <dlfcn.h>
#import <mach-o/loader.h>

// Shorter-lived launches that don't quit normally count as crashes. Long, since patches often crash on a first resize or new tab.
static const int64_t DPSurviveSeconds = 180;

NSInteger DPSafeMode;
static NSURL *DPStateURL;
static NSMutableDictionary *DPState;

static NSString *DPBuildUUID(const struct mach_header_64 *header) {
    const struct load_command *command = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const uint8_t *)command + command->cmdsize))
        if (command->cmd == LC_UUID) return [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
    return @"";
}

// A launch that never got to survive only counts if macOS wrote a crash report for it. A kill, from a force quit or a script, leaves none.
static BOOL DPCrashed(NSDictionary *state) {
    NSDate *launched = state[@"launched"];
    if (!launched) return YES;
    NSString *prefix = [NSProcessInfo.processInfo.processName stringByAppendingString:@"-"];
    NSString *pid = [NSString stringWithFormat:@"\"pid\" : %@,", state[@"pid"]];
    NSURL *reports = [NSFileManager.defaultManager.homeDirectoryForCurrentUser URLByAppendingPathComponent:@"Library/Logs/DiagnosticReports"];
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:reports includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil]) {
        NSDate *modified;
        [url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        if (![url.lastPathComponent hasPrefix:prefix] || ![url.pathExtension isEqual:@"ips"] || [modified compare:launched] != NSOrderedDescending) continue;
        if ([[NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] containsString:pid]) return YES;
    }
    return NO;
}

static void DPSurvived(void) {
    if (![DPState[@"launching"] boolValue]) return;
    DPState[@"launching"] = @NO;
    [DPState writeToURL:DPStateURL error:nil];
}

void DPBeginLaunch(void) {
    Dl_info info;
    dladdr((const void *)DPBeginLaunch, &info);
    DPStateURL = [NSURL fileURLWithPath:[@(info.dli_fname).stringByDeletingLastPathComponent stringByAppendingPathComponent:@"safe-mode.plist"]];
    // A new build may be the fix, so it starts over.
    NSString *build = DPBuildUUID(info.dli_fbase);
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:DPStateURL error:nil];
    DPState = [saved[@"build"] isEqual:build] ? [saved mutableCopy] : [NSMutableDictionary dictionaryWithObject:build forKey:@"build"];
    NSInteger crashes = [DPState[@"crashes"] integerValue];
    if ([DPState[@"launching"] boolValue]) crashes += DPCrashed(DPState);
    else crashes = 0;
    DPSafeMode = [DPState[@"level"] integerValue];
    if (crashes == 2 && DPSafeMode < 2) DPSafeMode++, crashes = 0;
    [DPState addEntriesFromDictionary:@{@"level": @(DPSafeMode), @"crashes": @(crashes), @"launching": @YES, @"launched": NSDate.date, @"pid": @(getpid())}];
    [DPState writeToURL:DPStateURL error:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, DPSurviveSeconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPSurvived(); });
    DPOnQuit(^{ DPSurvived(); });
    // Dia doesn't post NSApplicationWillTerminateNotification, so a normal quit only runs atexit.
    atexit(DPSurvived);
}

void DPLeaveSafeMode(void) {
    DPState = [NSMutableDictionary dictionaryWithObject:DPState[@"build"] forKey:@"build"];
    [DPState writeToURL:DPStateURL error:nil];
}
