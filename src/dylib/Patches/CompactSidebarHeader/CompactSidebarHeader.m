#import "StdPatch/StdPatch.h"

extern DPPatch DPCompactSidebarHeader;
static const CGFloat DPHeaderTrim = 10;
static const CGFloat DPTopTabsButtonInset = 14;  // Where Dia puts the window buttons, from the window's corner, with tabs at the top.
static NSHashTable<NSView *> *DPSidebars;
static char DPHeaderFrameKey, DPButtonsFrameKey, DPRetriesKey;

static NSRect DPLaidOutHeader(NSView *header) {
    return [DPDiaValue(header, &DPHeaderFrameKey, @(header.frame)) rectValue];
}

// The close button's frame from the window's top left corner.
static NSRect DPCloseButtonInWindow(NSView *lights) {
    NSView *close = DPFindView(lights, ^BOOL(NSView *v) { return [v isKindOfClass:NSButton.class] && v == [v.window standardWindowButton:NSWindowCloseButton]; });
    if (!close || !lights.window) return NSZeroRect;
    NSRect r = [close convertRect:close.bounds toView:nil];
    r.origin.y = NSHeight(lights.window.contentView.superview.bounds) - NSMaxY(r);
    return r;
}

// With tabs at the top Dia moves the window buttons into the corner; the compact header puts them in the same spot. A
// sidebar floating over the page has them elsewhere, so only buttons already near the corner move. In full screen macOS
// slides the buttons in with the menu bar, laying the header out each frame, so they stay where Dia puts them.
static void DPHeader_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(DPHeader_layout, self);
    NSView *lights = DPFindView(self, ^BOOL(NSView *v) { return DPIsKind(v, DPDiaTrafficLights); }), *row = lights.superview;
    if (!lights || row == self || !DPMayAdjust(row)) return;
    NSRect laidOut = [DPDiaValue(row, &DPButtonsFrameKey, @(row.frame)) rectValue], frame = laidOut;
    row.frame = laidOut;
    NSRect close = DPCloseButtonInWindow(lights);
    CGFloat dx = DPTopTabsButtonInset - NSMinX(close), dy = DPTopTabsButtonInset - NSMinY(close);
    BOOL fullScreen = (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    // At launch Dia lays the header out before the window's buttons are in it, then not again until the sidebar changes.
    NSUInteger retries = [DPGet(self, &DPRetriesKey) unsignedIntegerValue];
    if (DPCompactSidebarHeader.on && NSIsEmptyRect(close) && self.window && retries < 8) {
        DPSet(self, &DPRetriesKey, @(retries + 1));
        __weak NSView *header = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{ header.needsLayout = YES; });
    }
    if (DPCompactSidebarHeader.on && !fullScreen && !NSIsEmptyRect(close) && fabs(dx) <= 6 && fabs(dy) <= 6) {
        frame.origin.x += dx;
        frame.origin.y += self.isFlipped ? dy : -dy;
    }
    DPOverride(row, &DPButtonsFrameKey, @(laidOut), @(frame));
    row.frame = frame;
}

static void DPCompactHeader(NSView *sidebar) {
    NSView *header = DPSubview(sidebar, DPDiaSidebarHeader);
    if (!header || !DPMayAdjust(header)) return;
    NSRect laidOut = DPLaidOutHeader(header), frame = laidOut;
    if (DPCompactSidebarHeader.on) frame.size.height = MAX(0, NSHeight(laidOut) - DPHeaderTrim);
    DPOverride(header, &DPHeaderFrameKey, @(laidOut), @(frame));
    header.frame = frame;
    // The view under the header keeps its bottom edge, so whatever follows it stays put.
    for (NSView *sub in sidebar.subviews) {
        if (sub == header) continue;
        CGFloat top = NSMinY(sub.frame);
        if (fabs(top - NSMaxY(laidOut)) > 0.5 && fabs(top - NSMaxY(laidOut) + DPHeaderTrim) > 0.5) continue;
        sub.frame = NSMakeRect(NSMinX(sub.frame), NSMaxY(frame), NSWidth(sub.frame), NSMaxY(sub.frame) - NSMaxY(frame));
    }
}

static void DPSidebar_viewDidLayout(NSViewController *self, SEL _cmd) {
    DPCallOriginal(DPSidebar_viewDidLayout, self);
    [DPSidebars addObject:self.view];
    if (self.view.isFlipped) DPCompactHeader(self.view);
}

static void DPInstallCompactSidebarHeader(void) {
    DPSidebars = [NSHashTable weakObjectsHashTable];
    DPHook(DPDiaSidebarController, @selector(viewDidLayout), (IMP)DPSidebar_viewDidLayout);
    DPHook(DPDiaSidebarHeader, @selector(layout), (IMP)DPHeader_layout);
}

static void DPApplyCompactSidebarHeader(DPPatch *patch) { DPRelayoutViews(DPSidebars); }

// A sidebar that isn't open passes: with tabs at the top there's no header.
static NSString *DPVerifyCompactSidebarHeader(DPPatch *patch) {
    for (NSView *header in DPFindViews(DPDiaSidebarHeader)) {
        if (header.hiddenOrHasHiddenAncestor || !header.superview.isFlipped) continue;
        CGFloat trimmed = NSHeight(DPLaidOutHeader(header)) - NSHeight(header.frame);
        if (fabs(trimmed - (patch->on ? DPHeaderTrim : 0)) > 0.5) return patch->on ? @"header is full height" : @"header is still trimmed";
        NSView *lights = DPFindView(header, ^BOOL(NSView *v) { return DPIsKind(v, DPDiaTrafficLights); });
        NSRect close = lights ? DPCloseButtonInWindow(lights) : NSZeroRect;
        BOOL cornered = fabs(NSMinX(close) - DPTopTabsButtonInset) < 0.5 && fabs(NSMinY(close) - DPTopTabsButtonInset) < 0.5;
        BOOL fullScreen = (header.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
        if (patch->on && !fullScreen && !NSIsEmptyRect(close) && !cornered) return @"window buttons aren't where top tabs put them";
    }
    return nil;
}

DP_PATCH(DPCompactSidebarHeader) {
    .key = @"compactSidebarHeader",
    .order = 76,
    .section = @"Sidebar & Tab Bar",
    .title = @"Compact Sidebar Header",
    .detail = @"Move the pinned tabs up into the empty space under the window buttons.",
    .symbol = @"arrow.up.to.line.square.fill",
    .tint = @"systemTealColor",
    .classes = DPClasses(DPDiaSidebarController, DPDiaSidebarHeader, DPDiaTrafficLights),
    .install = DPInstallCompactSidebarHeader,
    .apply = DPApplyCompactSidebarHeader,
    .verify = DPVerifyCompactSidebarHeader,
};
