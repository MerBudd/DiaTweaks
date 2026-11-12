#import "LittleDia.h"
#import "Commands/GroupTabs/GroupTabs.h"
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const kKeyword = @"diatweaks-little-dia";

static NSString *const kManifest = @"{\n"
    @"  \"manifest_version\": 3,\n"
    @"  \"name\": \"DiaTweaks Little Dia\",\n"
    @"  \"description\": \"Opens links from other apps in a small window.\",\n"
    @"  \"version\": \"1\",\n"
    @"  \"permissions\": [\"tabs\", \"search\"],\n"
    @"  \"omnibox\": { \"keyword\": \"%@\" },\n"
    @"  \"background\": { \"service_worker\": \"worker.js\" }\n"
    @"}\n";

// open: a popup with the link, unless `until` has passed: a worker that wakes late finds the link has fallen back to a
// tab. The others name a popup by its tab's ID, or failing that its URL. search: the words, with the profile's search
// engine, in that popup. promote: its page becomes a tab in the last normal window, which comes forward.
static NSString *const kWorker = @"const popupTab = async ({ tabId, url }) => {\n"
    @"  const byId = tabId ? await chrome.tabs.get(tabId).catch(() => null) : null;\n"
    @"  if (byId) return byId;\n"
    @"  const tabs = await chrome.tabs.query({ windowType: 'popup' });\n"
    @"  return tabs.find((tab) => tab.url === url) ?? (tabs.length === 1 ? tabs[0] : null);\n"
    @"};\n"
    @"chrome.omnibox.onInputEntered.addListener(async (text) => {\n"
    @"  const request = JSON.parse(text);\n"
    @"  if (request.action === 'open') {\n"
    @"    const { url, left, top, width, height, until } = request;\n"
    @"    if (Date.now() > until) return;\n"
    @"    return chrome.windows.create({ url, type: 'popup', focused: true, left, top, width, height });\n"
    @"  }\n"
    @"  const tab = await popupTab(request);\n"
    @"  if (!tab) return;\n"
    @"  if (request.action === 'search') return chrome.search.query({ text: request.text, tabId: tab.id });\n"
    @"  if (request.action !== 'promote' || !tab.url) return;\n"
    @"  const normal = await chrome.windows.getLastFocused({ windowTypes: ['normal'] }).catch(() => null);\n"
    @"  if (normal) {\n"
    @"    await chrome.tabs.create({ windowId: normal.id, url: tab.url, active: true });\n"
    @"    await chrome.windows.update(normal.id, { focused: true });\n"
    @"  } else {\n"
    @"    await chrome.windows.create({ url: tab.url, focused: true });\n"
    @"  }\n"
    @"  await chrome.windows.remove(tab.windowId);\n"
    @"});\n";

// Chromium keeps an extension's worker from its first run, whatever its version says, so a changed worker gets a new
// folder, which makes it a new extension.
static NSString *DPExtensionFolder(void) {
    uint32_t hash = 2166136261u;
    for (const char *c = kWorker.UTF8String; *c; c++) hash = (hash ^ (uint8_t)*c) * 16777619u;
    return DPAppSupport([NSString stringWithFormat:@"DiaPatches/little-dia-%08x", hash]);
}

static NSString *gExtensionID;  // Set once Chromium has been told to load it.
static NSError *gWriteError;
static NSTimeInterval gLoaded;  // When Dia started, as systemUptime.
static const NSTimeInterval DPLaunchTime = 20;  // Dia is still launching for this long; a link waits less than this for it.

// Chromium names an unpacked extension after its folder: the SHA-256 of the path, its first 32 hex digits spelt a to p.
static NSString *DPExtensionID(NSString *folder) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    const char *path = folder.fileSystemRepresentation;
    CC_SHA256(path, (CC_LONG)strlen(path), digest);
    NSMutableString *id = [NSMutableString string];
    for (int i = 0; i < 16; i++) [id appendFormat:@"%c%c", 'a' + (digest[i] >> 4), 'a' + (digest[i] & 15)];
    return id;
}

