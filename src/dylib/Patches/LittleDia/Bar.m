#import "LittleDia.h"
#import <objc/message.h>

// One per popup bar: the buttons around Dia's address, which keeps its own look and Dia's updates to it.
@interface DPLittleBar : NSObject
@property (nonatomic, weak) NSView *title;
@property (nonatomic) NSArray<NSButton *> *leading;  // close, back, forward, reload
@property (nonatomic) NSButton *open;
@property (nonatomic) NSButton *profiles;  // Open in another profile; hidden with only one.
@property (nonatomic) NSView *address;
@property (nonatomic) NSView *divider;
@property (nonatomic) NSTimer *timer;
@end

static const CGFloat DPInset = 6, DPGap = 2, DPButton = 28, DPChevron = 20;

@interface DPBarDivider : NSView
@end

@implementation DPBarDivider
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)rect {
    [[NSColor.labelColor colorWithAlphaComponent:0.1] setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
}
@end

NSView *DPMakeDivider(void) { return [DPBarDivider new]; }

// The page's background, or failing that its theme-color. Chromium has neither for some pages: nil.
static NSColor *DPPageColor(id page) {
    id root = [page respondsToSelector:@selector(rootBackgroundColor)] ? ((id (*)(id, SEL))objc_msgSend)(page, @selector(rootBackgroundColor)) : nil;
    float (*part)(id, SEL) = (void *)objc_msgSend;
    if ([root respondsToSelector:@selector(a)] && part(root, @selector(a)) > 0.99)
        return [NSColor colorWithSRGBRed:part(root, @selector(r)) green:part(root, @selector(g)) blue:part(root, @selector(b)) alpha:1];
    id theme = [page respondsToSelector:@selector(themeColor)] ? ((id (*)(id, SEL))objc_msgSend)(page, @selector(themeColor)) : nil;
    unsigned char (*byte)(id, SEL) = (void *)objc_msgSend;
    if ([theme respondsToSelector:@selector(a)] && byte(theme, @selector(a)) == 255)
        return [NSColor colorWithSRGBRed:byte(theme, @selector(r)) / 255.0 green:byte(theme, @selector(g)) / 255.0 blue:byte(theme, @selector(b)) / 255.0 alpha:1];
    return nil;
}

static char DPColorKey;

void DPMatchPage(NSView *row, id page) {
    NSColor *color = DPPageColor(page);
    if ([DPGet(row, &DPColorKey) isEqual:color] || (!color && !DPGet(row, &DPColorKey))) return;
    DPSet(row, &DPColorKey, color);
    row.wantsLayer = YES;
    row.layer.backgroundColor = color.CGColor;
    CGFloat luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent;
    row.appearance = !color ? nil : [NSAppearance appearanceNamed:luminance > 0.55 ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
}

@interface DPBarButton : NSButton
@property (nonatomic, copy) void (^handler)(void);
@property (nonatomic) BOOL hovered, pill;  // pill: a filled button with an icon and a word, laid out like Dia's Chat button
@property (nonatomic) NSImageView *pillIcon;
@property (nonatomic) NSTextField *pillLabel;
@property (nonatomic) CGFloat outerCorner;  // The radius of the top corner nearest the window's, for a button tucked into it.
@property (nonatomic) BOOL outerCornerOnRight;
@end

@implementation DPBarButton

- (instancetype)initWithSymbol:(NSString *)symbol size:(CGFloat)size label:(NSString *)label {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.bordered = NO;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 6;
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightSemibold];
    self.image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label] imageWithSymbolConfiguration:config];
    self.imagePosition = NSImageOnly;
    self.accessibilityLabel = label;
    self.toolTip = label;
    self.target = self;
    self.action = @selector(run:);
    [self updateTint];
    return self;
}

- (void)run:(id)sender { if (self.handler) self.handler(); }

// Dia's Chat button: a 16pt icon 10pt in, the word 4pt after it, 9pt after that.
- (NSSize)intrinsicContentSize {
    return self.pill ? NSMakeSize(30 + ceil(self.pillLabel.intrinsicContentSize.width) + 9, 28) : NSMakeSize(28, 28);
}

