#import "StdPatch/StdPatch.h"
#import <objc/message.h>

extern DPPatch DPSavePageAs;
static const NSInteger DPWebContentsVisible = 2;
static NSHashTable *DPPages;
static NSMenuItem *DPSaveItem;

static NSDictionary *DPDefaultSaveShortcut(void) {
    return @{ @"keyCode" : @1, @"modifiers" : @(NSEventModifierFlagOption | NSEventModifierFlagCommand), @"key" : @"S" };
}

static void DPPage_setVisibility(id self, SEL _cmd, NSInteger visibility) {
    [DPPages addObject:self];
    DPCallOriginal(DPPage_setVisibility, self, visibility);
}

// The focused page, else the one under the pointer, else the only visible one; with split tabs and none of those, nil.
static id DPFrontPage(void) {
    NSWindow *window = NSApp.keyWindow;
    NSView *hit = [window.contentView.superview hitTest:window.mouseLocationOutsideOfEventStream];  // the frame view has no superview
    id focused = nil, under = nil, only = nil;
    NSUInteger count = 0;
    for (id page in DPPages.allObjects) {
        NSView *view = [page performSelector:@selector(nativeView)];
        if (view.window != window || ((NSInteger (*)(id, SEL))objc_msgSend)(page, @selector(visibility)) != DPWebContentsVisible) continue;
        if (((BOOL (*)(id, SEL))objc_msgSend)(page, @selector(hasFocus))) focused = page;
        if ([hit isDescendantOf:view]) under = page;
        only = page;
        count++;
    }
    return focused ?: under ?: (count == 1 ? only : nil);
}

static void DPSaveFrontPage(void) { [DPFrontPage() performSelector:@selector(save)]; }

static void DPAddSaveItem(void) {
    NSMenu *file = [NSApp.mainMenu itemWithTitle:@"File"].submenu;
    if (!file || [file indexOfItem:DPSaveItem] >= 0) return;
    NSInteger print = [file indexOfItemWithTitle:@"Print…"];
    [file insertItem:DPSaveItem atIndex:print >= 0 ? print : file.numberOfItems];
}

static void DPInstallSavePageAs(void) {
    DPPages = [NSHashTable weakObjectsHashTable];
    DPHook(DPDiaWebContents, @selector(setVisibility:), (IMP)DPPage_setVisibility);
    DPSaveItem = DPMenuItem(@"Save Page As…", ^{ DPSaveFrontPage(); });
    DPSaveItem.hidden = !DPSavePageAs.on;
    DPOnLaunch(^{ DPAddSaveItem(); });
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (!DPSavePageAs.on || !DPShortcutMatches(event, &DPSavePageAs) || !DPFrontPage()) return event;
        if (!event.isARepeat) DPSaveFrontPage();
        return nil;
    }];
}

static void DPApplySavePageAs(DPPatch *patch) {
    DPAddSaveItem();
    DPSaveItem.hidden = !patch->on;
}

static NSString *DPVerifySavePageAs(DPPatch *patch) {
    NSMenu *file = [NSApp.mainMenu itemWithTitle:@"File"].submenu;
    BOOL shown = file && [file indexOfItem:DPSaveItem] >= 0 && !DPSaveItem.hidden;
    if (shown == patch->on) return nil;
    return patch->on ? @"the File menu has no Save Page As" : @"Save Page As stays in the File menu";
}

DP_PATCH(DPSavePageAs) {
    .key = @"savePageAs",
    .order = 86,
    .title = @"Save Page As",
    .detail = @"Add Save Page As… to the File menu, with a shortcut, ⌥⌘S unless you set another.",
    .symbol = @"square.and.arrow.down.fill",
    .tint = @"systemPinkColor",
    .section = @"Tabs",
    .classes = DPClasses(DPDiaWebContents),
    .install = DPInstallSavePageAs,
    .apply = DPApplySavePageAs,
    .shortcut = @"savePageAsShortcut",
    .defaultShortcut = DPDefaultSaveShortcut,
    .verify = DPVerifySavePageAs,
};
