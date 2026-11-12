#import "LittleDia.h"
#import <objc/message.h>

static char DPLittleKey, DPPageKey, DPChromeKey, DPSourceKey, DPPromotedKey;

// Links on their way, oldest first: each {frame, noted, missed}. Chromium makes their windows, and hands over their pages,
// in the order it was asked, so the first window or page to arrive belongs to the first link still waiting.
static NSMutableArray<NSDictionary *> *DPExpected;
static NSMutableArray *DPPendingPages;                     // Pages that came before their window.
static NSPointerArray *DPWindowsAwaitingPage;              // Windows that came before their page.

void DPExpectLittleDiaWindow(NSRect frame, NSDictionary *noted, void (^missed)(void), void (^claimed)(NSWindow *window)) {
    NSMutableDictionary *link = [@{@"frame" : [NSValue valueWithRect:frame], @"noted" : noted, @"missed" : [missed copy]} mutableCopy];
    if (claimed) link[@"claimed"] = [claimed copy];
    [DPExpected addObject:link];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, DPLittleDiaWait * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([DPExpected indexOfObjectIdenticalTo:link] == NSNotFound) return;
        [DPExpected removeObjectIdenticalTo:link];
        if (!DPExpected.count) [DPPendingPages removeAllObjects];
        ((void (^)(void))link[@"missed"])();
    });
}

BOOL DPIsLittleDiaWindow(NSWindow *window) { return window && [DPGet(window, &DPLittleKey) boolValue]; }

id DPLittleDiaPage(NSWindow *window) { return DPGet(window, &DPPageKey); }

// Takes away the title bar: the content runs under it, so Dia's popup bar, pinned to the top, is the top of the window.
static void DPSetChrome(NSWindow *window, BOOL little) {
    NSView *titlebar = [window standardWindowButton:NSWindowCloseButton].superview.superview;
    if (little && !DPGet(window, &DPChromeKey)) {
        DPSet(window, &DPChromeKey, @{@"mask" : @(window.styleMask), @"movable" : @(window.movableByWindowBackground)});
        window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    } else if (!little && DPGet(window, &DPChromeKey)) {
        NSDictionary *saved = DPGet(window, &DPChromeKey);
        DPSet(window, &DPChromeKey, nil);
        window.styleMask = [saved[@"mask"] unsignedIntegerValue];
        window.movableByWindowBackground = [saved[@"movable"] boolValue];
    } else return;
    window.titlebarAppearsTransparent = little;
    window.titleVisibility = little ? NSWindowTitleHidden : NSWindowTitleVisible;
    if (little) window.movableByWindowBackground = YES;
    for (NSWindowButton kind = NSWindowCloseButton; kind <= NSWindowZoomButton; kind++) [window standardWindowButton:kind].hidden = little;
    titlebar.hidden = little;
}

// Claims a popup that appears while a link is on its way. Pages open popups too, but rarely in the same second.
static void DPClaim(NSWindow *window) {
    if (!window || !DPIsKind(window, DPDiaPopupWindow) || DPGet(window, &DPLittleKey) || !DPExpected.count) return;
    NSDictionary *link = DPExpected.firstObject, *noted = link[@"noted"];
    [DPExpected removeObjectAtIndex:0];
    DPSet(window, &DPLittleKey, @YES);
    if ([noted[@"source"] intValue]) DPSet(window, &DPSourceKey, noted[@"source"]);
    if (DPPendingPages.count) {
        DPSet(window, &DPPageKey, DPPendingPages.firstObject);
        [DPPendingPages removeObjectAtIndex:0];
    } else [DPWindowsAwaitingPage addPointer:(__bridge void *)window];
    // With no link left to claim a window, a page still waiting for its window is some other popup's. Kept, it would be
    // taken as the next window's page, and each window after would take the page before its own.
    if (!DPExpected.count) [DPPendingPages removeAllObjects];
    // Chromium adds its title bar to the size it's given, and the title bar is gone here.
    NSRect frame = [link[@"frame"] rectValue];
    [window setFrame:frame display:YES];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    DPRestoreStack(window, noted);
    // Chromium sizes and focuses the new window again a moment later, which can bring Dia's windows forward again.
    __weak NSWindow *weakWindow = window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [weakWindow setFrame:frame display:YES];
        DPRestoreStack(weakWindow, noted);
    });
    DPRefreshLittleDiaWindows();
    if (link[@"claimed"]) ((void (^)(NSWindow *))link[@"claimed"])(window);
}

