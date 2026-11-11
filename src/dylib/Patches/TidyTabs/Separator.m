#import "TidyTabs.h"

// Dia's divider shows Close All while the pointer is on it; the broom shows and hides with it.
static char DPLineFrameKey;
static const CGFloat DPCloseAllGap = 4, DPLineGap = 6;

static CALayer *DPSeparatorLine(NSView *separator) {
    for (CALayer *layer in separator.layer.sublayers)
        if (NSHeight(layer.frame) <= 1.5 && NSWidth(layer.frame) > 20) return layer;
    return nil;
}

static NSView *DPCloseAll(NSView *separator) {
    for (NSView *sub in separator.subviews)
        if ([sub isKindOfClass:NSButton.class] && ![sub isKindOfClass:DPTidyBrush.class]) return sub;
    return nil;
}

static DPTidyBrush *DPBrushIn(NSView *separator, BOOL create) {
    for (NSView *sub in separator.subviews) if ([sub isKindOfClass:DPTidyBrush.class]) return (DPTidyBrush *)sub;
    if (!create) return nil;
    DPTidyBrush *brush = [DPTidyBrush new];
    brush.plain = YES;
    [separator addSubview:brush];
    return brush;
}

NSView *DPTidySeparatorIn(NSView *list) {
    NSScrollView *scroll = DPTidyListScroll(list);
    return scroll ? DPFindView(scroll.documentView, ^BOOL(NSView *view) {
        return DPIsKind(view, DPDiaTabListSeparator) && !view.hiddenOrHasHiddenAncestor;
    }) : nil;
}

static void DPCloseAll_setHidden(NSView *self, SEL _cmd, BOOL hidden) {
    DPCallOriginal(DPCloseAll_setHidden, self, hidden);
    if (DPIsKind(self.superview, DPDiaTabListSeparator)) DPPlaceSeparatorBrush(self.superview);
}

// Loose tabs below the line, from the layout, which knows off-screen rows too. Tab rows, folders, the New Tab row and a
// group's own row are all about as tall as each other (and the height changes between Dia builds), so a row is a tab by
// its cell's class where it has one. An off-screen row has no cell: it's a tab if it's the height of the others. A group's
// tabs are rows inside the group's frame, so a row inside a taller row isn't loose.
NSInteger DPTidyTabsBelowLine(NSView *list) {
    NSCollectionView *collection = (NSCollectionView *)DPTidyListScroll(list).documentView;
    if (![collection isKindOfClass:NSCollectionView.class]) return 0;
    NSView *separator = DPTidySeparatorIn(list);
    CGFloat line = separator ? NSMaxY([collection convertRect:separator.bounds fromView:separator]) - 0.5 : -CGFLOAT_MAX;
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    NSMutableArray<NSNumber *> *isTab = [NSMutableArray array];  // YES, NO, or nil when not on screen.
    NSCountedSet<NSNumber *> *heights = [NSCountedSet set];
    for (NSInteger section = 0; section < collection.numberOfSections; section++)
        for (NSInteger item = 0; item < [collection numberOfItemsInSection:section]; item++) {
            NSIndexPath *path = [NSIndexPath indexPathForItem:item inSection:section];
            NSRect frame = [collection.collectionViewLayout layoutAttributesForItemAtIndexPath:path].frame;
            if (NSMinY(frame) < line || NSHeight(frame) <= 0) continue;
            NSView *cell = [collection itemAtIndexPath:path].view;
            BOOL tab = cell && strstr(object_getClassName(cell), "TabUI7TabView");
            // The New Tab row is last. Off screen it would pass for a tab.
            if (!cell && section == collection.numberOfSections - 1 && item == [collection numberOfItemsInSection:section] - 1) continue;
            [frames addObject:[NSValue valueWithRect:frame]];
            [isTab addObject:cell ? @(tab) : (id)NSNull.null];
            if (tab) [heights addObject:@(round(NSHeight(frame)))];
        }
    NSNumber *height = nil;
    for (NSNumber *each in heights) if (!height || [heights countForObject:each] > [heights countForObject:height]) height = each;
    if (!height) return 0;
    NSInteger loose = 0;
    for (NSUInteger i = 0; i < frames.count; i++) {
        NSRect frame = frames[i].rectValue;
        if (isTab[i] == (id)NSNull.null ? fabs(NSHeight(frame) - height.doubleValue) > 1 : !isTab[i].boolValue) continue;
        BOOL inside = NO;
        for (NSValue *other in frames) inside |= NSHeight(other.rectValue) > NSHeight(frame) + 1 && NSPointInRect(NSMakePoint(NSMidX(frame), NSMidY(frame)), other.rectValue);
        loose += !inside;
    }
    return loose;
}

