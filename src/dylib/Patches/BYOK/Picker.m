#import "Patches/BYOK/BYOK.h"

#define DPDiaCapabilitiesToolbar "_TtC23AssistantCapabilitiesUI32AssistantCapabilitiesToolbarView"
#define DPDiaDictationToolbar    "_TtC15BoostCommandBar20DictationToolbarView"
#define DPDiaPlaceholderText     "_TtC5ARCUI23TextViewWithPlaceholder"

@interface DPBYOKPickerButton : NSButton
@property (nonatomic, assign) CGFloat preferredWidth;
@property (nonatomic, assign) BOOL hovered;
@property (nonatomic, assign) BOOL pressed;
- (void)updateTitleAndSize;
- (void)updateColors;
@end

static NSHashTable<DPBYOKPickerButton *> *gAllPickers;

@implementation DPBYOKPickerButton

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.bordered = NO;
    self.wantsLayer = YES;
    self.layer.masksToBounds = YES;
    self.layer.cornerRadius = 8.0;
    self.layer.borderWidth = 0.5;
    self.alignment = NSTextAlignmentCenter;
    self.imagePosition = NSNoImage;
    self.accessibilityRole = NSAccessibilityButtonRole;
    self.accessibilityLabel = @"BYOK Model Picker";
    [self updateColors];
    [self updateTitleAndSize];
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (void)updateColors {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        CGFloat bgAlpha = self.pressed ? 0.15 : (self.hovered ? 0.11 : 0.06);
        self.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:bgAlpha].CGColor;
        self.layer.borderColor = [NSColor.labelColor colorWithAlphaComponent:0.10].CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateColors];
    [self updateTitleAndSize];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                          owner:self
                                                       userInfo:nil];
    [self addTrackingArea:area];
}

- (void)mouseEntered:(NSEvent *)event {
    self.hovered = YES;
    [self updateColors];
}

- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
    [self updateColors];
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

- (void)updateTitleAndSize {
    NSString *provider = DPBYOKProvider();
    NSString *activeModel = DPBYOKActiveModel();
    NSString *modelTitle = DPBYOKDisplayNameForModel(provider, activeModel);
    if (!modelTitle || modelTitle.length == 0) {
        modelTitle = @"Dia Default";
    }
    if (modelTitle.length > 24) {
        modelTitle = [[modelTitle substringToIndex:22] stringByAppendingString:@"…"];
    }

    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    style.lineBreakMode = NSLineBreakByTruncatingTail;

    NSMutableAttributedString *attrTitle = [[NSMutableAttributedString alloc] initWithString:modelTitle attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.labelColor,
        NSParagraphStyleAttributeName: style
    }];

    if (![activeModel isEqualToString:DPBYOKDiaDefaultModel]) {
        NSArray *levels = DPBYOKThinkingLevelsForModel(provider, activeModel);
        if (levels.count > 0) {
            NSString *lvl = DPBYOKThinkingLevel(provider, activeModel);
            NSString *lvlLabel = DPBYOKThinkingLabel(lvl);
            if (lvlLabel.length == 0 && lvl.length > 0) {
                lvlLabel = lvl.capitalizedString;
            }
            if (lvlLabel.length > 0) {
                NSAttributedString *levelAttr = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %@", lvlLabel] attributes:@{
                    NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightRegular],
                    NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
                    NSParagraphStyleAttributeName: style
                }];
                [attrTitle appendAttributedString:levelAttr];
            }
        }
    }

    NSAttributedString *chevronAttr = [[NSAttributedString alloc] initWithString:@" ▾" attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
        NSParagraphStyleAttributeName: style
    }];
    [attrTitle appendAttributedString:chevronAttr];

    self.attributedTitle = attrTitle;
    CGFloat width = ceil(attrTitle.size.width) + 18.0;
    self.preferredWidth = MIN(210.0, MAX(72.0, width));
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(self.preferredWidth > 0 ? self.preferredWidth : 72.0, 26.0);
}

