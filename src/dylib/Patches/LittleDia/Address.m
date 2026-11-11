#import "LittleDia.h"
#import <objc/message.h>

// Dia's address, drawn like the one in its main window: "site / Page Title", and "site/path" in a soft field under the
// pointer. A click, or ⌘L, edits the whole URL; Return goes, Escape doesn't.
@interface DPAddressView : NSView <NSTextFieldDelegate>
@property (nonatomic, weak) NSView *title;
@property (nonatomic) NSTextField *label, *field;
@property (nonatomic) BOOL hovered, beginning, ending;
@property (nonatomic, copy) NSString *notice;  // Shown in place of the address for a moment, as "Copied current URL".
@property (nonatomic) NSUInteger notices;
@end

@implementation DPAddressView

- (instancetype)init {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 8;
    _label = [NSTextField labelWithString:@""];
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    _label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
    [self addSubview:_label];
    return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// The label inside would take the click for itself; while editing, the field gets it.
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    if (!hit) return nil;
    return self.field && [hit isDescendantOf:self.field] ? hit : self;
}
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.IBeamCursor]; }
- (void)mouseDown:(NSEvent *)event { [self begin]; }

- (void)updateTrackingAreas {
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil]];
    [super updateTrackingAreas];
}

- (void)mouseEntered:(NSEvent *)event { self.hovered = YES; [self refresh]; }
- (void)mouseExited:(NSEvent *)event { self.hovered = NO; [self refresh]; }

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (mods != NSEventModifierFlagCommand || ![event.charactersIgnoringModifiers isEqual:@"l"] || self.window != NSApp.keyWindow) return NO;
    [self begin];
    return YES;
}

- (NSURL *)url {
    NSURL *url = ((id (*)(id, SEL))objc_msgSend)(DPLittleDiaPage(self.window), @selector(url));
    return [url isKindOfClass:NSURL.class] ? url : nil;
}

- (NSString *)pageTitle {
    NSString *title = ((id (*)(id, SEL))objc_msgSend)(DPLittleDiaPage(self.window), @selector(title));
    return [title isKindOfClass:NSString.class] ? title : nil;
}

- (void)refresh {
    BOOL open = self.hovered || self.field;
    self.layer.backgroundColor = open ? [NSColor.labelColor colorWithAlphaComponent:0.07].CGColor : nil;
    if (self.field) return;
    NSURL *url = self.url;
    NSString *host = url.host ?: @"", *rest = @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if (!url) {
        NSTextView *shown = (NSTextView *)DPFindView(self.title, ^BOOL(NSView *view) { return [view isKindOfClass:NSTextView.class]; });
        host = shown.string ?: @"";
    } else if (self.hovered) {
        NSString *path = [url.path isEqual:@"/"] ? @"" : url.path ?: @"";
        rest = url.query.length ? [NSString stringWithFormat:@"%@?%@", path, url.query] : path;
    } else if (self.pageTitle.length && ![self.pageTitle isEqual:url.absoluteString]) {
        rest = [@" / " stringByAppendingString:self.pageTitle];
    }
    if (self.notice) {
        host = self.notice;
        rest = @"";
    }
    NSFont *font = [NSFont systemFontOfSize:13];
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:host attributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : NSColor.labelColor}];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:rest attributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : NSColor.secondaryLabelColor}]];
    if (![self.label.attributedStringValue isEqual:text]) self.label.attributedStringValue = text;
    CGFloat height = ceil(self.label.intrinsicContentSize.height);
    self.label.frame = NSMakeRect(10, round((NSHeight(self.bounds) - height) / 2), MAX(0, NSWidth(self.bounds) - 20), height);
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self refresh];
}

#pragma mark Typing another address
- (void)begin {
    if (self.field) {
        [self.window makeFirstResponder:self.field];
        return;
    }
    self.notice = nil;  // A notice in the label isn't an address to edit.
    [self refresh];
    NSString *shown = [self.url.absoluteString isEqual:@"about:blank"] ? @"" : self.url.absoluteString;
    NSTextField *field = [NSTextField textFieldWithString:shown ?: self.label.stringValue];
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.font = [NSFont systemFontOfSize:13];
    field.usesSingleLineMode = YES;
    field.cell.scrollable = YES;
    field.delegate = self;
    CGFloat height = ceil(field.intrinsicContentSize.height);
    field.frame = NSMakeRect(8, round((NSHeight(self.bounds) - height) / 2), NSWidth(self.bounds) - 16, height);
    field.autoresizingMask = NSViewWidthSizable;
    [self addSubview:field];
    self.field = field;
    self.label.hidden = YES;
    [self refresh];
    // selectText: focuses the field itself; focusing it first would have it end that editing straight away.
    self.beginning = YES;
    [field selectText:nil];
    self.beginning = NO;
}

- (void)end {
    if (!self.field || self.ending) return;
    self.ending = YES;
    [self.field removeFromSuperview];
    self.field = nil;
    self.label.hidden = NO;
    [self.window makeFirstResponder:nil];
    self.ending = NO;
    [self refresh];
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
    if (self.beginning) return;
    BOOL go = [note.userInfo[@"NSTextMovement"] integerValue] == NSTextMovementReturn;
    NSString *typed = self.field.stringValue;
    NSWindow *window = self.window;
    [self end];
    if (go) DPLittleDiaNavigate(window, typed);
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    if (command != @selector(cancelOperation:)) return NO;
    [self end];
    return YES;
}

@end

NSView *DPMakeAddressView(NSView *title) {
    DPAddressView *view = [DPAddressView new];
    view.title = title;
    return view;
}

void DPRefreshAddressView(NSView *view) {
    if ([view isKindOfClass:DPAddressView.class]) [(DPAddressView *)view refresh];
}

// Chromium focuses the new window's page a moment after it opens, which would end the typing, so this starts after that,
// and waits for the bar to be laid out.
static void DPEditAddressSoon(NSWindow *window, int tries) {
    NSView *address = DPFindView(window.contentView.superview, ^BOOL(NSView *view) { return [view isKindOfClass:DPAddressView.class]; });
    if (address && window.isKeyWindow) return [(DPAddressView *)address begin];
    if (tries > 0 && window.visible)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ DPEditAddressSoon(window, tries - 1); });
}

void DPEditLittleDiaAddress(NSWindow *window) {
    __weak NSWindow *weak = window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ if (weak) DPEditAddressSoon(weak, 20); });
}

void DPShowLittleDiaNotice(NSWindow *window, NSString *message) {
    DPAddressView *address = (DPAddressView *)DPFindView(window.contentView.superview, ^BOOL(NSView *view) { return [view isKindOfClass:DPAddressView.class]; });
    if (!address || address.field) return;
    address.notice = message;
    NSUInteger notice = ++address.notices;
    [address refresh];
    __weak DPAddressView *weak = address;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (weak.notices != notice) return;
        weak.notice = nil;
        [weak refresh];
    });
}
