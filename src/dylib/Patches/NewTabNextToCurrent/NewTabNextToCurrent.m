#import "StdPatch/StdPatch.h"
#import "Patches/CommandBar/Tabs.h"
#import "Commands/GroupTabs/GroupTabs.h"
#import <objc/message.h>

extern DPPatch DPNewTabNextToCurrent;
static char DPStateKey, DPRelayKey;

// Dia puts a tab made from its menu or the sidebar at the end of the list, and its own new tab page has nothing a tab
// can be moved by. A tab made through its scripting, as `make new tab` does, is a real page, which Group Tabs by Domain's
// way of moving a tab works on: put it in a scratch group, move the group, ungroup it. So File › New Tab, its
// shortcut, whatever that's set to, and the sidebar's New Tab button make that tab instead and move it right after the
// one you were on. From a pinned or favorite tab it goes to the top of the unpinned tabs, and from a tab in a folder
// right after the folder, as in Arc. Closing it goes back to the tab it was opened from.
@interface DPNextTabs : NSObject
@property(strong) NSSet<NSString *> *known;  // Tab IDs at the last look.
@property(copy) NSString *last;              // The tab in front at the last look.
@property BOOL moving;                       // A new tab is being moved, which shifts the tab in front for a moment.
@property(strong) NSMutableDictionary<NSString *, NSString *> *origins;  // New tab ID: the tab it was opened from.
@end

@implementation DPNextTabs
@end

#pragma mark Tabs

static NSArray<NSString *> *DPTabIDs(NSWindow *window) {
    return [[DPScriptWindow(window) valueForKey:@"appleScriptTabs"] valueForKey:@"tabId"] ?: @[];
}

// A tab with no page loaded is Dia's new tab page.
static BOOL DPIsBlank(NSWindow *window, NSString *tabID) {
    NSString *url = [[DPScriptTab(window, tabID) valueForKey:@"URL"] description];
    return !url.length || !([url hasPrefix:@"http:"] || [url hasPrefix:@"https:"] || [url hasPrefix:@"file:"]);
}

static DPNextTabs *DPStateFor(NSWindow *window) {
    DPNextTabs *state = DPGet(window, &DPStateKey);
    NSString *active = DPActiveTabID(window);
    if (state || !active) return state;
    state = [DPNextTabs new];
    state.origins = [NSMutableDictionary dictionary];
    state.known = [NSSet setWithArray:DPTabIDs(window)];
    state.last = active;
    DPSet(window, &DPStateKey, state);
    return state;
}

#pragma mark Opening

static void DPAskGroups(id delegate, id browser, void (^done)(NSArray *groups)) {
    void (*ask)(id, SEL, id, void (^)(NSArray *)) = (void *)objc_msgSend;
    if (![delegate respondsToSelector:@selector(browser:getAllTabGroupsWithCompletion:)]) return done(@[]);
    ask(delegate, @selector(browser:getAllTabGroupsWithCompletion:), browser, ^(NSArray *groups) {
        dispatch_async(dispatch_get_main_queue(), ^{ done([groups isKindOfClass:NSArray.class] ? groups : @[]); });
    });
}

// How many tabs follow `session` in its folder, 0 when it isn't in one.
static NSInteger DPTabsLeftInFolder(NSArray *groups, long long session) {
    for (id info in groups) {
        NSArray *raw = [info respondsToSelector:@selector(tabSessionIds)] ? DPMsg(info, @selector(tabSessionIds)) : nil;
        if (![raw isKindOfClass:NSArray.class]) continue;
        for (NSUInteger i = 0; i < raw.count; i++)
            if (DPLongID(raw[i]) == session) return (NSInteger)(raw.count - 1 - i);
    }
    return 0;
}

static NSSet<NSNumber *> *DPSessions(id browser) {
    NSMutableSet *sessions = [NSMutableSet set];
    for (id contents in DPTrackedContents(browser)) {
        long long sid = DPSessionOf(contents);
        if (sid > 0) [sessions addObject:@(sid)];
    }
    return sessions;
}

static void DPDoneMoving(NSWindow *window, DPNextTabs *state) {
    state.moving = NO;
    state.known = [NSSet setWithArray:DPTabIDs(window)];
    state.last = DPActiveTabID(window);
}