- (void)mouseDown:(NSEvent *)event {
    self.pressed = YES;
    [self updateColors];

    NSMenu *menu = DPBYOKBuildModelMenu(YES, NO);
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, self.bounds.size.height + 4) inView:self];

    self.pressed = NO;
    if (self.window) {
        NSPoint mouseLoc = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
        self.hovered = NSPointInRect(mouseLoc, self.bounds);
    } else {
        self.hovered = NO;
    }
    [self updateColors];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self mouseDown:event];
}

@end

static BOOL DPShouldShowBYOKPicker(NSView *commandBar) {
    if (!DPBYOK.on || !DPBYOKModelPicker.on || DPTurnOffAI.on) return NO;
    if (!commandBar) return NO;

    NSView *capToolbar = DPCommandBarPart(commandBar, DPDiaCapabilitiesToolbar);
    if (capToolbar) {
        if (DPCompactCommandBar.on || DPCompactToolbar(commandBar) != nil) return NO;
    }

    NSView *dictation = DPCommandBarPart(commandBar, DPDiaDictationToolbar);
    if (dictation && !dictation.isHidden && dictation.alphaValue > 0.01) return NO;

    return YES;
}

static DPBYOKPickerButton *DPFindOrCreatePickerInView(NSView *container) {
    for (NSView *subview in container.subviews) {
        if ([subview isKindOfClass:[DPBYOKPickerButton class]]) {
            return (DPBYOKPickerButton *)subview;
        }
    }
    DPBYOKPickerButton *picker = [[DPBYOKPickerButton alloc] initWithFrame:NSMakeRect(0, 0, 72, 26)];
    [container addSubview:picker];
    if (!gAllPickers) gAllPickers = [NSHashTable weakObjectsHashTable];
    [gAllPickers addObject:picker];
    return picker;
}

static DPBYOKPickerButton *DPFindOrCreatePickerInCommandBar(NSView *commandBar) {
    for (NSView *subview in commandBar.subviews) {
        if ([subview isKindOfClass:[DPBYOKPickerButton class]]) {
            return (DPBYOKPickerButton *)subview;
        }
    }
    DPBYOKPickerButton *picker = [[DPBYOKPickerButton alloc] initWithFrame:NSMakeRect(0, 0, 72, 26)];
    [commandBar addSubview:picker positioned:NSWindowAbove relativeTo:nil];
    if (!gAllPickers) gAllPickers = [NSHashTable weakObjectsHashTable];
    [gAllPickers addObject:picker];
    return picker;
}

static NSView *DPFindAttachButton(NSView *toolbar) {
    if (!toolbar) return nil;

    __block NSView *found = nil;
    DPFindView(toolbar, ^BOOL(NSView *v) {
        if (DPIsKind(v, DPDiaCommandBarButton)) {
            NSString *label = v.accessibilityLabel.lowercaseString;
            if (label.length > 0 && ([label containsString:@"add"] || [label containsString:@"file"] || [label containsString:@"tab"])) {
                found = v;
                return YES;
            }
        }
        return NO;
    });
    if (found) return found;

    NSView *firstSub = toolbar.subviews.firstObject;
    if ([firstSub isKindOfClass:[NSStackView class]]) {
        NSStackView *stack = (NSStackView *)firstSub;
        NSMutableArray<NSView *> *buttons = [NSMutableArray new];
        for (NSView *v in stack.subviews) {
            if (DPIsKind(v, DPDiaCommandBarButton)) {
                [buttons addObject:v];
            }
        }
        if (buttons.count >= 2) {
            return buttons.firstObject;
        }
    }
    return nil;
}

static void DPAdjustTextContainerForPicker(NSView *commandBar, DPBYOKPickerButton *picker) {
    if (!picker || picker.isHidden) return;
    NSView *textContainer = DPCommandBarPart(commandBar, DPDiaCommandBarText);
    if (!textContainer || !textContainer.superview) return;

    NSRect pickerInInput = [commandBar convertRect:picker.frame toView:textContainer.superview];
    if (NSMinY(pickerInInput) < NSMaxY(textContainer.frame) && NSMaxY(pickerInInput) > NSMinY(textContainer.frame)) {
        CGFloat maxRight = NSMinX(pickerInInput) - 6.0;
        if (NSMaxX(textContainer.frame) > maxRight) {
            if (DPMayAdjust(textContainer)) {
                NSRect frame = textContainer.frame;
                frame.size.width = MAX(0.0, maxRight - NSMinX(frame));
                textContainer.frame = frame;
            }
        }
    }
}

