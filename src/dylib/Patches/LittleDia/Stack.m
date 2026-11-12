#import "LittleDia.h"

// A link from another app makes macOS bring Dia forward, and Dia's main window with it. Little Dia puts the main window
// back where it was: the order of the windows on screen is noted just before Dia comes forward, and after the small
// window opens, every Dia window that was behind the app the link came from goes back behind it.

static NSArray<NSDictionary *> *DPBeforeActivating;
static NSDate *DPNotedAt, *DPUnhiddenAt;
static NSMutableArray<NSWindow *> *DPPutAway;  // Dia's other windows, while a link opened with Dia hidden is open.
static NSMapTable<NSWindow *, NSNumber *> *DPVeiled;  // Windows kept see-through as Dia unhides, with their own alpha.

// Normal windows on screen, front to back, with the app each belongs to. Needs no screen recording permission.
static NSArray<NSDictionary *> *DPWindowStack(void) {
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableArray *stack = [NSMutableArray array];
    for (NSDictionary *info in list)
        if ([info[(id)kCGWindowLayer] integerValue] == 0) [stack addObject:@{@"number" : info[(id)kCGWindowNumber], @"pid" : info[(id)kCGWindowOwnerPID]}];
    return stack;
}

// Each link keeps its own: the next can arrive before this one's window does, and the app it came from may differ.
NSDictionary *DPNoteStackForLink(void) {
    NSArray<NSDictionary *> *stack = nil;  // Dia was already in front: nothing to put back.
    if (!NSApp.active) stack = DPWindowStack();
    else if (DPNotedAt && DPNotedAt.timeIntervalSinceNow > -2) stack = DPBeforeActivating;
    NSNumber *me = @(getpid()), *source = @0;  // The app the link was clicked in, if Dia wasn't in front.
    for (NSDictionary *window in stack)
        if (![window[@"pid"] isEqual:me]) {
            source = window[@"pid"];
            break;
        }
    return @{@"stack" : stack ?: @[], @"source" : source};
}

// Closing the window goes back to that app, instead of Dia bringing its main window up in its place.
void DPReturnToSource(pid_t pid) {
    NSRunningApplication *app = pid ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
    if (!app || app.terminated) return;
    if (@available(macOS 14, *)) [app activateFromApplication:NSRunningApplication.currentApplication options:0];
    else [app activateWithOptions:0];
}

// Dia was hidden, so bringing it forward for the link showed every window: the others go away again, until Open in
// Dia, or Dia is hidden again when its last small window closes and comes back the usual way.
static BOOL DPPutAwayIfHidden(NSWindow *little) {
    if (!DPUnhiddenAt || DPUnhiddenAt.timeIntervalSinceNow < -2) return NO;
    for (NSWindow *window in NSApp.orderedWindows) {
        if (DPIsLittleDiaWindow(window) || !window.visible || window.level != NSNormalWindowLevel) continue;
        if (![DPPutAway containsObject:window]) [DPPutAway addObject:window];
        [window orderOut:nil];
    }
    return YES;
}

// macOS unhides Dia a moment before the link that unhid it arrives, which showed every window for that moment. So as Dia
// unhides, its windows stay see-through for a little while: long enough for a link to come and put them away.
static void DPUnveil(void) {
    for (NSWindow *window in DPVeiled) window.alphaValue = [[DPVeiled objectForKey:window] doubleValue];
    [DPVeiled removeAllObjects];
}

void DPLinkArrived(void) {
    for (NSWindow *window in DPVeiled) {
        if (!window.visible) continue;
        if (![DPPutAway containsObject:window]) [DPPutAway addObject:window];
        [window orderOut:nil];
    }
    DPUnveil();
}

void DPBringBackPutAway(NSWindow *little) {
    for (NSWindow *window in DPPutAway) {
        if (little.visible) [window orderWindow:NSWindowBelow relativeTo:little.windowNumber];
        else [window orderFront:nil];
    }
    [DPPutAway removeAllObjects];
}

BOOL DPHideAgain(void) {
    if (!DPPutAway.count) return NO;
    for (NSWindow *window in NSApp.windows)
        if (DPIsLittleDiaWindow(window) && window.visible) return NO;
    // A window shown or opened since is one the user is working in.
    for (NSWindow *window in NSApp.windows)
        if (window.visible && !window.miniaturized && window.level == NSNormalWindowLevel && window.canBecomeMainWindow) return NO;
    // Hiding notes which windows are showing, so they're shown first, behind everything, for unhiding to bring back.
    for (NSWindow *window in DPPutAway) [window orderBack:nil];
    [DPPutAway removeAllObjects];
    [NSApp hide:nil];
    return YES;
}

void DPRestoreStack(NSWindow *little, NSDictionary *noted) {
    if (DPPutAwayIfHidden(little)) return;
    NSArray<NSDictionary *> *stack = noted[@"stack"];
    NSNumber *me = @(getpid());
    NSUInteger front = [stack indexOfObjectPassingTest:^BOOL(NSDictionary *window, NSUInteger i, BOOL *stop) { return ![window[@"pid"] isEqual:me]; }];
    if (front == NSNotFound) return;
    NSInteger anchor = [stack[front][@"number"] integerValue];
    // Back to front, so each lands just behind that window and they keep their order.
    NSMutableArray<NSWindow *> *behind = [NSMutableArray array];
    for (NSWindow *window in NSApp.orderedWindows) {
        if (window == little || !window.visible || window.level != NSNormalWindowLevel) continue;
        NSUInteger at = [stack indexOfObjectPassingTest:^BOOL(NSDictionary *each, NSUInteger i, BOOL *stop) { return [each[@"number"] integerValue] == window.windowNumber; }];
        if (at != NSNotFound && at > front) [behind insertObject:window atIndex:0];
    }
    for (NSWindow *window in behind) [window orderWindow:NSWindowBelow relativeTo:anchor];
}

void DPInstallLittleDiaStack(void) {
    DPPutAway = [NSMutableArray array];
    DPVeiled = [NSMapTable weakToStrongObjectsMapTable];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillUnhideNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
                                                    if (!DPLittleDia.on) return;
                                                    for (NSWindow *window in NSApp.windows)
                                                        if (window.level == NSNormalWindowLevel && !DPIsLittleDiaWindow(window) && window.alphaValue > 0) {
                                                            [DPVeiled setObject:@(window.alphaValue) forKey:window];
                                                            window.alphaValue = 0;
                                                        }
                                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ DPUnveil(); });
                                                }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidUnhideNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) { DPUnhiddenAt = [NSDate date]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillBecomeActiveNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
                                                    DPBeforeActivating = DPWindowStack();
                                                    DPNotedAt = [NSDate date];
                                                }];
}
