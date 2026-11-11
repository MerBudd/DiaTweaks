#import "Patches/Peek/Peek.h"
#import "Patches/HideToolbar/HideToolbar.h"

// Dia's Copy URL and Copy URL as Markdown copy the tab behind the card. In a Peek, their shortcuts, whatever they're set
// to, copy the Peek's page instead, and show the Copied message Dia shows for a tab.

static NSMenuItem *DPPeekMenuItem(NSMenu *menu, NSString *title) {
    for (NSMenuItem *item in menu.itemArray) {
        NSMenuItem *found = [item.title isEqual:title] ? item : DPPeekMenuItem(item.submenu, title);
        if (found) return found;
    }
    return nil;
}

static BOOL DPPeekIsShortcut(NSEvent *event, NSString *title) {
    NSMenuItem *item = DPPeekMenuItem(NSApp.mainMenu, title);
    NSString *key = item.keyEquivalent;
    if (!key.length) return NO;
    NSEventModifierFlags all = NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl;
    NSEventModifierFlags mask = item.keyEquivalentModifierMask & all;
    // A capital letter means Shift, whether or not the mask says so.
    if (![key isEqual:key.lowercaseString]) mask |= NSEventModifierFlagShift;
    return (event.modifierFlags & all) == mask && [event.charactersIgnoringModifiers caseInsensitiveCompare:key] == NSOrderedSame;
}

BOOL DPPeekCopyURL(DPPeekCard *peek, NSEvent *event) {
    BOOL markdown = DPPeekIsShortcut(event, @"Copy URL as Markdown");
    if (!markdown && !DPPeekIsShortcut(event, @"Copy URL")) return NO;
    NSObject *page = (NSObject *)peek.page;
    NSURL *url = [page valueForKey:@"url"];
    if (![url isKindOfClass:NSURL.class]) return NO;
    NSString *title = [page valueForKey:@"title"];
    if (![title isKindOfClass:NSString.class] || !title.length) title = url.absoluteString;
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    [board clearContents];
    if (markdown) [board setString:[NSString stringWithFormat:@"[%@](%@)", title, url.absoluteString] forType:NSPasteboardTypeString];
    else {
        [board setString:url.absoluteString forType:NSPasteboardTypeString];
        [board setString:url.absoluteString forType:NSPasteboardTypeURL];
    }
    // Dia's own wording, at the top of the card as Dia shows it at the top of the page.
    DPShowCopyToast(peek.clip, markdown ? @"Copied URL as Markdown" : @"Copied Current URL");
    return YES;
}
