#import "StdPatch/StdPatch.h"
#include <simd/simd.h>

extern DPPatch DPHideToolbar, DPRevealToolbarOnHover, DPShowToolbarWithSidebar, DPShowToolbarOnNewTab, DPShowToolbarWithTopTabs, DPPlainSelectedTab;
extern DPPatch DPPeekToolbarOnCopy, DPCopyToast, DPShowLoadingProgress;
extern NSHashTable<NSView *> *DPPanes;

@interface DPToolbarHover : NSObject
@property (nonatomic, weak) NSView *pane, *bar, *bookmarks;
@property (nonatomic, strong) NSTrackingArea *tracking;
@property (nonatomic, strong) NSTimer *animation, *hideTimer, *inPlaceAnimation, *peekTimer;
@property (nonatomic) BOOL revealed, inPlace, peeking;
@property (nonatomic) CGFloat progress, inPlaceProgress;  // Revealed by the pointer, and kept in place by an option.
+ (DPToolbarHover *)forPane:(NSView *)pane;  // nil until the pane is laid out.
+ (DPToolbarHover *)attachToPane:(NSView *)pane;
- (void)updateForBar:(NSView *)bar bookmarks:(NSView *)bookmarks;
- (void)peek;
- (void)endPeek;
@end

NSRect DPLaidOutFrame(NSView *view);  // Where Dia put the view, before the patch moved it.
CGFloat DPTop(NSView *pane, NSRect r);  // From the pane's top, either way it's flipped.
CGFloat DPBottom(NSView *pane, NSRect r);
NSView *DPBookmarksUnder(NSView *pane, NSView *bar);
BOOL DPKeptInPlace(NSView *pane);
NSString *DPVerifyKeptInPlace(DPPatch *patch);
void DPApplyToolbar(NSView *pane);
void DPApplyToolbarOpacity(DPToolbarHover *hover);
void DPRelayoutPanes(void);
void DPRepaintTabs(NSWindow *window);

void DPShowCopyToast(NSView *pane, NSString *message);
void DPRemoveCopyToasts(void);
NSString *DPVerifyNoCopyToast(DPPatch *patch);

void DPShowProgressLine(NSView *pane, CGFloat fraction);
void DPFinishProgressLine(NSView *pane);
void DPRemoveProgressLine(NSView *pane);
BOOL DPShowsProgressLine(NSView *pane);

CAMetalLayer *DPProgressShaderLayer(void);  // nil when Dia's loading shader can't be loaded.
void DPDrawProgressShader(CAMetalLayer *layer, CGFloat progress, CGFloat cycle, simd_float3 primary, simd_float3 secondary);
BOOL DPProgressColorSlots(NSUInteger slots[2]);

NSMenu *DPProgressColorChoices(void);
void DPProgressColors(NSView *pane, NSString *choice, simd_float3 *primary, simd_float3 *secondary);
void DPInstallProgressColors(void);
