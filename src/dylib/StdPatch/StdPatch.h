#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "StdPatch/Dia.h"

#pragma mark Patches

typedef struct DPPatch DPPatch;
struct DPPatch {
    __unsafe_unretained NSString *key;
    BOOL defaultOn;
    int order;  // Orders sections in Settings; rewritten at load.
    __unsafe_unretained NSString *title, *detail;
    __unsafe_unretained NSString *hint;
    __unsafe_unretained NSString *symbol, *tint;  // symbol: space-separated fallbacks for older macOS. tint: an NSColor class property.
    __unsafe_unretained NSString *section;  // For an option, its heading on its patch's page.
    const char *const *classes;  // DPClasses it needs; if one is missing it stays off.
    const char *const *builtIn;  // DPClasses meaning Dia does this itself; if one exists it stays off.
    __unsafe_unretained NSString *requires;    // Makes this an option on that patch's page.
    __unsafe_unretained NSString *disabledBy;  // While on, that patch hides what this one changes.
    __unsafe_unretained NSString *coveredBy;   // While on, that patch does this one's job too, so this one is greyed out.
    __unsafe_unretained NSString *choice, *defaultChoice;  // Saved as the chosen item's representedObject.
    NSMenu *(*choices)(void);
    NSArray<NSView *> *(*rows)(void);  // Under Options, or the heading in a view's identifier.
    // sharesShortcutWith: a menu action, such as @"undo:", whose item may use the same shortcut without a warning.
    __unsafe_unretained NSString *shortcut, *sharesShortcutWith;
    NSDictionary *(*defaultShortcut)(void);
    BOOL (*hides)(NSView *view);
    void (*install)(void);  // Runs at launch whether or not the patch is on.
    void (*apply)(DPPatch *patch);  // Without it, `progress` eases toward `on` and every `relayout` runs each frame.
    void (*relayout)(void);
    // nil if Dia's views match `on`, else what's wrong. Use DPFindViews, not your hooks, so a hook that never ran fails.
    NSString *(*verify)(DPPatch *patch);
    // For patches that set things up outside Dia: nil if all of it is in place, else what's wrong. While it fails, turning the
    // patch on runs apply again, up to three tries, then turns the patch back off and tells the user why.
    NSString *(*ready)(DPPatch *patch);
    BOOL on, unavailable, inDia;
    CGFloat progress;
};

#define DPClasses(...) ((const char *const []){__VA_ARGS__, NULL})

//     DP_PATCH(DPHideFooButton) { .key = @"hideFooButton", .title = @"Hide Foo button", ... };
#define DP_PATCH(name)                                                                              \
    DPPatch name;                                                                                   \
    __attribute__((used, section("__DATA,__dppatches"))) static DPPatch *const name##Entry = &name; \
    DPPatch name =

extern DPPatch *const *DPPatches;  // In Settings order.
extern NSUInteger DPPatchCount;
DPPatch *DPPatchNamed(NSString *key);
DPPatch *DPRequired(DPPatch *patch);
void DPSetPatch(DPPatch *patch, BOOL on, BOOL save);  // save: NO lasts until Dia quits.
BOOL DPSavedOn(DPPatch *patch);
NSString *DPChoice(DPPatch *patch);
void DPSetChoice(DPPatch *patch, NSString *value);
void DPLoadPatches(void);
void DPInstallPatches(void);
BOOL DPWriteManifest(NSString *path);  // Reads no settings.
NSString *DPAppSupport(NSString *path);
NSString *DPRelayProblem(void);  // nil if diapatch and the original Dia it starts are in place.
NSString *DPHostProblem(NSString *manifest, NSString *name);  // nil if the native host manifest at that path sends `name` to diapatch.
extern NSNotificationName const DPPatchesDidChangeNotification;
#define DPLeadingOption @"DPLeadingOption"  // A row's identifier that puts it first under Options, above the options.
extern BOOL DPTesting;  // Under make test, which saves nothing and has no one to answer an alert.

#pragma mark Hooks

// Two patches may hook one method: each DPCallOriginal calls what was there when it was installed.
void DPHook(const char *className, SEL sel, IMP replacement);
void DPHookClass(Class cls, SEL sel, IMP replacement);
IMP DPOriginalIMP(id object, SEL sel, IMP replacement);

#define DPCallOriginal(hook, self, ...) \
    ((__typeof__(&hook))DPOriginalIMP(self, _cmd, (IMP)hook))(self, _cmd, ##__VA_ARGS__)

#pragma mark Views

NSView *DPFindView(NSView *root, BOOL (^match)(NSView *view));  // Root included.
NSArray<NSView *> *DPFindViews(const char *className);
NSString *DPTabLayout(void);
NSView *DPSubview(NSView *parent, const char *className);
BOOL DPIsKind(id object, const char *className);
BOOL DPHasLabel(NSView *view, NSString *accessibilityLabel);
void DPRelayoutViews(NSHashTable<NSView *> *views);
// Call before changing a view's frame during layout. If Dia keeps restoring its frame, the two would loop until AppKit
// aborts Dia, so after a few changes to one view in a run loop turn this says no.
BOOL DPMayAdjust(NSView *view);
void *DPIvar(id object, const char *name);
// A Swift property the Objective-C runtime hides, through AXCoreUtilities; nil when the object has none.
id DPSwiftValue(id object, NSString *key);
NSArray<NSString *> *DPUUIDsIn(NSString *text);
NSWindowController *DPOpenTabSwitcher(void);

void DPSetHint(NSView *view, NSString *text);
NSString *DPHintOf(NSView *view);
void DPShowHint(NSView *view);

// Saved under the patch's `shortcut` key as @{keyCode, modifiers, key}, key being the label to show.
NSView *DPShortcutRow(DPPatch *patch);
BOOL DPShortcutMatches(NSEvent *event, DPPatch *patch);  // NO while any field is recording.

#pragma mark Values

id DPGet(id object, const void *key);
void DPSet(id object, const void *key, id value);

// DPDiaValue returns Dia's remembered value while `current` is still ours, else `current`.
void DPOverride(id object, const void *key, id dia, id ours);
id DPDiaValue(id object, const void *key, id current);

#pragma mark Extensions

// Loads the unpacked Chromium extension in `folder` into every profile. Chromium reads it once as Dia starts, so call
// it from an `install`.
void DPLoadExtension(NSString *folder);
void DPAddLaunchFlag(NSString *flag);  // A Chromium command-line flag, also read once as Dia starts.

#pragma mark App

void DPOnLaunch(void (^block)(void));
void DPOnQuit(void (^block)(void));

// menu: a menu bar title, nil for the app menu. Menus exist once Dia has launched: call these from DPOnLaunch.
NSMenuItem *DPMenuItem(NSString *title, void (^action)(void));
NSMenuItem *DPAddMenuItem(NSString *menu, NSString *title, void (^action)(void));
void DPOnMenuItem(NSString *menu, NSString *titlePrefix, void (^action)(void));