static NSDictionary<NSString *, NSString *> *DPExtensionFiles(void) {
    return @{@"manifest.json" : [NSString stringWithFormat:kManifest, kKeyword], @"worker.js" : kWorker};
}

BOOL DPWriteLittleDiaExtension(BOOL on) {
    NSString *folder = DPExtensionFolder(), *parent = folder.stringByDeletingLastPathComponent;
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *name in [files contentsOfDirectoryAtPath:parent error:nil])
        if ([name hasPrefix:@"little-dia-"] && (![name isEqual:folder.lastPathComponent] || !on))
            [files removeItemAtPath:[parent stringByAppendingPathComponent:name] error:nil];
    gWriteError = nil;
    if (!on) return YES;
    NSError *error;
    BOOL written = [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error];
    for (NSString *name in DPExtensionFiles())
        written = written && [DPExtensionFiles()[name] writeToFile:[folder stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:&error];
    gWriteError = written ? nil : error;
    return written;
}

NSString *DPLittleDiaExtensionProblem(void) {
    if (gWriteError) return [NSString stringWithFormat:@"Couldn’t write %@: %@", DPExtensionFolder(), gWriteError.localizedDescription];
    for (NSString *name in DPExtensionFiles())
        if (![NSFileManager.defaultManager fileExistsAtPath:[DPExtensionFolder() stringByAppendingPathComponent:name]])
            return [NSString stringWithFormat:@"%@ is missing.", [DPExtensionFolder() stringByAppendingPathComponent:name]];
    return nil;
}

void DPInstallLittleDiaExtension(void) {
    gLoaded = NSProcessInfo.processInfo.systemUptime;
    if (!DPWriteLittleDiaExtension(DPLittleDia.on) || !DPLittleDia.on) return;
    DPLoadExtension(DPExtensionFolder());
    gExtensionID = DPExtensionID(DPExtensionFolder());
}

static id DPExtensions(id browser) {
    id context = [browser respondsToSelector:@selector(context)] ? DPMsg(browser, @selector(context)) : nil;
    return [context respondsToSelector:@selector(extensions)] ? DPMsg(context, @selector(extensions)) : nil;
}

// Without a browser it is a launch that has no window yet, but only for a while. Later it is Dia running with every window
// closed: nothing is on its way, and the link would wait for nothing.
BOOL DPLittleDiaStarting(void) {
    id extensions = DPExtensions(DPCommandBrowser());
    if (!extensions) return gExtensionID && NSProcessInfo.processInfo.systemUptime - gLoaded < DPLaunchTime;
    return gExtensionID && [extensions respondsToSelector:@selector(isExtensionSystemReady)] && !DPMsgBool(extensions, @selector(isExtensionSystemReady));
}

// Chromium crashes on input for an extension that isn't loaded and on, as after it's turned off in Extensions.
BOOL DPLittleDiaReady(void) {
    id browser = DPCommandBrowser();
    id extensions = DPExtensions(browser);
    SEL trigger = @selector(triggerExtensionOmniboxInput:inputText:disposition:);
    if (!gExtensionID || ![browser respondsToSelector:trigger] || ![extensions respondsToSelector:@selector(isExtensionSystemReady)]
        || !DPMsgBool(extensions, @selector(isExtensionSystemReady)) || ![extensions respondsToSelector:@selector(getExtensionInfo:)])
        return NO;
    id info = ((id (*)(id, SEL, NSString *))objc_msgSend)(extensions, @selector(getExtensionInfo:), gExtensionID);
    return [info respondsToSelector:@selector(enabled)] && DPMsgBool(info, @selector(enabled));
}

BOOL DPSendToLittleDia(NSDictionary *request) {
    if (!DPLittleDiaReady()) return NO;
    NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    NSString *text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
    if (!text) return NO;
    // The disposition is Chromium's WindowOpenDisposition; the worker ignores it.
    void (*send)(id, SEL, NSString *, NSString *, long) = (void *)objc_msgSend;
    send(DPCommandBrowser(), @selector(triggerExtensionOmniboxInput:inputText:disposition:), gExtensionID, text, 1);
    return YES;
}
