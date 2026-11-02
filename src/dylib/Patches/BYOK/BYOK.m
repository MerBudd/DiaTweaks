#import "BYOK.h"
#import "Settings/Settings.h"
#include <sys/stat.h>

static NSMenuItem *gBriefsMenuItem;

static NSString *DPAppSupportPath(NSString *subpath) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"DiaPatches"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return subpath ? [dir stringByAppendingPathComponent:subpath] : dir;
}

static NSUserDefaults *DPBYOKDefaults(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:@"com.diapatches"];
}

void DPSyncBYOKConfig(void) {
    NSUserDefaults *defs = DPBYOKDefaults();
    BOOL enabled = DPBYOK.on;
    BOOL useForBriefs = DPBYOKBriefs.on;
    NSString *provider = [defs stringForKey:@"byokProvider"] ?: @"anthropic";
    NSString *apiKey = [defs stringForKey:@"byokApiKey"] ?: @"";
    NSString *model = [defs stringForKey:@"byokModel"] ?: @"";

    NSDictionary *dict = @{
        @"enabled": @(enabled),
        @"provider": provider,
        @"apiKey": apiKey,
        @"model": model,
        @"useForBriefs": @(useForBriefs),
    };

    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&err];
    if (data) {
        NSString *dest = DPAppSupportPath(@"byok.json");
        [data writeToFile:dest atomically:YES];
    }

    if (gBriefsMenuItem) {
        gBriefsMenuItem.state = useForBriefs ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

static void DPInstallHandlerWrapperIfNeeded(void) {
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *distDir = [bundle stringByAppendingPathComponent:@"Contents/Resources/agent-server-resources/dist"];
    NSString *handlerPath = [distDir stringByAppendingPathComponent:@"handler"];
    NSString *realHandlerPath = [distDir stringByAppendingPathComponent:@"handler.real"];
    NSString *byokSourceDir = DPAppSupportPath(@"byok");

    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:distDir]) return;

    // Check if handler is already wrapped
    if ([fm fileExistsAtPath:realHandlerPath]) {
        // Already wrapped, ensure byok helper scripts in dist are up to date
        for (NSString *name in @[@"router.js", @"translator.js", @"providers.js", @"verify.js"]) {
            NSString *src = [byokSourceDir stringByAppendingPathComponent:name];
            NSString *dst = [distDir stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:src]) {
                [fm removeItemAtPath:dst error:nil];
                [fm copyItemAtPath:src toPath:dst error:nil];
            }
        }
        return;
    }

    if (![fm fileExistsAtPath:handlerPath]) return;

    // Rename handler -> handler.real
    NSError *err = nil;
    if (![fm moveItemAtPath:handlerPath toPath:realHandlerPath error:&err]) {
        NSLog(@"[DiaTweaks BYOK] Failed to rename handler to handler.real: %@", err);
        return;
    }

    // Copy handler-wrapper.js and dependencies
    NSString *wrapperSrc = [byokSourceDir stringByAppendingPathComponent:@"handler-wrapper.js"];
    if ([fm fileExistsAtPath:wrapperSrc]) {
        [fm copyItemAtPath:wrapperSrc toPath:handlerPath error:&err];
        chmod(handlerPath.fileSystemRepresentation, 0755);
    }

    for (NSString *name in @[@"router.js", @"translator.js", @"providers.js", @"verify.js"]) {
        NSString *src = [byokSourceDir stringByAppendingPathComponent:name];
        NSString *dst = [distDir stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:src]) {
            [fm copyItemAtPath:src toPath:dst error:nil];
            chmod(dst.fileSystemRepresentation, 0644);
        }
    }
    NSLog(@"[DiaTweaks BYOK] Successfully installed handler wrapper into agent-server dist");
}

static void DPInstallBYOK(void) {
    DPSyncBYOKConfig();
    DPInstallHandlerWrapperIfNeeded();

    DPOnLaunch(^{
        gBriefsMenuItem = DPAddMenuItem(nil, @"Use BYOK for Briefs & Summaries", ^{
            BOOL nextState = !DPBYOKBriefs.on;
            DPSetPatch(&DPBYOKBriefs, nextState, YES);
            DPSyncBYOKConfig();
        });
        gBriefsMenuItem.state = DPBYOKBriefs.on ? NSControlStateValueOn : NSControlStateValueOff;
    });
}

static void DPApplyBYOK(DPPatch *patch) {
    DPSyncBYOKConfig();
}

static void DPApplyBYOKBriefs(DPPatch *patch) {
    DPSyncBYOKConfig();
}

DP_PATCH(DPBYOK) {
    .key = @"byok",
    .order = 50,
    .defaultOn = NO,
    .title = @"Bring Your Own Key (BYOK)",
    .detail = @"Route Dia Chat through your own AI API key and model (Google Gemini, Anthropic, OpenAI, OpenRouter).",
    .symbol = @"key.fill",
    .tint = @"systemOrangeColor",
    .section = @"AI",
    .install = DPInstallBYOK,
    .apply = DPApplyBYOK,
};

DP_PATCH(DPBYOKBriefs) {
    .key = @"byokBriefs",
    .requires = @"byok",
    .defaultOn = NO,
    .title = @"Use for Briefs & Summaries",
    .detail = @"Route morning briefs and summaries through your custom key and model instead of Dia's default.",
    .symbol = @"newspaper.fill",
    .tint = @"systemBlueColor",
    .apply = DPApplyBYOKBriefs,
};
