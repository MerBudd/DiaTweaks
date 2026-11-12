#import "TurnOffAI.h"

// Rows hidden through the table itself: the chat suggestion, Settings' Apps and Skills panes, the chat shortcuts, and
// the chat sounds.
#define DPDiaSuggestionsView   "_TtC15BoostCommandBar15SuggestionsView"
#define DPDiaShortcutsPane     "_TtC11Preferences45KeyboardShortcutsPreferencePaneViewController"
#define DPDiaPreferencesTable  "_TtC11Preferences20PreferencesTableView"

static char DPAIRowsKey;

static BOOL DPFoldsRows(NSTableView *table) {
    id owner = table.delegate;
    return DPIsKind(owner, DPDiaSuggestionsView) || DPIsKind(owner, DPDiaSettingsSidebar) || DPIsKind(owner, DPDiaShortcutsPane)
        || DPIsKind(owner, DPDiaPreferencesTable);
}

static BOOL DPIsAIRowView(NSTableView *table, NSView *row) {
    BOOL sidebar = DPIsKind(table.delegate, DPDiaSettingsSidebar), suggestions = DPIsKind(table.delegate, DPDiaSuggestionsView);
    return DPFindView(row, ^BOOL(NSView *view) {
        if ([view isKindOfClass:NSImageView.class]) return [view.accessibilityLabel isEqual:@"chat"];
        // A suggestion's text is what was typed or a page's title, which can start with "Chat with" too. Only the icon
        // says the row is Dia's chat.
        if (suggestions) return NO;
        NSString *text = [view isKindOfClass:NSTextField.class] ? [(NSTextField *)view stringValue] : view.accessibilityLabel;
        if (sidebar) return [text isEqual:@"Apps"] || [text isEqual:@"Skills"];
        return DPIsAITitle(text);
    }) != nil;
}

// A hidden row has no view to look at, so the ones hidden here are shown again first, all before anything is drawn.
// Rows are only looked at between updates: asking a table for a view while it updates throws.
static void DPFindAIRows(NSTableView *table) {
    // Hiding and showing rows are updates too.
    static BOOL finding;
    if (finding) return;
    finding = YES;
    // The table keeps its hidden rows in step as rows come and go; what was found before may point past the end now.
    if ([DPGet(table, &DPAIRowsKey) count] && table.hiddenRowIndexes.count)
        [table unhideRowsAtIndexes:table.hiddenRowIndexes withAnimation:NSTableViewAnimationEffectNone];
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    for (NSInteger row = 0; DPTurnOffAI.on && row < table.numberOfRows; row++) {
        NSView *view = [table rowViewAtRow:row makeIfNecessary:YES];
        if (view && DPIsAIRowView(table, view)) [rows addIndex:row];
    }
    BOOL changed = ![rows isEqualToIndexSet:DPGet(table, &DPAIRowsKey) ?: [NSIndexSet indexSet]];
    DPSet(table, &DPAIRowsKey, rows);
    if (rows.count) [table hideRowsAtIndexes:rows withAnimation:NSTableViewAnimationEffectNone];
    finding = NO;
    if (!changed || !DPIsKind(table.delegate, DPDiaSuggestionsView)) return;
    for (NSView *view = table; view; view = view.superview)
        if (DPIsKind(view, DPDiaCommandBar)) { view.needsLayout = YES; break; }
}

CGFloat DPHiddenSuggestionsHeight(NSView *suggestions) {
    if (!DPTurnOffAI.on) return 0;
    NSTableView *table = (NSTableView *)DPFindView(suggestions, ^BOOL(NSView *view) { return [view isKindOfClass:NSTableView.class]; });
    NSIndexSet *rows = DPGet(table, &DPAIRowsKey);
    CGFloat height = 0;
    for (NSUInteger row = rows.firstIndex; rows.count && row != NSNotFound; row = [rows indexGreaterThanIndex:row])
        height += [(id<NSTableViewDelegate>)table.delegate tableView:table heightOfRow:row];
    return height;
}

static void DPTable_endUpdates(NSTableView *self, SEL _cmd) {
    DPCallOriginal(DPTable_endUpdates, self);
    if (DPFoldsRows(self)) DPFindAIRows(self);
}

static void DPTable_reloadData(NSTableView *self, SEL _cmd) {
    DPCallOriginal(DPTable_reloadData, self);
    if (DPFoldsRows(self)) DPFindAIRows(self);
}

// Dia picks the command bar's suggestion itself, hidden or not, so landing on the chat row moves on the way the arrow
// key did.
static void DPTable_selectRows(NSTableView *self, SEL _cmd, NSIndexSet *rows, BOOL extend) {
    NSInteger from = self.selectedRow;
    DPCallOriginal(DPTable_selectRows, self, rows, extend);
    if (!DPTurnOffAI.on || rows.count != 1 || ![DPGet(self, &DPAIRowsKey) containsIndex:rows.firstIndex]) return;
    if (!DPIsKind(self.delegate, DPDiaSuggestionsView)) return;
    BOOL up = from > (NSInteger)rows.firstIndex && rows.firstIndex > 0;
    if (!up && rows.firstIndex + 1 >= (NSUInteger)self.numberOfRows) up = YES;
    NSResponder *editor = self.window.firstResponder;
    dispatch_async(dispatch_get_main_queue(), ^{ [editor doCommandBySelector:up ? @selector(moveUp:) : @selector(moveDown:)]; });
}

void DPApplyAIRows(void) {
    for (NSView *table in DPFindViews("NSTableView"))
        if (DPFoldsRows((NSTableView *)table)) DPFindAIRows((NSTableView *)table);
}

void DPInstallAIRows(void) {
    DPHookClass(NSTableView.class, @selector(endUpdates), (IMP)DPTable_endUpdates);
    DPHookClass(NSTableView.class, @selector(reloadData), (IMP)DPTable_reloadData);
    DPHookClass(NSTableView.class, @selector(selectRowIndexes:byExtendingSelection:), (IMP)DPTable_selectRows);
}
