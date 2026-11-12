#import "StdPatch/StdPatch.h"

extern DPPatch DPDragWindowFromPage;
static const CGFloat DPDragBand = 56, DPDragSlop = 3, DPDragScroller = 16;
static const NSEventModifierFlags DPDragKeys = NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift;  // Not Caps Lock.
static NSEvent *DPPressed;

// Links and buttons show a hand and text an I-beam, so only the plain arrow drags. The page's own scrollbar and anything drawn over it, like the toolbar, are left alone.
static NSView *DPPageTopUnder(NSEvent *event) {
    NSWindow *window = event.window;
    if (!window || (window.styleMask & NSWindowStyleMaskFullScreen) || NSCursor.currentCursor != NSCursor.arrowCursor) return nil;
    Class card = NSClassFromString(@"DPPeekCard");
    NSView *content = window.contentView, *hit = [content hitTest:[content.superview convertPoint:event.locationInWindow fromView:nil]];
    return DPFindView(content, ^BOOL(NSView *view) {
        if (!DPIsKind(view, "WebContentsHostView") || view.isHiddenOrHasHiddenAncestor) return NO;
        for (NSView *up = view; up; up = up.superview) if ([up isKindOfClass:card]) return NO;
        NSPoint point = [view convertPoint:event.locationInWindow fromView:nil];
        CGFloat fromTop = view.isFlipped ? point.y : NSHeight(view.bounds) - point.y;
        return NSPointInRect(point, view.bounds) && fromTop <= DPDragBand && point.x <= NSMaxX(view.bounds) - DPDragScroller && [hit isDescendantOf:view];
    });
}

static NSEvent *DPDragMouse(NSEvent *event) {
    NSEvent *pressed = DPPressed;
    switch (event.type) {
    case NSEventTypeLeftMouseDown:
        DPPressed = nil;
        if (!DPDragWindowFromPage.on || event.clickCount != 1 || (event.modifierFlags & DPDragKeys) || !DPPageTopUnder(event)) return event;
        DPPressed = event;
        return nil;
    case NSEventTypeLeftMouseDragged:
        if (!pressed) return event;
        if (hypot(event.locationInWindow.x - pressed.locationInWindow.x, event.locationInWindow.y - pressed.locationInWindow.y) < DPDragSlop) return nil;
        DPPressed = nil;
        [pressed.window performWindowDragWithEvent:pressed];
        return nil;
    default:  // Let go without moving: it was a click after all, so the page gets it.
        DPPressed = nil;
        if (pressed) [pressed.window sendEvent:pressed];
        return event;
    }
}

static void DPInstallDragWindowFromPage(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
                                          handler:^NSEvent *(NSEvent *event) { return DPDragMouse(event); }];
}

DP_PATCH(DPDragWindowFromPage) {
    .key = @"dragWindowFromPage",
    .order = 96,
    .title = @"Drag Window from Page",
    .detail = @"Drag an empty spot near the top of a page to move the window, like a title bar. Handy with the toolbar and sidebar hidden.",
    .symbol = @"macwindow.and.cursorarrow",
    .tint = @"systemBrownColor",
    .section = @"Window",
    .install = DPInstallDragWindowFromPage,
};
