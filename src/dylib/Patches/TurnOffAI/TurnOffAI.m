#import "TurnOffAI.h"
#import "Updates/Updates.h"

#define DPDiaCapabilitiesToolbar "_TtC23AssistantCapabilitiesUI32AssistantCapabilitiesToolbarView"
#define DPDiaCapabilitiesItem    "_TtC23AssistantCapabilitiesUI36AssistantCapabilitiesToolbarItemView"
#define DPDiaTabCardActions      "_TtC5TabUI21TabPopoverActionsView"
#define DPDiaSettingsHeader      "_TtC11Preferences25SettingsSectionHeaderView"
#define DPDiaPlaceholderText     "_TtC5ARCUI23TextViewWithPlaceholder"
#define DPDiaChatSidebar         "_TtC6Window30AssistantSidebarViewController"

BOOL DPIsAITitle(NSString *title) {
    if (![title isKindOfClass:NSString.class] || [title hasPrefix:@"Chat with Support"]) return NO;
    NSString *lower = title.lowercaseString;
    return [@[ @"Chat…", @"New Chat", @"Focus Chat", @"Send Chat Prompt Now", @"Open Daily Brief", @"Personalize Dia", @"Chat events", @"Daily report" ]
               containsObject:title]
        || [lower hasPrefix:@"chat with "] || [lower hasPrefix:@"ask dia"];
}

#pragma mark Views

static BOOL DPIsAIView(NSView *view) {
    return DPHasLabel(view, @"Chat with this tab") || DPIsKind(view, DPDiaLibraryButton) || DPIsKind(view, DPDiaLibraryCell)
        || DPIsKind(view, DPDiaSkillsSuggestions) || DPIsKind(view, DPDiaPersonalizeButton) || DPIsKind(view, DPDiaChatUsage)
        || DPIsKind(view, DPDiaCapabilitiesItem);
}

// The command bar and a tab's card are outside the hide hosts. The command bar's toolbar itself stays, so the buttons
// right of it don't slide left.
static void DPHost_layout(NSView *self, SEL _cmd) {
    [DPHideHosts addObject:self];
    DPEnforceHides(self);
    DPCallOriginal(DPHost_layout, self);
}

static NSHashTable<NSView *> *DPMorningBriefs;

// Settings' Morning Brief section: a heading and its switch in a stack of their own, hidden whole so no gap is left.
static void DPSettingsHeader_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(DPSettingsHeader_layout, self);
    NSTextField *title = (NSTextField *)DPFindView(self, ^BOOL(NSView *view) { return [view isKindOfClass:NSTextField.class]; });
    if (![title.stringValue isEqual:@"Morning Brief"] || !self.superview) return;
    [DPMorningBriefs addObject:self.superview];
    if (DPTurnOffAI.on) self.superview.hidden = YES;
}

#pragma mark Chat sidebar

static NSHashTable<NSViewController *> *DPChatSidebars;

// Chat beside the page, open when AI is turned off or opened some way still left, is closed with Dia's own Hide Chat
// button, which also gives the page its width back.
static void DPCloseChat(NSViewController *sidebar) {
    if (!DPTurnOffAI.on) return;
    NSView *hide = DPFindView(sidebar.view, ^BOOL(NSView *view) { return DPHasLabel(view, @"Hide chat"); });
    if (!hide.isHiddenOrHasHiddenAncestor) [hide accessibilityPerformPress];
}

static void DPChatSidebar_viewWillLayout(NSViewController *self, SEL _cmd) {
    DPCallOriginal(DPChatSidebar_viewWillLayout, self);
    [DPChatSidebars addObject:self];
    dispatch_async(dispatch_get_main_queue(), ^{ DPCloseChat(self); });
}

#pragma mark Placeholder

static NSHashTable<NSTextView *> *DPPlaceholderViews;

// "Ask anything…" in the command bar. Dia sets it from Swift, so it's changed where AppKit reads it to draw.
static NSAttributedString *DPPlaceholder_get(NSTextView *self, SEL _cmd) {
    NSAttributedString *dia = DPCallOriginal(DPPlaceholder_get, self);
    [DPPlaceholderViews addObject:self];
    if (!DPTurnOffAI.on || ![dia.string.lowercaseString hasPrefix:@"ask "]) return dia;
    NSMutableAttributedString *ours = [dia mutableCopy];
    [ours replaceCharactersInRange:NSMakeRange(0, ours.length) withString:@"Search or enter address"];
    return ours;
}

#pragma mark Menus

static NSHashTable<NSMenuItem *> *DPAIItems;
static char DPDiaHiddenKey;

// Dia shows and hides some of these itself, so what it asked for is kept and only added to.
static void DPItem_setHidden(NSMenuItem *self, SEL _cmd, BOOL hidden) {
    BOOL ai = [DPAIItems containsObject:self];
    if (ai) DPSet(self, &DPDiaHiddenKey, @(hidden));
    DPCallOriginal(DPItem_setHidden, self, hidden || (ai && DPTurnOffAI.on));
}

static void DPTrack(NSMenuItem *item) {
    if (!DPIsAITitle(item.title)) return;
    if (![DPAIItems containsObject:item]) {
        BOOL diaHidden = item.hidden;
        [DPAIItems addObject:item];
        DPSet(item, &DPDiaHiddenKey, @(diaHidden));
    }
    item.hidden = [DPGet(item, &DPDiaHiddenKey) boolValue];
}

static void DPTrackMenu(NSMenu *menu) {
    for (NSMenuItem *item in menu.itemArray) {
        DPTrack(item);
        if (item.submenu) DPTrackMenu(item.submenu);
    }
}

