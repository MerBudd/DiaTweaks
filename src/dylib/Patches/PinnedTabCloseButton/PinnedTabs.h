#import "StdPatch/StdPatch.h"

extern DPPatch DPPinnedTabCloseButton, DPPinnedTabMinusButton;  // The minus button is an option of the close button.

// The view model's delegate of a TabView (its TabController) or a TabContentView (its TabContentController).
id DPViewModelDelegate(NSView *view);
NSView *DPEnclosingTab(NSView *view);
void DPRelayoutTabContents(void);  // Each tab's page row picks its close button as it's laid out.

id DPAttributes(NSView *content);
BOOL DPIsOpenPinned(NSView *content);  // Takes a TabContentView.
// Runs `click`, a click on the close button of `content`, as Dia's closeKeepingTab: the page closes and the tab stays
// pinned, as with Dia's minus under a folded folder. NO, without clicking, if the tab has no close button style.
BOOL DPClickKeepingTab(NSView *content, void (^click)(void));
BOOL DPCloseKeepingTab(NSView *content);  // The same for a click made here. NO if Dia can't be asked.