- (NSView *)hitTest:(NSPoint)point { return [super hitTest:point] ? self : nil; }

- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)updateTint {
    self.contentTintColor = !self.enabled ? NSColor.tertiaryLabelColor : self.hovered || self.pill ? NSColor.labelColor : NSColor.secondaryLabelColor;
    // labelColor with alpha keeps the appearance it was made in, so this follows the bar's light or dark look itself.
    CGFloat alpha = self.hovered ? 1 : 0.85;
    self.pillIcon.contentTintColor = self.pillLabel.textColor = [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        __block NSColor *color;
        [appearance performAsCurrentDrawingAppearance:^{ color = [[NSColor.labelColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace] colorWithAlphaComponent:alpha]; }];
        return color;
    }];
    self.needsDisplay = YES;
}

- (void)setEnabled:(BOOL)enabled {
    if (enabled == self.enabled) return;
    super.enabled = enabled;
    [self updateTint];
}

- (void)updateTrackingAreas {
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil]];
    [super updateTrackingAreas];
}

- (void)mouseEntered:(NSEvent *)event { self.hovered = YES; [self updateTint]; }
- (void)mouseExited:(NSEvent *)event { self.hovered = NO; [self updateTint]; }

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    if (!self.outerCorner) return;
    // CALayer rounds every corner alike, so the shape is drawn: one corner follows the window's, the rest stay small.
    CGFloat small = self.layer.cornerRadius, big = MIN(self.outerCorner, NSHeight(self.bounds) / 2);
    CGFloat left = self.outerCornerOnRight ? small : big, right = self.outerCornerOnRight ? big : small;
    NSRect r = self.bounds;
    CGFloat top = self.isFlipped ? NSMinY(r) : NSMaxY(r), bottom = self.isFlipped ? NSMaxY(r) : NSMinY(r), down = self.isFlipped ? 1 : -1;
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, NSMinX(r), top + down * left);
    CGPathAddArcToPoint(path, NULL, NSMinX(r), top, NSMinX(r) + left, top, left);
    CGPathAddArcToPoint(path, NULL, NSMaxX(r), top, NSMaxX(r), bottom, right);
    CGPathAddArcToPoint(path, NULL, NSMaxX(r), bottom, NSMinX(r), bottom, small);
    CGPathAddArcToPoint(path, NULL, NSMinX(r), bottom, NSMinX(r), top, small);
    CGPathCloseSubpath(path);
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.path = path;
    CGPathRelease(path);
    self.layer.mask = mask;
}

- (void)drawRect:(NSRect)rect {
    CGFloat fill = self.pill ? (self.hovered ? 0.12 : 0.08) : (self.hovered && self.enabled ? 0.08 : 0);
    self.layer.backgroundColor = fill ? [NSColor.labelColor colorWithAlphaComponent:fill].CGColor : nil;
    [super drawRect:rect];
}

@end

NSButton *DPMakeBarButton(NSString *symbol, NSString *label, NSString *key, void (^action)(void)) {
    DPBarButton *button = [[DPBarButton alloc] initWithSymbol:symbol size:13 label:label];
    button.handler = action;
    if (key) {
        button.keyEquivalent = key;
        button.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    }
    return button;
}

static NSButton *DPMakeOpenInDiaButton(void (^action)(void)) {
    DPBarButton *button = [[DPBarButton alloc] initWithSymbol:@"arrow.up.forward" size:12 label:@"Open in Dia"];
    button.pill = YES;
    button.pillIcon = [NSImageView imageViewWithImage:button.image];
    button.image = nil;
    button.pillIcon.frame = NSMakeRect(10, 6, 16, 16);
    button.pillLabel = [NSTextField labelWithString:@"Open in Dia"];
    button.pillLabel.font = [NSFont systemFontOfSize:13];
    button.pillLabel.frame = NSMakeRect(30, 6, ceil(button.pillLabel.intrinsicContentSize.width), 16);
    [button addSubview:button.pillIcon];
    [button addSubview:button.pillLabel];
    button.toolTip = @"Open this page in a tab (⌘O)";
    button.keyEquivalent = @"o";
    button.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    button.handler = action;
    [button updateTint];
    return button;
}

