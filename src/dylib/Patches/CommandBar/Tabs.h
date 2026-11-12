#import "StdPatch/StdPatch.h"

// Dia's scripting objects for a window's tabs, shared by the tweaks that follow which tab is in front.
id DPScriptWindow(NSWindow *window);
id DPScriptTab(NSWindow *window, NSString *tabID);
NSString *DPTabID(id tab);
NSString *DPActiveTabID(NSWindow *window);
void DPFocusTab(id tab);
void DPCloseTab(id tab);
// Dia doesn't say who closes a page, so the closes DiaTweaks makes are marked, and the page closing takes the mark. A
// mark lapses if no page closes soon after. DPCloseTab marks its own; DPMarkOwnClose is for a close made another way.
void DPMarkOwnClose(void);
BOOL DPTakeOwnClose(void);
