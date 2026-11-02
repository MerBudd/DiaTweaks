#import "ChatModelPicker.h"

@implementation DPChatModelPickerButton

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 7.0;
    self.target = self;
    self.action = @selector(showModelMenu:);
    [self reloadFromConfig];
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    [self showModelMenu:self];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) [self removeTrackingArea:self.trackingArea];
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                     options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways)
                                                       owner:self
                                                    userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    self.isHovered = YES;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent *)event {
    self.isHovered = NO;
    self.needsDisplay = YES;
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

- (void)reloadFromConfig {
    NSDictionary *cfg = DPLoadChatModelConfig();
    NSString *active = cfg[@"activeModel"] ?: @"claude-opus-4-6";
    self.modelId = active;
    self.thinkingLevel = cfg[@"activeThinkingLevel"] ?: @"adaptive";
    self.modelTitle = DPFriendlyModelName(active, nil);
    self.needsDisplay = YES;
}

- (NSAttributedString *)attributedTitle {
    NSMutableAttributedString *str = [[NSMutableAttributedString alloc] init];
    NSFont *font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    NSColor *titleColor = self.isHovered ? NSColor.labelColor : [NSColor.labelColor colorWithAlphaComponent:0.9];
    NSColor *secColor = self.isHovered ? NSColor.secondaryLabelColor : [NSColor.secondaryLabelColor colorWithAlphaComponent:0.85];

    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.lineBreakMode = NSLineBreakByTruncatingTail;
    para.alignment = NSTextAlignmentLeft;

    // 1. Model Title
    [str appendAttributedString:[[NSAttributedString alloc] initWithString:self.modelTitle ?: @"Model"
                                                                attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: titleColor,
        NSParagraphStyleAttributeName: para
    }]];

    // 2. Thinking Level (if any)
    if (self.thinkingLevel.length && ![self.thinkingLevel isEqualToString:@"off"] && ![self.thinkingLevel isEqualToString:@"disabled"]) {
        NSString *cap = [self.thinkingLevel capitalizedString];
        if (![cap isEqualToString:@"Adaptive"]) {
            [str appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" %@", cap]
                                                                        attributes:@{
                NSFontAttributeName: font,
                NSForegroundColorAttributeName: secColor,
                NSParagraphStyleAttributeName: para
            }]];
        }
    }

    // 3. Dropdown Chevron
    [str appendAttributedString:[[NSAttributedString alloc] initWithString:@" ⌵"
                                                                attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: secColor,
        NSParagraphStyleAttributeName: para
    }]];

    return str;
}

- (NSSize)sizeThatFits:(NSSize)limit {
    NSAttributedString *attr = [self attributedTitle];
    NSSize strSize = [attr size];
    CGFloat w = ceil(strSize.width) + 16.0;
    if (limit.width > 0 && w > limit.width) {
        w = limit.width;
    }
    return NSMakeSize(w, 26.0);
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bgRect = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bgRect xRadius:7.0 yRadius:7.0];
    NSColor *bgColor = self.isHovered ? [NSColor.labelColor colorWithAlphaComponent:0.12] : [NSColor.labelColor colorWithAlphaComponent:0.06];
    [bgColor setFill];
    [path fill];

    NSAttributedString *title = [self attributedTitle];
    NSSize strSize = [title size];
    CGFloat availableWidth = self.bounds.size.width - 16.0;
    if (availableWidth < 10.0) availableWidth = 10.0;
    NSRect textRect = NSMakeRect(8.0, (self.bounds.size.height - strSize.height) / 2.0, availableWidth, strSize.height);
    [title drawWithRect:textRect options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
}

@end