// Dia's main window comes forward on the chosen profile, with the page as a new tab, and the small window closes.
static void DPShowProfiles(NSButton *button) {
    NSWindow *window = button.window;
    NSMenu *menu = [NSMenu new];
    [DPLittleDiaProfiles() enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        NSMenuItem *item = DPMenuItem(name, ^{
            DPBringBackPutAway(window);
            DPOpenInProfile(DPLittleDiaURL(window), i, ^(BOOL opened) {
                if (!opened) return NSBeep();
                DPPromoteLittleDiaWindow(window);
                [window performClose:nil];
            });
        });
        item.image = DPLittleDiaProfileImage(name);
        if (@available(macOS 27, *)) [item setValue:@1 forKey:@"preferredImageVisibility"];  // 1: .visible
        [menu addItem:item];
    }];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(button.bounds) + 4) inView:button];
}

static NSButton *DPMakeProfilesButton(void) {
    DPBarButton *button = [[DPBarButton alloc] initWithSymbol:@"chevron.down" size:10 label:@"Open in Another Profile"];
    button.pill = YES;
    __weak DPBarButton *weakButton = button;
    button.handler = ^{ DPShowProfiles(weakButton); };
    button.hidden = DPLittleDiaProfiles().count < 2;
    [button updateTint];
    return button;
}

@implementation DPLittleBar
- (void)dealloc { [_timer invalidate]; }
@end

static char DPBarKey;  // The DPLittleBar on Dia's address view.
static char DPHiddenByUsKey;
static const CGFloat DPAddressHeight = 30;

// The page has no change notifications that reach here, so the bar looks at it a few times a second.
static void DPUpdateButtons(DPLittleBar *bar) {
    id page = DPLittleDiaPage(bar.title.window);
    BOOL (*flag)(id, SEL) = (void *)objc_msgSend;
    bar.leading[1].enabled = page && flag(page, @selector(canGoBack));
    bar.leading[2].enabled = page && flag(page, @selector(canGoForward));
    bar.leading[3].enabled = page != nil;
}

static DPLittleBar *DPMakeBar(NSView *title) {
    DPLittleBar *bar = [DPLittleBar new];
    bar.title = title;
    __weak NSView *weakTitle = title;
    bar.leading = @[
        DPMakeBarButton(@"xmark", @"Close", nil, ^{ [weakTitle.window performClose:nil]; }),
        DPMakeBarButton(@"chevron.left", @"Back", nil, ^{ DPLittleDiaGo(weakTitle.window, @selector(goBack)); }),
        DPMakeBarButton(@"chevron.right", @"Forward", nil, ^{ DPLittleDiaGo(weakTitle.window, @selector(goForward)); }),
        DPMakeBarButton(@"arrow.clockwise", @"Reload", @"r", ^{ DPLittleDiaGo(weakTitle.window, @selector(reload)); }),
    ];
    bar.open = DPMakeOpenInDiaButton(^{
        if (DPSendToLittleDia(DPLittleDiaTab(weakTitle.window, @"promote"))) DPPromoteLittleDiaWindow(weakTitle.window);
        else NSBeep();
    });
    bar.profiles = DPMakeProfilesButton();
    bar.address = DPMakeAddressView(title);
    bar.divider = DPMakeDivider();
    __weak DPLittleBar *weakBar = bar;
    bar.timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        if (!weakBar.title.window) return;
        DPUpdateButtons(weakBar);
        DPRefreshAddressView(weakBar.address);
        DPMatchPage(weakBar.title.superview, DPLittleDiaPage(weakBar.title.window));
    }];
    return bar;
}

