#import "StdPatch/StdPatch.h"

// Dia's scripting objects for a window's tabs, shared by the tweaks that follow which tab is in front.
id DPScriptWindow(NSWindow *window);
id DPScriptTab(NSWindow *window, NSString *tabID);
NSString *DPTabID(id tab);
NSString *DPActiveTabID(NSWindow *window);
void DPFocusTab(id tab);
void DPCloseTab(id tab);