// Chromium hands Dia each popup's page here, with the popup's own browser.
static void DPBrowser_didCreate(id self, SEL _cmd, id browser, id page, BOOL active) {
    DPCallOriginal(DPBrowser_didCreate, self, browser, page, active);
    long (*type)(id, SEL) = (void *)objc_msgSend;
    if (!page || ![browser respondsToSelector:@selector(type)] || type(browser, @selector(type)) != 2) return;  // 2: a popup
    [DPWindowsAwaitingPage compact];
    if (DPWindowsAwaitingPage.count) {
        NSWindow *window = (__bridge NSWindow *)[DPWindowsAwaitingPage pointerAtIndex:0];
        [DPWindowsAwaitingPage removePointerAtIndex:0];
        DPSet(window, &DPPageKey, page);
        DPRefreshLittleDiaWindows();
    } else if (DPExpected.count) [DPPendingPages addObject:page];
}

static void DPPopupBar_viewDidMoveToWindow(NSView *self, SEL _cmd) {
    DPCallOriginal(DPPopupBar_viewDidMoveToWindow, self);
    DPClaim(self.window);
}

// A link that opens a new tab, from a small window's page, opens in that window instead: tabs here would be out of
// sight, and one in the main window brings it forward. ⌘-click still opens a tab behind, and popups a page opens with a
// size are still popups, since sign-in windows talk back to the page that opened them.
enum { DPCurrentTab = 1, DPForegroundTab = 2 };

static BOOL DPStaysInLittleDia(id page, NSInteger disposition) {
    if (disposition != DPForegroundTab || (NSEvent.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift))) return NO;
    for (NSWindow *window in NSApp.windows)
        if (DPIsLittleDiaWindow(window) && DPLittleDiaPage(window) == page) return YES;
    return NO;
}

// The same link, as if it stayed in its page.
@interface DPStayingLink : NSProxy
@property (nonatomic, strong) id action;
@end

@implementation DPStayingLink
- (NSInteger)navigationDisposition { return DPCurrentTab; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector { return [self.action methodSignatureForSelector:selector]; }
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:self.action]; }
@end

// Links and window.open: Dia, and any tweak that looks at links before it, are asked as if the link stayed, so no
// other page is made.
static NSInteger DPPage_decidePolicy(id self, SEL _cmd, id page, id action) {
    if (!DPStaysInLittleDia(page, [[action valueForKey:@"navigationDisposition"] integerValue]))
        return DPCallOriginal(DPPage_decidePolicy, self, page, action);
    DPStayingLink *staying = [DPStayingLink alloc];
    staying.action = action;
    return DPCallOriginal(DPPage_decidePolicy, self, page, staying);
}

void DPPromoteLittleDiaWindow(NSWindow *window) { DPSet(window, &DPPromotedKey, @YES); }

static void DPShowMainWindow(void) {
    for (NSWindow *window in NSApp.orderedWindows)
        if (DPIsKind(window, DPDiaWindow) && window.visible) {
            [NSApp activateIgnoringOtherApps:YES];
            [window makeKeyAndOrderFront:nil];
            return;
        }
}

void DPRefreshLittleDiaWindows(void) {
    for (NSWindow *window in NSApp.windows)
        if (DPIsLittleDiaWindow(window)) DPSetChrome(window, DPLittleDia.on);
    DPRelayoutLittleDiaBars();
}

void DPInstallLittleDiaWindows(void) {
    DPExpected = [NSMutableArray array];
    DPPendingPages = [NSMutableArray array];
    DPWindowsAwaitingPage = [NSPointerArray weakObjectsPointerArray];
    DPHookClass(objc_getClass(DPDiaPopupBar), @selector(viewDidMoveToWindow), (IMP)DPPopupBar_viewDidMoveToWindow);
    DPHook(DPDiaBrowserDelegate, @selector(browser:didCreateNewWebContents:isActive:), (IMP)DPBrowser_didCreate);
    DPOnLaunch(^{
        DPHook(DPDiaWebContent, @selector(webContents:decidePolicyForNavigationAction:), (IMP)DPPage_decidePolicy);
    });
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) { DPClaim(note.object); }];
    // Open in Dia goes to the main window. Otherwise, closed while in front, by ✕, ⌘W or Escape: back to the app the
    // link came from.
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
                                                    NSWindow *window = note.object;
                                                    if (!DPLittleDia.on || !DPIsLittleDiaWindow(window)) return;
                                                    pid_t source = [DPGet(window, &DPSourceKey) intValue];
                                                    BOOL key = window.isKeyWindow;
                                                    if ([DPGet(window, &DPPromotedKey) boolValue])
                                                        dispatch_async(dispatch_get_main_queue(), ^{
                                                            DPBringBackPutAway(nil);
                                                            DPShowMainWindow();
                                                        });
                                                    else dispatch_async(dispatch_get_main_queue(), ^{
                                                        if (!DPHideAgain() && key && source) DPReturnToSource(source);
                                                    });
                                                }];
    DPInstallLittleDiaBar();
    DPInstallLittleDiaStack();
}