static void DPPlaceBar(DPLittleBar *bar) {
    NSView *title = bar.title, *row = title.superview;
    CGFloat mid = NSMidY(title.frame);
    [bar.leading enumerateObjectsUsingBlock:^(NSButton *button, NSUInteger i, BOOL *stop) {
        if (button.superview != row) [row addSubview:button];
        button.frame = NSMakeRect(DPInset + i * (DPButton + DPGap), round(mid - DPButton / 2), DPButton, DPButton);
    }];
    NSSize open = bar.open.intrinsicContentSize;
    if (bar.open.superview != row) [row addSubview:bar.open];
    if (bar.profiles.superview != row) [row addSubview:bar.profiles];
    // The same gap above them as beside them.
    CGFloat top = round(mid - open.height / 2), gap = NSHeight(row.bounds) - NSMaxY(NSMakeRect(0, top, 0, open.height));
    CGFloat chevron = bar.profiles.hidden ? 0 : DPGap + DPChevron;
    bar.open.frame = NSMakeRect(NSWidth(row.bounds) - gap - chevron - open.width, top, open.width, open.height);
    bar.profiles.frame = NSMakeRect(NSMaxX(bar.open.frame) + DPGap, top, DPChevron, open.height);
    CGFloat corner = [row.window respondsToSelector:@selector(_cornerRadius)] ? ((CGFloat (*)(id, SEL))objc_msgSend)(row.window, @selector(_cornerRadius)) : 16;
    // The first and last buttons sit in the window's top corners, so those corners of them follow the window's.
    for (DPBarButton *button in @[ bar.leading.firstObject, bar.profiles.hidden ? bar.open : bar.profiles ]) {
        NSRect inWindow = [row convertRect:button.frame toView:nil];
        button.outerCornerOnRight = button != bar.leading.firstObject;
        CGFloat side = button.outerCornerOnRight ? NSWidth(row.window.frame) - NSMaxX(inWindow) : NSMinX(inWindow);
        button.outerCorner = MAX(button.layer.cornerRadius, corner - MAX(side, NSHeight(row.window.frame) - NSMaxY(inWindow)));
        button.needsLayout = YES;
    }
    // Dia's address stays, unseen, so its frame keeps telling this layout where the address belongs.
    title.alphaValue = 0;
    if (bar.address.superview != row) [row addSubview:bar.address positioned:NSWindowAbove relativeTo:title];
    bar.address.frame = NSMakeRect(NSMinX(title.frame), round(mid - DPAddressHeight / 2), NSWidth(title.frame), DPAddressHeight);
    CGFloat hairline = 1 / MAX(1, row.window.backingScaleFactor);
    if (bar.divider.superview != row) [row addSubview:bar.divider];
    bar.divider.frame = NSMakeRect(0, row.isFlipped ? NSHeight(row.bounds) - hairline : 0, NSWidth(row.bounds), hairline);
    // Dia's Downloads button would sit under Open in Dia. Newer Dia puts it in a stack it shows and hides it in itself, so
    // the row's view holding it is what's hidden.
    for (NSView *view in row.subviews)
        if (!view.hidden && DPFindView(view, ^BOOL(NSView *each) { return DPHasLabel(each, @"Downloads"); })) {
            view.hidden = YES;
            DPSet(view, &DPHiddenByUsKey, @YES);
        }
    DPUpdateButtons(bar);
}

static void DPRemoveBar(NSView *title) {
    DPLittleBar *bar = DPGet(title, &DPBarKey);
    if (!bar) return;
    DPSet(title, &DPBarKey, nil);
    [bar.timer invalidate];
    for (NSView *view in [bar.leading arrayByAddingObjectsFromArray:@[ bar.open, bar.profiles ]]) [view removeFromSuperview];
    [bar.address removeFromSuperview];
    [bar.divider removeFromSuperview];
    title.alphaValue = 1;
    DPMatchPage(title.superview, nil);
    for (NSView *view in title.superview.subviews)
        if ([DPGet(view, &DPHiddenByUsKey) boolValue]) {
            view.hidden = NO;
            DPSet(view, &DPHiddenByUsKey, nil);
        }
}

