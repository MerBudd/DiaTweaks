#import "StdPatch/StdPatch.h"
#import "Commands/GroupTabs/GroupTabs.h"
#import "Patches/CommandBar/Tabs.h"

extern DPPatch DPUndoCloseTab;
static BOOL DPJustClosed;

static NSMenuItem *DPReopenItem(void) {
    for (NSMenuItem *top in NSApp.mainMenu.itemArray)
        for (NSMenuItem *item in top.submenu.itemArray)
            if ([item.title isEqualToString:@"Reopen Closed Tab"]) return item;
    return nil;
}

// Dia closes a tab's page this way; Peek closes its own pages with -close. Only a close the user made counts: not one
// DiaTweaks made, such as the command bar dropping the tab it opened, whose ⌘Z would then reopen it over the page's undo.
static void DPPage_close(id self, SEL _cmd, NSInteger timing) {
    DPCallOriginal(DPPage_close, self, timing);
    if (!DPUndoCloseTab.on) return;
    if (!DPTakeOwnClose()) DPJustClosed = YES;
    DPForgetGroupingUndo();
}

// Text being edited in the window keeps ⌘Z while there is something in it to undo.
static BOOL DPEditingWithUndo(NSWindow *window) {
    NSText *text = [window.firstResponder isKindOfClass:NSText.class] ? (NSText *)window.firstResponder : nil;
    return text.editable && text.undoManager.canUndo;
}

static NSDictionary *DPDefaultUndoShortcut(void) { return @{ @"keyCode" : @6, @"modifiers" : @(NSEventModifierFlagCommand), @"key" : @"Z" }; }

static void DPInstallUndoCloseTab(void) {
    DPHook(DPDiaWebContents, @selector(closeWithForegroundCommitTiming:), (IMP)DPPage_close);
    NSEventMask mask = NSEventMaskKeyDown | NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
    [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
        BOOL undo = DPJustClosed && event.type == NSEventTypeKeyDown && DPShortcutMatches(event, &DPUndoCloseTab) && !DPCanUndoGrouping() && !DPEditingWithUndo(event.window);
        DPJustClosed = NO;
        NSMenuItem *reopen = undo ? DPReopenItem() : nil;
        if (!reopen) return event;
        [reopen.menu performActionForItemAtIndex:[reopen.menu indexOfItem:reopen]];
        return nil;
    }];
}

static NSString *DPVerifyUndoCloseTab(DPPatch *patch) {
    return patch->on && !DPReopenItem() ? @"Dia has no Reopen Closed Tab menu item" : nil;
}

DP_PATCH(DPUndoCloseTab) {
    .key = @"undoCloseTab",
    .order = 86,
    .title = @"Undo Closing a Tab",
    .detail = @"Press a shortcut, ⌘Z unless you set another, right after closing a tab to bring it back, as long as you haven’t typed or clicked since.",
    .symbol = @"arrow.uturn.backward.circle.fill",
    .tint = @"systemPinkColor",
    .section = @"Tabs",
    .classes = DPClasses(DPDiaWebContents),
    .shortcut = @"undoCloseTabShortcut",
    .defaultShortcut = DPDefaultUndoShortcut,
    .sharesShortcutWith = @"undo:",  // It only takes the shortcut right after a tab closes, when there's nothing for Undo to undo.
    .install = DPInstallUndoCloseTab,
    .verify = DPVerifyUndoCloseTab,
};