static NSView *DPListOf(NSView *view) {
    for (; view; view = view.superview) if (DPIsKind(view, DPDiaTabList)) return view;
    return nil;
}

void DPPlaceSeparatorBrush(NSView *separator) {
    NSView *closeAll = DPCloseAll(separator);
    // Close All's class is private to Dia's TabList module, so it's hooked once one turns up.
    static BOOL hooked;
    if (closeAll && !hooked) {
        hooked = YES;
        DPHookClass(object_getClass(closeAll), @selector(setHidden:), (IMP)DPCloseAll_setHidden);
    }
    // While busy the broom still follows Close All, and the wave fills the whole line when it's away.
    BOOL shown = DPTidyTabs.on && closeAll && !closeAll.hidden && (DPTidyIsBusy() || DPTidyTabsBelowLine(DPListOf(separator)) >= DPTidyMinimumTabs);
    DPTidyBrush *brush = DPBrushIn(separator, shown);
    CALayer *line = DPSeparatorLine(separator);
    if (!brush && !line) return;
    CGFloat right = closeAll ? NSMinX(closeAll.frame) - DPCloseAllGap : NSMaxX(separator.bounds) - 7;
    brush.frame = NSMakeRect(right - DPTidyBrushSize, round(NSMidY(separator.bounds) - DPTidyBrushSize / 2), DPTidyBrushSize, DPTidyBrushSize);
    brush.hidden = !shown;
    if (!line) return;
    NSRect dia = [DPDiaValue(line, &DPLineFrameKey, [NSValue valueWithRect:line.frame]) rectValue], frame = dia;
    CGFloat trimmed = MIN(NSWidth(dia), MAX(0, right - DPTidyBrushSize - DPLineGap - NSMinX(dia)));
    if (shown) frame.size.width = trimmed;
    DPOverride(line, &DPLineFrameKey, [NSValue valueWithRect:dia], [NSValue valueWithRect:frame]);
    if (!NSEqualRects(line.frame, frame)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        line.frame = frame;
        [CATransaction commit];
    }
    DPTidyWave(separator.layer, line, line.backgroundColor, DPTidyTabs.on && DPTidyIsBusy());
}

static void DPSeparator_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(DPSeparator_layout, self);
    DPPlaceSeparatorBrush(self);
}

static void DPSeparator_updateLayer(NSView *self, SEL _cmd) {
    DPCallOriginal(DPSeparator_updateLayer, self);
    DPPlaceSeparatorBrush(self);
}

// The tab list's collection view takes every click inside it, to drag tabs; a click on the broom goes to the broom.
static NSView *DPCollection_hitTest(NSView *self, SEL _cmd, NSPoint point) {
    for (DPTidyBrush *brush in DPTidyBrushes()) {
        if (brush.hiddenOrHasHiddenAncestor || ![brush isDescendantOf:self]) continue;
        if (NSPointInRect([brush convertPoint:point fromView:self.superview], brush.bounds)) return brush;
    }
    return DPCallOriginal(DPCollection_hitTest, self, point);
}

void DPInstallTidySeparator(void) {
    DPHook(DPDiaTabListCollection, @selector(hitTest:), (IMP)DPCollection_hitTest);
    DPHook(DPDiaTabListSeparator, @selector(layout), (IMP)DPSeparator_layout);
    DPHook(DPDiaTabListSeparator, @selector(updateLayer), (IMP)DPSeparator_updateLayer);
}
