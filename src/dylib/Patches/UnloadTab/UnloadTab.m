#import "Patches/UnloadTab/Recent.h"
#import "Patches/PinnedTabCloseButton/PinnedTabs.h"
#import <objc/message.h>

enum { DPPageVisible = 2 };  // content::Visibility: hidden, occluded, visible.

static NSHashTable *DPPages;
static NSHashTable *DPDiscarded;  // Pages Chromium says it unloaded, until they're shown again.
static NSHashTable *DPUnloadOnHide;  // Pages to unload as soon as switching away from them takes them off screen.

// The tab's one page, as Dia's tab controller knows it. A split tab has more than one, and isn't offered.
static id DPTabContent(NSView *tab) {
    NSDictionary *views = DPSwiftValue(tab, @"contentViews");
    if (views.count != 1) return nil;
    return DPSwiftValue(DPSwiftValue(views.allValues.firstObject, @"viewModel"), @"delegate");
}

// Dia's tabs don't hold their page, so it's found by address, and only when no other loaded page shares it.
static id DPPageAt(NSURL *url) {
    id found = nil;
    for (id page in DPPages) {
        if (![[page valueForKey:@"url"] isEqual:url]) continue;
        if (found) return nil;
        found = page;
    }
    return found;
}

static BOOL DPTabOpen(NSView *tab) {
    NSString *state = [DPSwiftValue(DPSwiftValue(DPSwiftValue(tab, @"viewModel"), @"stateSubject"), @"currentValue") description];
    NSString *style = [[state componentsSeparatedByString:@"selectionStyle: "].lastObject substringToIndex:5];
    return ![style hasPrefix:@"nil"] && ![style hasPrefix:@"none"] && ![style hasPrefix:@"above"] && ![style hasPrefix:@"below"];
}

static void DPPage_setVisibility(id self, SEL _cmd, NSInteger visibility) {
    [DPPages addObject:self];
    DPCallOriginal(DPPage_setVisibility, self, visibility);
    if (visibility == DPPageVisible) {
        [DPDiscarded removeObject:self];  // Showing it loads it again.
    } else if ([DPUnloadOnHide containsObject:self]) {
        [DPUnloadOnHide removeObject:self];
        dispatch_async(dispatch_get_main_queue(), ^{ [self performSelector:@selector(discard)]; });
    }
}

// Chromium may decline, as for a page playing audio, so a page only counts as unloaded once it says it went.
static void DPWebContent_finalizeDiscard(id self, SEL _cmd, id page, BOOL discarded) {
    DPCallOriginal(DPWebContent_finalizeDiscard, self, page, discarded);
    if (discarded && page) [DPDiscarded addObject:page];
}

static NSMenu *DPTab_menuForEvent(NSView *self, SEL _cmd, NSEvent *event) {
    NSMenu *menu = DPCallOriginal(DPTab_menuForEvent, self, event);
    id content = menu && DPUnloadTab.on ? DPTabContent(self) : nil;
    NSView *pane = content ? DPFindView(self, ^BOOL(NSView *view) { return DPIsKind(view, DPDiaTabContentView); }) : nil;
    // An open pinned tab closes its page and stays pinned, as its minus button does, so Dia knows it has no page.
    BOOL pinned = pane && DPIsOpenPinned(pane) && [pane respondsToSelector:NSSelectorFromString(@"closeButtonClicked")];
    id page = content && !pinned ? DPPageAt(DPSwiftValue(content, @"webContentURL")) : nil;
    if (!pinned && (!page || [DPDiscarded containsObject:page])) return menu;
    // Chromium won't unload a page on screen, so for the tab in front the window goes back to the one before it first.
    BOOL open = DPTabOpen(self);
    BOOL visible = page ? ((NSInteger (*)(id, SEL))objc_msgSend)(page, @selector(visibility)) == DPPageVisible : open;
    NSWindow *window = self.window;
    id before = visible && open ? DPTabBefore(window) : nil;
    NSMenuItem *item = DPMenuItem(@"Unload Tab", ^{
        if (before) DPForgetFrontTab(window);
        if (pinned) {
            if (before) DPFocusTab(before);
            DPMarkOwnClose();  // Unloading isn't closing, so it doesn't arm Undo Closing a Tab.
            return (void)DPCloseKeepingTab(pane);
        }
        if (!before) return (void)[page performSelector:@selector(discard)];
        [DPUnloadOnHide addObject:page];
        DPFocusTab(before);
        // If switching doesn't take it off screen, it isn't unloaded later out of the blue.
        __weak id weakPage = page;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            id shown = weakPage;
            if (shown) [DPUnloadOnHide removeObject:shown];
        });
    });
    item.image = [NSImage imageWithSystemSymbolName:@"moon.zzz" accessibilityDescription:nil];
    // Hidden by default, unlike Dia's own items. By name: CI's SDK predates macOS 27. 1 is NSMenuItemImageVisibilityVisible.
    if (@available(macOS 27, *)) [item setValue:@1 forKey:@"preferredImageVisibility"];
    item.enabled = pinned || !visible || before;  // A page on screen elsewhere, as in another window, stays.
    NSUInteger close = [menu.itemArray indexOfObjectPassingTest:^BOOL(NSMenuItem *it, NSUInteger i, BOOL *stop) { return [it.title isEqual:@"Close"]; }];
    [menu insertItem:item atIndex:close == NSNotFound ? (NSUInteger)menu.numberOfItems : close];
    return menu;
}