static void DPLayoutPickerInCapToolbar(NSView *capToolbar, NSView *commandBar) {
    if (!capToolbar) return;

    DPBYOKPickerButton *picker = DPFindOrCreatePickerInView(capToolbar);
    [picker updateTitleAndSize];

    NSView *addBtn = nil;
    for (NSView *subview in capToolbar.subviews) {
        if (DPIsKind(subview, DPDiaCapabilityButton)) {
            if (!addBtn || NSMaxX(subview.frame) > NSMaxX(addBtn.frame)) {
                addBtn = subview;
            }
        }
    }

    CGFloat x = addBtn ? (NSMaxX(addBtn.frame) + 8.0) : 8.0;
    CGFloat maxW = MAX(0.0, NSWidth(capToolbar.bounds) - x - 8.0);
    CGFloat w = MIN(picker.preferredWidth, maxW);
    CGFloat h = 26.0;
    CGFloat y = round((NSHeight(capToolbar.bounds) - h) / 2.0);
    picker.frame = NSMakeRect(x, y, w, h);

    BOOL shouldShow = DPShouldShowBYOKPicker(commandBar) && (w >= 50.0);
    picker.hidden = !shouldShow;
}

static void DPLayoutPickerInChatCommandBar(NSView *commandBar) {
    DPBYOKPickerButton *picker = DPFindOrCreatePickerInCommandBar(commandBar);
    [picker updateTitleAndSize];

    BOOL shouldShow = DPShouldShowBYOKPicker(commandBar);
    NSView *toolbar = DPCommandBarPart(commandBar, DPDiaCommandBarToolbar);
    if (!shouldShow || !toolbar) {
        picker.hidden = YES;
        return;
    }

    NSView *plusBtn = DPFindAttachButton(toolbar);
    NSRect plusRect;
    if (plusBtn) {
        plusRect = [plusBtn convertRect:plusBtn.bounds toView:commandBar];
    } else {
        plusRect = [toolbar convertRect:toolbar.bounds toView:commandBar];
    }

    CGFloat rightEdge = NSMinX(plusRect) - 6.0;
    CGFloat availW = MAX(0.0, rightEdge - 80.0);
    CGFloat w = MIN(picker.preferredWidth, availW);
    CGFloat h = 26.0;
    CGFloat x = rightEdge - w;
    CGFloat y = round(NSMinY(plusRect) + (NSHeight(plusRect) - h) / 2.0);

    picker.frame = NSMakeRect(x, y, w, h);
    if (w < 50.0) {
        picker.hidden = YES;
    } else {
        picker.hidden = NO;
        DPAdjustTextContainerForPicker(commandBar, picker);
    }
}

static void DPApplyBYOKPickerToCommandBar(NSView *commandBar) {
    if (!commandBar) return;

    NSView *capToolbar = DPCommandBarPart(commandBar, DPDiaCapabilitiesToolbar);
    if (capToolbar) {
        for (NSView *subview in commandBar.subviews) {
            if ([subview isKindOfClass:[DPBYOKPickerButton class]]) {
                subview.hidden = YES;
            }
        }
        DPLayoutPickerInCapToolbar(capToolbar, commandBar);
    } else {
        DPLayoutPickerInChatCommandBar(commandBar);
    }
}

static void DPBYOKCommandBar_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(DPBYOKCommandBar_layout, self);
    DPApplyBYOKPickerToCommandBar(self);
}

