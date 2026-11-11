#import "Patches/Peek/Peek.h"
#import "Patches/HideToolbar/HideToolbar.h"

// Dia's loading glow along the bottom of the Peek's toolbar, as its own bars and Little Dia's show it: Dia's shader in
// Dia's colors, rising from the bottom edge as far as the page has loaded, then fading once it has.
static const NSTimeInterval DPGlowCycle = 2;
// Dia's finish, timed from Little Dia's bar: the rest of the way across, a hold at full width, then a quick fade.
static const NSTimeInterval DPGlowFinish = 0.3, DPGlowHold = 0.1, DPGlowFade = 0.15;
static const CGFloat DPGlowEase = 0.15;  // While loading: how much of the gap to the page's progress it closes each frame.

@interface DPPeekGlow : NSView
@property (nonatomic, weak) id page;
@property (nonatomic, strong) CAMetalLayer *shader;
@property (nonatomic, strong) CALayer *line;  // Without the shader: a plain line in the accent color.
@property (nonatomic, strong) NSTimer *frames;
@property (nonatomic) CGFloat fraction, shown, finishFrom;
@property (nonatomic) CFTimeInterval finishStart;
@property (nonatomic) BOOL loading, finishing, fading;
@end

@implementation DPPeekGlow
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (BOOL)wantsUpdateLayer { return YES; }

- (instancetype)initWithPage:(id)page {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.page = page;
    self.wantsLayer = YES;
    self.alphaValue = 0;
    self.shader = DPProgressShaderLayer();
    if (self.shader) {
        CAGradientLayer *fade = [CAGradientLayer layer];  // Hide Toolbar's fade, the right way up.
        fade.colors = @[(id)NSColor.blackColor.CGColor, (id)NSColor.clearColor.CGColor];
        fade.startPoint = CGPointMake(0.5, 0.35);
        fade.endPoint = CGPointMake(0.5, 1);
        self.shader.mask = fade;
        [self.layer addSublayer:self.shader];
    } else {
        self.line = [CALayer layer];
        [self.layer addSublayer:self.line];
    }
    return self;
}

- (void)dealloc { [_frames invalidate]; }

- (void)updateLayer { self.line.backgroundColor = NSColor.controlAccentColor.CGColor; }

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.shader.frame = self.bounds;
    self.shader.mask.frame = self.shader.bounds;
    self.shader.contentsScale = self.window.backingScaleFactor ?: 2;
    self.shader.drawableSize = CGSizeMake(NSWidth(self.bounds) * self.shader.contentsScale, NSHeight(self.bounds) * self.shader.contentsScale);
    self.line.frame = NSMakeRect(0, 0, round(NSWidth(self.bounds) * self.shown), 2);
    [CATransaction commit];
    [self draw];
}

- (NSView *)pane {
    for (NSView *view = self.superview; view; view = view.superview)
        if ([view isKindOfClass:DPPeekCard.class]) return ((DPPeekCard *)view).pane;
    return nil;
}

- (void)draw {
    if (!self.shader) return (void)(self.needsLayout = YES);
    simd_float3 primary, secondary;
    DPProgressColors(self.pane, @"dia", &primary, &secondary);
    DPDrawProgressShader(self.shader, self.shown, fmod(CACurrentMediaTime(), DPGlowCycle) / DPGlowCycle, primary, secondary);
}

// Once the page has loaded, the glow still runs on to the right edge, however fast, and only then fades, as Dia's does.
- (void)step {
    NSObject *page = self.page;
    BOOL loading = [[page valueForKey:@"isLoading"] boolValue];
    if (loading && !self.loading) {  // Starts again from the left, as Dia's does.
        self.shown = self.fraction = 0;
        self.finishing = self.fading = NO;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0;
            self.animator.alphaValue = 1;
        }];
    }
    if (!loading && self.loading) {
        self.fraction = 1;
        self.finishing = YES;
        self.finishFrom = self.shown;
        self.finishStart = CACurrentMediaTime();
    }
    self.loading = loading;
    if (loading) self.fraction = MAX(self.fraction, MAX(0.1, [[page valueForKey:@"loadProgress"] doubleValue]));
    if (!loading && !self.finishing) return;
    CFTimeInterval since = CACurrentMediaTime() - self.finishStart;
    if (!self.finishing) self.shown += (self.fraction - self.shown) * DPGlowEase;
    else {
        CGFloat t = MIN(1, since / DPGlowFinish), eased = 1 - (1 - t) * (1 - t);  // Ease out, as Dia's slows into the edge.
        self.shown = self.finishFrom + (1 - self.finishFrom) * eased;
    }
    if (self.finishing && !self.fading && since >= DPGlowFinish + DPGlowHold) {
        self.fading = YES;
        __weak DPPeekGlow *weak = self;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = DPGlowFade;
            self.animator.alphaValue = 0;
        } completionHandler:^{
            DPPeekGlow *glow = weak;
            if (!glow.fading) return;  // A new load took over.
            glow.finishing = glow.fading = NO;
            glow.fraction = glow.shown = 0;
        }];
    }
    [self draw];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self.frames invalidate];
    self.frames = nil;
    if (!self.window) return;
    __weak DPPeekGlow *weak = self;
    self.frames = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) { [weak step]; }];
    [NSRunLoop.mainRunLoop addTimer:self.frames forMode:NSRunLoopCommonModes];
}
@end

NSView *DPPeekGlowFor(id page) { return [[DPPeekGlow alloc] initWithPage:page]; }