static void DPMenu_addItem(NSMenu *self, SEL _cmd, NSMenuItem *item) {
    DPCallOriginal(DPMenu_addItem, self, item);
    DPTrack(item);
}

static void DPMenu_insertItem(NSMenu *self, SEL _cmd, NSMenuItem *item, NSInteger index) {
    DPCallOriginal(DPMenu_insertItem, self, item, index);
    DPTrack(item);
}

static const NSEventModifierFlags DPModifiers = NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift;

// Dia runs its shortcuts, ones set in its Shortcuts settings included, ahead of the menus, so a hidden item's still works.
static BOOL DPIsAIShortcut(NSEvent *event) {
    NSEventModifierFlags mods = event.modifierFlags & DPModifiers;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString;
    for (NSMenuItem *item in DPAIItems)
        if (item.keyEquivalent.length && [item.keyEquivalent.lowercaseString isEqual:key] && (item.keyEquivalentModifierMask & DPModifiers) == mods) return YES;
    // ⌃⌘Return in the command bar sends what's typed to chat.
    BOOL inBar = [NSStringFromClass([event.window.firstResponder class]) hasPrefix:@"_TtCC15BoostCommandBar"];
    return inBar && (event.keyCode == 36 || event.keyCode == 76) && mods == (NSEventModifierFlagCommand | NSEventModifierFlagControl);
}

#pragma mark Servers

static BOOL gCutOff;  // Chromium reads its host rules only as Dia starts.

// Dia sends chat and fetches AI apps and skills from inside Chromium, so names that resolve nowhere stop them at once,
// as if offline.
static void DPCutOffAIServers(void) {
    gCutOff = DPTurnOffAI.on;
    if (!gCutOff) return;
    NSMutableArray<NSString *> *rules = [NSMutableArray array];
    for (NSString *host in @[ @"ai-service", @"aiproxy", @"webresultproxy", @"websearch", @"artifactcdn", @"tools-cache" ])
        [rules addObject:[NSString stringWithFormat:@"MAP %@.diabrowser.engineering ~NOTFOUND", host]];
    DPAddLaunchFlag([@"--host-resolver-rules=" stringByAppendingString:[rules componentsJoinedByString:@", "]]);
}

static void DPOfferRelaunch(DPPatch *patch) {
    if (patch->on == gCutOff || patch->on != DPSavedOn(patch)) return;  // the self-test flips patches without saving
    NSAlert *alert = [NSAlert new];
    alert.messageText = patch->on ? @"Relaunch Dia to cut off its AI servers" : @"Relaunch Dia to reconnect its AI servers";
    alert.informativeText = patch->on ? @"Until then, AI is hidden, but Dia can still reach its AI servers." : @"Until then, chat can’t reach them.";
    [alert addButtonWithTitle:@"Relaunch"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] == NSAlertFirstButtonReturn) DPHandOffAndQuit(@[ @"apply" ]);
}

#pragma mark Patch

static void DPInstallTurnOffAI(void) {
    DPCutOffAIServers();
    DPAIItems = [NSHashTable weakObjectsHashTable];
    DPPlaceholderViews = [NSHashTable weakObjectsHashTable];
    DPMorningBriefs = [NSHashTable weakObjectsHashTable];
    DPChatSidebars = [NSHashTable weakObjectsHashTable];
    DPHookClass(NSMenu.class, @selector(addItem:), (IMP)DPMenu_addItem);
    DPHookClass(NSMenu.class, @selector(insertItem:atIndex:), (IMP)DPMenu_insertItem);
    DPHookClass(NSMenuItem.class, @selector(setHidden:), (IMP)DPItem_setHidden);
    DPHook(DPDiaCapabilitiesToolbar, @selector(layout), (IMP)DPHost_layout);
    DPHook(DPDiaTabCardActions, @selector(layout), (IMP)DPHost_layout);
    DPHook(DPDiaSettingsHeader, @selector(layout), (IMP)DPSettingsHeader_layout);
    DPHook(DPDiaPlaceholderText, @selector(placeholderAttributedString), (IMP)DPPlaceholder_get);
    DPHook(DPDiaChatSidebar, @selector(viewWillLayout), (IMP)DPChatSidebar_viewWillLayout);
    DPInstallAIRows();
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        return DPTurnOffAI.on && !DPShortcutRecording() && DPIsAIShortcut(event) ? nil : event;
    }];
    DPOnLaunch(^{ DPTrackMenu(NSApp.mainMenu); });
}

static void DPApplyTurnOffAI(DPPatch *patch) {
    DPApplyHides(patch);
    for (NSMenuItem *item in DPAIItems.allObjects) DPTrack(item);
    for (NSTextView *view in DPPlaceholderViews.allObjects) view.needsDisplay = YES;
    for (NSView *section in DPMorningBriefs.allObjects) section.hidden = patch->on;
    for (NSViewController *sidebar in DPChatSidebars.allObjects) DPCloseChat(sidebar);
    DPApplyAIRows();
    DPOfferRelaunch(patch);
}

DP_PATCH(DPTurnOffAI) {
    .key = @"turnOffAI",
    .order = 95,
    .section = @"AI",
    .title = @"Turn Off AI",
    .detail = @"Turn off every AI feature in Dia: chat and its buttons, menus and shortcuts, Skills, Ask Dia, Morning Brief, and Settings' Apps and Skills. After a relaunch, Dia can't reach its AI servers either. To send questions to search, set Address Bar to Prefer Search Engine in Advanced.",
    .symbol = @"bubble.left.and.exclamationmark.bubble.right.fill bubble.left.fill",
    .tint = @"systemPurpleColor",
    .hides = DPIsAIView,
    .install = DPInstallTurnOffAI,
    .apply = DPApplyTurnOffAI,
};