#pragma mark Verify

// The tab's menu, built as a right-click would without showing it.
static NSMenuItem *DPUnloadItem(NSView *tab) {
    NSPoint point = [tab convertPoint:NSMakePoint(NSMidX(tab.bounds), NSMidY(tab.bounds)) toView:nil];
    NSEvent *click = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                    windowNumber:tab.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    return [[tab menuForEvent:click] itemWithTitle:@"Unload Tab"];
}

// A tab showing a web page no other tab shows offers Unload Tab when its page is loaded, as the one in front of a window
// always is, and the one in front can leave for another tab if the window has one. Nothing is unloaded.
static NSString *DPVerifyUnloadTab(DPPatch *patch) {
    NSArray<NSView *> *tabs = DPFindViews(DPDiaTabView);
    NSCountedSet<NSURL *> *urls = [NSCountedSet set];
    for (NSView *tab in tabs) {
        NSURL *url = DPSwiftValue(DPTabContent(tab), @"webContentURL");
        if (url) [urls addObject:url];
    }
    for (NSView *tab in tabs) {
        if (!tab.window || tab.isHiddenOrHasHiddenAncestor) continue;
        NSMenuItem *item = DPUnloadItem(tab);
        if (!patch->on) {
            if (item) return @"tab still offers Unload Tab";
            continue;
        }
        NSURL *url = DPSwiftValue(DPTabContent(tab), @"webContentURL");
        if (![url.scheme hasPrefix:@"http"] || [urls countForObject:url] > 1) continue;
        BOOL front = DPTabOpen(tab);
        if (!front && (!DPPageAt(url) || [DPDiscarded containsObject:DPPageAt(url)])) continue;
        if (!item) return front ? @"tab in front has no Unload Tab" : @"loaded tab has no Unload Tab";
        if (front && !item.enabled && [[DPScriptWindow(tab.window) valueForKey:@"appleScriptTabs"] count] > 1)
            return @"Unload Tab can't leave the tab in front";
    }
    return nil;
}

#pragma mark Patch

static void DPInstallUnloadTab(void) {
    DPPages = [NSHashTable weakObjectsHashTable];
    DPDiscarded = [NSHashTable weakObjectsHashTable];
    DPUnloadOnHide = [NSHashTable weakObjectsHashTable];
    DPHook(DPDiaWebContents, @selector(setVisibility:), (IMP)DPPage_setVisibility);
    DPHook(DPDiaTabView, @selector(menuForEvent:), (IMP)DPTab_menuForEvent);
    DPWatchFrontTabs();
    DPOnLaunch(^{
        DPHook(DPDiaWebContent, @selector(webContents:finalizeDiscardRequest:), (IMP)DPWebContent_finalizeDiscard);
    });
}

DP_PATCH(DPUnloadTab) {
    .key = @"unloadTab",
    .order = 86,
    .section = @"Tabs",
    .title = @"Unload Tabs",
    .detail = @"Right-click a tab and choose Unload Tab to free its memory. It stays in the sidebar and loads again when you open it. Unloading the tab you’re on takes you back to the one you were on before. A pinned tab goes back to its pinned page.",
    .symbol = @"moon.zzz.fill",
    .tint = @"systemPinkColor",
    .classes = DPClasses(DPDiaWebContents, DPDiaTabView, DPDiaContentPane),
    .install = DPInstallUnloadTab,
    .verify = DPVerifyUnloadTab,
};
