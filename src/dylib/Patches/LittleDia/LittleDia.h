// Little Dia opens links from other apps, and Open Link in Little Dia on a page's links, in Dia's own popup window, the one sites get from window.open, instead of a new
// tab. Only Chromium can make that window, so a small extension makes it with chrome.windows.create: the dylib wakes the
// extension's worker with an omnibox event, the one event Dia lets native code send it.
#import "StdPatch/StdPatch.h"

#define DPDiaOpenURLEvents "_TtC13OpenURLClient19OpenURLEventManager"
#define DPDiaPopupWindow   "_TtC5Popup19PlatformPopupWindow"
#define DPDiaPopupBar      "_TtC5Popup22PopupNavigationBarView"
#define DPDiaPopupTitle    "_TtC13NavigationBar21AssistantBarTitleView"

extern DPPatch DPLittleDia;

// Extension.m
void DPInstallLittleDiaExtension(void);
BOOL DPWriteLittleDiaExtension(BOOL on);
NSString *DPLittleDiaExtensionProblem(void);  // nil once its files are written.
BOOL DPSendToLittleDia(NSDictionary *request);  // Hands the extension {action, ...}: see its worker. NO until it's loaded.
BOOL DPLittleDiaStarting(void);  // Dia has no window or its extensions are still loading.
BOOL DPLittleDiaReady(void);     // DPSendToLittleDia would reach the extension.

// Options.m: the window's size, and Close with Escape.
NSSize DPLittleDiaSize(void);
NSArray<NSView *> *DPLittleDiaRows(void);

// Route.m
void DPInstallLittleDiaRoute(void);
void DPOpenLinkInLittleDia(NSURL *url);  // A link from Dia's own page, in the current profile.
void DPOpenBlankLittleDia(void);         // A blank page, with its address ready to type.

// LinkMenu.m: Open Link in Little Dia, in the menu for a link in a page.
void DPInstallLittleDiaLinkMenu(void);
NSString *DPLittleDiaLinkMenuProblem(void);

// NewWindow.m: New Little Dia Window in the File menu, there while Little Dia is on and ready.
void DPInstallLittleDiaNewWindow(void);
void DPRefreshLittleDiaNewWindow(void);
NSString *DPLittleDiaNewWindowProblem(void);

// Window.m: which popups are Little Dia's, their page, and their title bar.
void DPExpectLittleDiaWindow(NSRect frame, void (^missed)(void), void (^claimed)(NSWindow *window));  // A popup in the next 3 seconds is this link's, and `claimed` gets it; else `missed` runs.
BOOL DPIsLittleDiaWindow(NSWindow *window);  // Opened by Little Dia, whether or not it's still on.
id DPLittleDiaPage(NSWindow *window);        // Its ArcWebContents, once Chromium has handed it over.
void DPInstallLittleDiaWindows(void);
void DPRefreshLittleDiaWindows(void);        // After a claim or a switch in Settings.
void DPPromoteLittleDiaWindow(NSWindow *window);  // Open in Dia: when it closes, Dia's main window comes forward.

// Stack.m: the small window comes up over the app the link was clicked in; Dia's other windows stay behind that app.
void DPInstallLittleDiaStack(void);
void DPNoteStackForLink(void);
void DPRestoreStack(NSWindow *little);
void DPFinishStack(void);
pid_t DPLinkSource(void);            // The app the last link came from, or 0.
void DPReturnToSource(pid_t pid);
void DPBringBackPutAway(NSWindow *little);  // Dia's windows put away because it was hidden when the link came.
void DPLinkArrived(void);                   // A link for Little Dia came in.
BOOL DPHideAgain(void);                     // Hides Dia again once its last small window closes, if it was hidden.

// Bar.m: close, back, forward and reload before the address, Open in Dia and a profile menu after it, and no Downloads
// button.
void DPInstallLittleDiaBar(void);
// Also Peek's toolbar, so the two bars look and behave alike.
NSButton *DPMakeBarButton(NSString *symbol, NSString *label, NSString *key, void (^action)(void));  // key: with ⌘, or nil.
NSView *DPMakeDivider(void);
void DPMatchPage(NSView *row, id page);  // The row takes the page's color, and a light or dark look to suit it.
void DPRelayoutLittleDiaBars(void);

// Address.m: the address as Dia's main window shows it. Click it, or press ⌘L, to type another.
NSView *DPMakeAddressView(NSView *title);
void DPRefreshAddressView(NSView *view);
void DPEditLittleDiaAddress(NSWindow *window);  // As ⌘L does, once the window has its address.
void DPShowLittleDiaNotice(NSWindow *window, NSString *message);  // In place of the address, for a moment.

// Shortcuts.m: Dia's menu commands, like Copy URL, Go Back, Zoom In and Print, and their shortcuts, act on the page.
void DPInstallLittleDiaShortcuts(void);
NSString *DPLittleDiaShortcutsProblem(void);

// Navigate.m: the page's own navigation.
NSString *DPLittleDiaURL(NSWindow *window);                   // The page's address, or @"" before it has one.
NSDictionary *DPLittleDiaTab(NSWindow *window, NSString *action);  // A request naming the window's tab.
void DPLittleDiaGo(NSWindow *window, SEL action);             // goBack, goForward or reload
void DPLittleDiaNavigate(NSWindow *window, NSString *typed);  // An address, or words to search for.

// Profile.m: Dia's profiles, in its order, and opening a page as a tab in one, focused.
NSArray<NSString *> *DPLittleDiaProfiles(void);
NSImage *DPLittleDiaProfileImage(NSString *name);
void DPOpenInProfile(NSString *url, NSUInteger index, void (^done)(BOOL opened));