static void DPBYOKCommandBarInput_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(DPBYOKCommandBarInput_layout, self);

    NSView *commandBar = self;
    while (commandBar && !DPIsKind(commandBar, DPDiaCommandBar)) {
        commandBar = commandBar.superview;
    }
    if (!commandBar) return;

    for (NSView *subview in commandBar.subviews) {
        if ([subview isKindOfClass:[DPBYOKPickerButton class]]) {
            DPBYOKPickerButton *picker = (DPBYOKPickerButton *)subview;
            if (!picker.isHidden) {
                DPAdjustTextContainerForPicker(commandBar, picker);
            }
            break;
        }
    }
}

static void DPBYOKCapabilitiesToolbar_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(DPBYOKCapabilitiesToolbar_layout, self);

    NSView *commandBar = self.superview;
    while (commandBar && !DPIsKind(commandBar, DPDiaCommandBar)) {
        commandBar = commandBar.superview;
    }
    if (commandBar) {
        DPLayoutPickerInCapToolbar(self, commandBar);
    }
}

static NSAttributedString *DPBYOKPlaceholder_get(NSTextView *self, SEL _cmd) {
    NSAttributedString *res = DPCallOriginal(DPBYOKPlaceholder_get, self);
    NSView *commandBar = self.superview;
    while (commandBar && !DPIsKind(commandBar, DPDiaCommandBar)) {
        commandBar = commandBar.superview;
    }
    if (commandBar) {
        DPApplyBYOKPickerToCommandBar(commandBar);
    }
    return res;
}

void DPInstallBYOKPicker(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gAllPickers = [NSHashTable weakObjectsHashTable];
    });

    DPHook(DPDiaCommandBar, @selector(layout), (IMP)DPBYOKCommandBar_layout);
    DPHook(DPDiaCommandBarInput, @selector(layout), (IMP)DPBYOKCommandBarInput_layout);
    DPHook(DPDiaCapabilitiesToolbar, @selector(layout), (IMP)DPBYOKCapabilitiesToolbar_layout);
    DPHook(DPDiaPlaceholderText, @selector(placeholderAttributedString), (IMP)DPBYOKPlaceholder_get);
}

void DPApplyBYOKPicker(DPPatch *patch) {
    (void)patch;
    DPUpdateAllBYOKPickers();
}

void DPUpdateAllBYOKPickers(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DPUpdateAllBYOKPickers();
        });
        return;
    }

    if (gAllPickers) {
        for (DPBYOKPickerButton *btn in gAllPickers) {
            [btn updateTitleAndSize];
        }
    }

    for (NSView *commandBar in DPFindViews(DPDiaCommandBar)) {
        NSView *capToolbar = DPCommandBarPart(commandBar, DPDiaCapabilitiesToolbar);
        if (capToolbar) {
            capToolbar.needsLayout = YES;
        }
        commandBar.needsLayout = YES;
        [commandBar layoutSubtreeIfNeeded];
    }
}

NSString *DPVerifyBYOKPicker(DPPatch *patch) {
    (void)patch;
    for (NSView *commandBar in DPFindViews(DPDiaCommandBar)) {
        if (!commandBar.window || commandBar.isHidden || commandBar.hiddenOrHasHiddenAncestor || commandBar.alphaValue < 0.01 || NSWidth(commandBar.bounds) < 160.0) {
            continue;
        }

        BOOL shouldShow = DPShouldShowBYOKPicker(commandBar);
        DPBYOKPickerButton *picker = (DPBYOKPickerButton *)DPFindView(commandBar, ^BOOL(NSView *v) {
            return [v isKindOfClass:[DPBYOKPickerButton class]] && !v.isHidden;
        });
        if (!picker) {
            picker = (DPBYOKPickerButton *)DPFindView(commandBar, ^BOOL(NSView *v) {
                return [v isKindOfClass:[DPBYOKPickerButton class]];
            });
        }

        if (shouldShow && (!picker || picker.isHidden)) {
            return @"BYOK model picker is missing from command bar";
        }
        if (!shouldShow && (picker && !picker.isHidden)) {
            return @"BYOK model picker is still visible when disabled";
        }
    }
    return nil;
}
