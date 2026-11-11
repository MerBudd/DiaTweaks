#import "LittleDia.h"
#import <objc/message.h>

#define DPDiaPopupController  "_TtC5Popup29PlatformPopupWindowController"
#define DPDiaCallbackMenuItem "_TtC5ARCUI16CallbackMenuItem"

// Dia sends its menu commands for a popup window through a model of its page that Little Dia's page isn't part of, so
// in a Little Dia window Copy URL, Go Back, Zoom In and the rest did nothing, from the menu or by shortcut. Here they act
// on the page itself, so each keeps whatever shortcut its menu item has.
static const char *const DPPopupActionNames[] = {"copyCurrentURL:", "copyCurrentURLAsMarkdown:", "navigateTabBack:", "navigateTabForward:", "zoomIn:",
                                                 "zoomInAlternate:", "zoomOut:", "resetZoom:", "printFocusedContent:", "closeFocusedContent:"};

static const SEL *DPPopupActions(void) {
    static SEL actions[sizeof DPPopupActionNames / sizeof *DPPopupActionNames + 1];  // and NULL
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (size_t i = 0; i < sizeof DPPopupActionNames / sizeof *DPPopupActionNames; i++) actions[i] = sel_registerName(DPPopupActionNames[i]);
    });
    return actions;
}

// Dia's own items for these call back into its main window, so they're greyed out in a popup.
static SEL DPCallbackAction(NSMenuItem *item) {
    if (item.menu.supermenu != NSApp.mainMenu) return NULL;
    static NSDictionary<NSString *, NSString *> *actions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ actions = @{@"Refresh" : @"reload", @"Force Refresh the Page" : @"reloadWithoutCache", @"Close Window" : @"performClose:"}; });
    NSString *action = actions[item.title];
    return action ? NSSelectorFromString(action) : NULL;
}

static NSWindow *DPLittleWindow(NSWindow *window) { return DPLittleDia.on && DPIsLittleDiaWindow(window) ? window : nil; }

static BOOL DPPageFlag(id page, SEL flag) { return [page respondsToSelector:flag] && ((BOOL (*)(id, SEL))objc_msgSend)(page, flag); }

// Chromium's zoom steps.
static const float DPZoomSteps[] = {0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5};

static void DPZoom(NSWindow *window, int direction) {
    id page = DPLittleDiaPage(window);
    if (![page respondsToSelector:@selector(zoomFactor)] || ![page respondsToSelector:@selector(setZoomFactor:)]) return;
    float now = ((float (*)(id, SEL))objc_msgSend)(page, @selector(zoomFactor)), next = 1;
    size_t count = sizeof DPZoomSteps / sizeof *DPZoomSteps;
    if (direction > 0) {
        next = DPZoomSteps[count - 1];
        for (size_t i = 0; i < count; i++) if (DPZoomSteps[i] > now + 0.001) { next = DPZoomSteps[i]; break; }
    } else if (direction < 0) {
        next = DPZoomSteps[0];
        for (size_t i = count; i-- > 0;) if (DPZoomSteps[i] < now - 0.001) { next = DPZoomSteps[i]; break; }
    }
    ((void (*)(id, SEL, float))objc_msgSend)(page, @selector(setZoomFactor:), next);
    DPShowLittleDiaNotice(window, [NSString stringWithFormat:@"Zoom %d%%", (int)lroundf(next * 100)]);
}

static void DPCopyURL(NSWindow *window, BOOL markdown) {
    NSString *url = DPLittleDiaURL(window);
    NSString *title = ((id (*)(id, SEL))objc_msgSend)(DPLittleDiaPage(window), @selector(title));
    if (![title isKindOfClass:NSString.class] || !title.length) title = url;
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    if (markdown) [pasteboard setString:[NSString stringWithFormat:@"[%@](%@)", title, url] forType:NSPasteboardTypeString];
    else {
        [pasteboard setString:url forType:NSPasteboardTypeString];
        [pasteboard setString:url forType:NSPasteboardTypeURL];
    }
    DPShowLittleDiaNotice(window, markdown ? @"Copied URL as Markdown" : @"Copied current URL");
}