// `before` is the pages Dia had when the tab was made, so the new tab's page is the one it gained.
static void DPPlace(NSWindow *window, NSString *newID, NSString *fromID, long long fromSession, NSSet<NSNumber *> *before, DPNextTabs *state, int tries) {
    id browser = DPBrowserOfWindow(window), delegate = DPGroupingDelegate(browser);
    if (!DPNewTabNextToCurrent.on || !DPScriptTab(window, newID) || !delegate) return DPDoneMoving(window, state);
    NSMutableSet<NSNumber *> *gained = [DPSessions(browser) mutableCopy];
    [gained minusSet:before];
    if (gained.count != 1) {  // Dia may not have told us about the page yet.
        if (tries <= 0) return DPDoneMoving(window, state);
        return (void)dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            DPPlace(window, newID, fromID, fromSession, before, state, tries - 1);
        });
    }
    NSNumber *sid = gained.anyObject;
    NSMutableArray<NSString *> *others = [DPTabIDs(window) mutableCopy];
    NSUInteger newIndex = [others indexOfObject:newID];
    [others removeObject:newID];
    NSUInteger fromIndex = [others indexOfObject:fromID];
    if (newIndex == NSNotFound || fromIndex == NSNotFound || newIndex == fromIndex + 1) return DPDoneMoving(window, state);

    // The move also ends when Dia makes no group for the tab, as when it has closed, which DPMoveTab reports as a failure.
    void (^finish)(void) = ^{ DPDoneMoving(window, state); };
    // Nothing reports where the unpinned tabs start, but a tab moved to 0 lands there.
    DPMoveTab(delegate, browser, sid, 0, ^{
        NSUInteger start = [DPTabIDs(window) indexOfObject:newID];
        if (start == NSNotFound || fromIndex < start) return finish();
        DPAskGroups(delegate, browser, ^(NSArray *groups) {
            NSInteger to = (NSInteger)(fromIndex - start) + 1 + (fromSession > 0 ? DPTabsLeftInFolder(groups, fromSession) : 0);
            DPMoveTab(delegate, browser, sid, to, finish, finish);
        });
    }, finish);
}

// What `make new tab` does. Nothing happens if Dia's scripting isn't as expected, or the tab in front is already a new
// tab, which Dia's own New Tab only brings to the front.
static BOOL DPOpenNextToCurrent(NSWindow *window) {
    id scripted = DPScriptWindow(window), browser = DPBrowserOfWindow(window);
    NSString *from = DPActiveTabID(window);
    Class tabClass = NSClassFromString(@"DiaAppleScriptTab");
    SEL make = NSSelectorFromString(@"newScriptingObjectOfClass:forValueForKey:withContentsValue:properties:");
    if (!DPNewTabNextToCurrent.on || !from || !browser || !DPGroupingDelegate(browser) || !tabClass || ![scripted respondsToSelector:make]) return NO;
    if (DPIsBlank(window, from)) return NO;
    DPNextTabs *state = DPStateFor(window);
    if (state.moving) return NO;
    NSSet<NSNumber *> *before = DPSessions(browser);
    long long fromSession = DPActiveSession(browser);
    NSSet<NSString *> *tabsBefore = [NSSet setWithArray:DPTabIDs(window)];
    id tab = ((id (*)(id, SEL, Class, NSString *, id, id))objc_msgSend)(scripted, make, tabClass, @"appleScriptTabs", nil, @{});
    // The command bar sends you straight back to the tab you were on, so the new tab is found by what's new.
    NSMutableArray<NSString *> *added = [DPTabIDs(window) mutableCopy];
    [added removeObjectsInArray:tabsBefore.allObjects];
    NSString *created = tab && added.count == 1 ? added.firstObject : nil;
    if (!created) return tab != nil;
    state.origins[created] = from;
    state.moving = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ DPPlace(window, created, from, fromSession, before, state, 20); });
    return YES;
}

// Menu items hold their target weakly, so the relay is kept on the item.
@interface DPNewTabRelay : NSObject
@property(weak) id target;
@property SEL action;
@end

@implementation DPNewTabRelay
- (void)open:(NSMenuItem *)sender {
    NSWindow *window = NSApp.keyWindow;
    if (window && DPOpenNextToCurrent(window)) return;
    if (self.action) [NSApp sendAction:self.action to:self.target from:sender];
}
@end

static NSMenuItem *DPNewTabItem(void) {
    for (NSMenuItem *top in NSApp.mainMenu.itemArray)
        for (NSMenuItem *item in top.submenu.itemArray)
            if ([item.title isEqualToString:@"New Tab"] && item.keyEquivalent.length) return item;
    return nil;
}

// Both Dia's shortcut for it and a click reach the item's action, so it's the one place to catch them.
static void DPRelayMenuItem(BOOL on) {
    NSMenuItem *item = DPNewTabItem();
    DPNewTabRelay *relay = DPGet(item, &DPRelayKey);
    if (!item || on == (relay != nil)) return;
    if (on) {
        relay = [DPNewTabRelay new];
        relay.target = item.target;
        relay.action = item.action;
        DPSet(item, &DPRelayKey, relay);
        item.target = relay;
        item.action = @selector(open:);
    } else {
        item.target = relay.target;
        item.action = relay.action;
        DPSet(item, &DPRelayKey, nil);
    }
}

static void DPNewTabButton_mouseDown(NSView *self, SEL _cmd, NSEvent *event) {
    if (!(self.window && DPOpenNextToCurrent(self.window))) DPCallOriginal(DPNewTabButton_mouseDown, self, event);
}