// Dia lays out its popup bar around its address view, so this follows that view's frame to lay out Little Dia's bar.
static char DPDiaOriginKey, DPDiaSizeKey;

static BOOL DPInPopupBar(NSView *view) {
    for (NSView *each = view.superview; each; each = each.superview)
        if (DPIsKind(each, DPDiaPopupBar)) return YES;
    return NO;
}

static BOOL DPShowsBar(NSView *title) { return DPLittleDia.on && DPInPopupBar(title) && DPIsLittleDiaWindow(title.window); }

static NSRect DPTitleFrame(NSView *title, DPLittleBar *bar) {
    NSRect bounds = title.superview.bounds;
    NSPoint diaOrigin = [DPGet(title, &DPDiaOriginKey) pointValue];
    NSSize diaSize = [DPGet(title, &DPDiaSizeKey) sizeValue];
    CGFloat left = DPInset + bar.leading.count * DPButton + (bar.leading.count - 1) * DPGap + DPInset;
    CGFloat right = NSWidth(bounds) - DPInset - bar.open.intrinsicContentSize.width - (bar.profiles.hidden ? 0 : DPGap + DPChevron) - 6;
    return NSMakeRect(left, diaOrigin.y, MAX(0, right - left), diaSize.height);
}

static DPLittleBar *DPBarFor(NSView *title) {
    DPLittleBar *bar = DPGet(title, &DPBarKey);
    if (!bar) DPSet(title, &DPBarKey, bar = DPMakeBar(title));
    return bar;
}

// Dia keeps setting the address's frame; in a Little Dia window it gets this layout's instead.
static void DPTitle_setFrameOrigin(NSView *self, SEL _cmd, NSPoint origin) {
    if (!DPInPopupBar(self)) return DPCallOriginal(DPTitle_setFrameOrigin, self, origin);
    DPSet(self, &DPDiaOriginKey, [NSValue valueWithPoint:origin]);
    if (!DPShowsBar(self)) {
        DPRemoveBar(self);
        return DPCallOriginal(DPTitle_setFrameOrigin, self, origin);
    }
    DPCallOriginal(DPTitle_setFrameOrigin, self, DPTitleFrame(self, DPBarFor(self)).origin);
    DPPlaceBar(DPBarFor(self));
}

static void DPTitle_setFrameSize(NSView *self, SEL _cmd, NSSize size) {
    if (!DPInPopupBar(self)) return DPCallOriginal(DPTitle_setFrameSize, self, size);
    DPSet(self, &DPDiaSizeKey, [NSValue valueWithSize:size]);
    if (!DPGet(self, &DPDiaOriginKey)) DPSet(self, &DPDiaOriginKey, [NSValue valueWithPoint:self.frame.origin]);
    if (!DPShowsBar(self)) {
        DPRemoveBar(self);
        return DPCallOriginal(DPTitle_setFrameSize, self, size);
    }
    DPCallOriginal(DPTitle_setFrameSize, self, DPTitleFrame(self, DPBarFor(self)).size);
    DPPlaceBar(DPBarFor(self));
}

void DPRelayoutLittleDiaBars(void) {
    for (NSView *bar in DPFindViews(DPDiaPopupBar)) {
        NSView *title = DPFindView(bar, ^BOOL(NSView *view) { return DPIsKind(view, DPDiaPopupTitle); });
        if (!title) continue;
        NSValue *origin = DPGet(title, &DPDiaOriginKey), *size = DPGet(title, &DPDiaSizeKey);
        [title setFrameOrigin:origin ? origin.pointValue : title.frame.origin];
        [title setFrameSize:size ? size.sizeValue : title.frame.size];
    }
}

void DPInstallLittleDiaBar(void) {
    DPHook(DPDiaPopupTitle, @selector(setFrameOrigin:), (IMP)DPTitle_setFrameOrigin);
    DPHook(DPDiaPopupTitle, @selector(setFrameSize:), (IMP)DPTitle_setFrameSize);
}