static BOOL DPCanRun(NSWindow *window, SEL action) {
    id page = DPLittleDiaPage(window);
    if (action == @selector(closeFocusedContent:) || action == @selector(performClose:)) return YES;
    if (action == @selector(copyCurrentURL:) || action == @selector(copyCurrentURLAsMarkdown:)) return DPLittleDiaURL(window).length > 0;
    if (action == @selector(navigateTabBack:)) return DPPageFlag(page, @selector(canGoBack));
    if (action == @selector(navigateTabForward:)) return DPPageFlag(page, @selector(canGoForward));
    return page != nil;
}

static void DPRun(NSWindow *window, SEL action) {
    if (!DPCanRun(window, action)) return NSBeep();
    id page = DPLittleDiaPage(window);
    if (action == @selector(copyCurrentURL:) || action == @selector(copyCurrentURLAsMarkdown:)) DPCopyURL(window, action == @selector(copyCurrentURLAsMarkdown:));
    else if (action == @selector(navigateTabBack:)) DPLittleDiaGo(window, @selector(goBack));
    else if (action == @selector(navigateTabForward:)) DPLittleDiaGo(window, @selector(goForward));
    else if (action == @selector(reload) || action == @selector(reloadWithoutCache)) DPLittleDiaGo(window, action);
    else if (action == @selector(zoomIn:) || action == @selector(zoomInAlternate:)) DPZoom(window, 1);  // ⌘+, and ⌘= from a hidden item
    else if (action == @selector(zoomOut:) || action == @selector(resetZoom:)) DPZoom(window, action == @selector(zoomOut:) ? -1 : 0);
    else if (action == @selector(printFocusedContent:) && [page respondsToSelector:@selector(print)]) ((void (*)(id, SEL))objc_msgSend)(page, @selector(print));
    else if (action == @selector(closeFocusedContent:) || action == @selector(performClose:)) [window performClose:nil];
}

#pragma mark Hooks

static void DPPopup_action(NSWindowController *self, SEL _cmd, id sender) {
    NSWindow *window = DPLittleWindow(self.window);
    if (!window) return DPCallOriginal(DPPopup_action, self, sender);
    DPRun(window, _cmd);
}

static BOOL DPHandles(SEL action) {
    for (const SEL *each = DPPopupActions(); *each; each++) if (*each == action) return YES;
    return NO;
}

static BOOL DPPopup_validate(NSWindowController *self, SEL _cmd, NSMenuItem *item) {
    NSWindow *window = DPLittleWindow(self.window);
    if (!window || !DPHandles(item.action)) return DPCallOriginal(DPPopup_validate, self, item);
    return DPCanRun(window, item.action);
}

// Every key equivalent validates the menu bar's items, so the key window is looked at before the title.
static BOOL DPCallback_validate(NSMenuItem *self, SEL _cmd, NSMenuItem *item) {
    NSWindow *window = DPLittleWindow(NSApp.keyWindow);
    SEL action = window ? DPCallbackAction(self) : NULL;
    return action ? DPCanRun(window, action) : DPCallOriginal(DPCallback_validate, self, item);
}

static void DPCallback_perform(NSMenuItem *self, SEL _cmd, id sender) {
    NSWindow *window = DPLittleWindow(NSApp.keyWindow);
    SEL action = window ? DPCallbackAction(self) : NULL;
    if (!action) return DPCallOriginal(DPCallback_perform, self, sender);
    DPRun(window, action);
}

void DPInstallLittleDiaShortcuts(void) {
    for (const SEL *each = DPPopupActions(); *each; each++) DPHook(DPDiaPopupController, *each, (IMP)DPPopup_action);
    DPHook(DPDiaPopupController, @selector(validateMenuItem:), (IMP)DPPopup_validate);
    DPHook(DPDiaCallbackMenuItem, @selector(validateMenuItem:), (IMP)DPCallback_validate);
    DPHook(DPDiaCallbackMenuItem, @selector(performWithSender:), (IMP)DPCallback_perform);
}

NSString *DPLittleDiaShortcutsProblem(void) {
    Class popup = objc_getClass(DPDiaPopupController), item = objc_getClass(DPDiaCallbackMenuItem);
    for (const SEL *each = DPPopupActions(); *each; each++)
        if (class_getMethodImplementation(popup, *each) != (IMP)DPPopup_action) return [NSString stringWithFormat:@"%@ doesn't reach Little Dia", NSStringFromSelector(*each)];
    if (class_getMethodImplementation(item, @selector(performWithSender:)) != (IMP)DPCallback_perform) return @"Refresh doesn't reach Little Dia";
    return nil;
}