#pragma mark Following

static void DPReturnTo(NSWindow *window, NSString *originID, NSString *expectedFront) {
    id origin = DPScriptTab(window, originID);
    if (origin && [DPActiveTabID(window) isEqual:expectedFront]) DPFocusTab(origin);
}

// Tracks which tab you're on. A tab opened from another stays tied to it while you're on either, so going back and
// forth keeps it, and a command bar tab that sends you back while it waits for a search does too.
static void DPNote(NSWindow *window) {
    if (!DPNewTabNextToCurrent.on) return DPSet(window, &DPStateKey, nil);
    NSString *active = DPActiveTabID(window);
    NSArray<NSString *> *ids = DPTabIDs(window);
    DPNextTabs *state = DPGet(window, &DPStateKey);
    if (!active || !ids.count) return;
    if (!state) return (void)DPStateFor(window);
    if (state.moving) return;
    NSSet<NSString *> *now = [NSSet setWithArray:ids];
    BOOL switched = ![active isEqual:state.last];

    // A new tab page came to the front that Dia, not the tweak, opened: a button or shortcut this didn't catch.
    if (state.last && switched && ![state.known containsObject:active] && [now containsObject:state.last] && DPIsBlank(window, active))
        state.origins[active] = state.last;

    for (NSString *tab in state.origins.allKeys) {
        NSString *origin = state.origins[tab];
        if (![now containsObject:origin]) {
            [state.origins removeObjectForKey:tab];
        } else if (![now containsObject:tab]) {
            [state.origins removeObjectForKey:tab];
            if ([state.last isEqual:tab] && ![active isEqual:origin])
                dispatch_async(dispatch_get_main_queue(), ^{ DPReturnTo(window, origin, active); });
        } else if (![active isEqual:tab] && ![active isEqual:origin]) {
            [state.origins removeObjectForKey:tab];
            // Dia may bring the next tab to the front before it lets the closing one go.
            if ([state.last isEqual:tab])
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    if (!DPScriptTab(window, tab)) DPReturnTo(window, origin, active);
                });
        }
    }
    state.known = now;
    state.last = active;
}

static void DPContentPane_viewDidMoveToWindow(NSView *self, SEL _cmd) {
    DPCallOriginal(DPContentPane_viewDidMoveToWindow, self);
    NSWindow *window = self.window;
    if (window && DPNewTabNextToCurrent.on) DPNote(window);
}

static void DPNewTabPage_viewDidMoveToWindow(NSView *self, SEL _cmd) {
    DPCallOriginal(DPNewTabPage_viewDidMoveToWindow, self);
    NSWindow *window = self.window;
    if (window && DPNewTabNextToCurrent.on) DPNote(window);
}

#pragma mark Patch

static void DPInstallNewTabNextToCurrent(void) {
    DPHook(DPDiaContentPane, @selector(viewDidMoveToWindow), (IMP)DPContentPane_viewDidMoveToWindow);
    DPHook(DPDiaNewTabPage, @selector(viewDidMoveToWindow), (IMP)DPNewTabPage_viewDidMoveToWindow);
    DPHook(DPDiaNewTabButton, @selector(mouseDown:), (IMP)DPNewTabButton_mouseDown);
    DPOnLaunch(^{ if (DPNewTabNextToCurrent.on) DPRelayMenuItem(YES); });
}

static void DPApplyNewTabNextToCurrent(DPPatch *patch) {
    DPRelayMenuItem(patch->on);
    for (NSWindow *window in NSApp.windows) {
        DPSet(window, &DPStateKey, nil);  // Starts afresh from the tabs there are when it's on.
        if (patch->on) DPNote(window);
    }
}

static NSString *DPVerifyNewTabNextToCurrent(DPPatch *patch) {
    NSMenuItem *item = DPNewTabItem();
    if (!item) return patch->on ? @"Dia has no New Tab menu item" : nil;
    if (patch->on && !DPGet(item, &DPRelayKey)) return @"New Tab doesn't open next to the current tab";
    if (!patch->on && DPGet(item, &DPRelayKey)) return @"New Tab is still changed";
    return nil;
}

DP_PATCH(DPNewTabNextToCurrent) {
    .key = @"newTabNextToCurrent",
    .order = 86,
    .title = @"Open New Tabs Next to Current",
    .detail = @"A new tab opens right after the tab you’re on, not at the end, as in Arc and Chrome. Close it and you’re back on the tab you came from. On a pinned tab, it opens at the top of the unpinned tabs.",
    .symbol = @"rectangle.badge.plus",
    .tint = @"systemPinkColor",
    .section = @"Tabs",
    .classes = DPClasses(DPDiaContentPane, DPDiaNewTabPage, DPDiaNewTabButton),
    .install = DPInstallNewTabNextToCurrent,
    .apply = DPApplyNewTabNextToCurrent,
    .verify = DPVerifyNewTabNextToCurrent,
};

