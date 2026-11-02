#import "ChatModelPicker.h"

@implementation DPChatModelPickerButton (Menu)

- (void)showModelMenu:(id)sender {
    NSMutableDictionary *cfg = DPLoadChatModelConfig();
    NSString *currentActive = cfg[@"activeModel"] ?: @"claude-opus-4-6";
    NSString *currentLevel = cfg[@"activeThinkingLevel"] ?: @"adaptive";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Model Selection"];
    menu.autoenablesItems = NO;

    NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:@"Dia Chat Models" action:nil keyEquivalent:@""];
    header.enabled = NO;
    [menu addItem:header];

    NSArray *models = @[
        @{@"id": @"claude-opus-4-6", @"name": @"Claude Opus 4.6 (Default)"},
        @{@"id": @"claude-opus-4-8", @"name": @"Claude Opus 4.8"},
        @{@"id": @"claude-opus-5-5", @"name": @"Claude Opus 5.5"},
        @{@"id": @"claude-sonnet-5-5", @"name": @"Claude Sonnet 5.5"},
        @{@"id": @"claude-haiku-5-5", @"name": @"Claude Haiku 5.5"},
    ];

    for (NSDictionary *m in models) {
        NSString *mId = m[@"id"];
        NSString *mName = m[@"name"];
        BOOL isCurrentModel = [mId isEqualToString:currentActive];

        NSString *itemTitle = mName;
        if (isCurrentModel && currentLevel.length && ![currentLevel isEqualToString:@"adaptive"] && ![currentLevel isEqualToString:@"off"]) {
            itemTitle = [NSString stringWithFormat:@"%@ (%@)", mName, [currentLevel capitalizedString]];
        }

        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:itemTitle action:@selector(selectChatModel:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = m;
        if (isCurrentModel) {
            item.state = NSControlStateValueOn;
        }

        // Submenu for Thinking Levels
        NSDictionary *thinkingCap = DPGetModelThinkingCapabilities(mId);
        if ([thinkingCap[@"supported"] boolValue]) {
            NSArray *levels = thinkingCap[@"levels"];
            if (levels.count) {
                NSMenu *sub = [[NSMenu alloc] initWithTitle:@"Thinking Level"];
                for (NSDictionary *lvl in levels) {
                    NSMenuItem *subItem = [[NSMenuItem alloc] initWithTitle:lvl[@"label"] action:@selector(selectChatModelWithLevel:) keyEquivalent:@""];
                    subItem.target = self;
                    subItem.representedObject = @{@"model": m, @"level": lvl};
                    if (isCurrentModel) {
                        NSString *activeLvl = currentLevel ?: @"adaptive";
                        if ([lvl[@"id"] isEqualToString:activeLvl]) {
                            subItem.state = NSControlStateValueOn;
                        }
                    }
                    [sub addItem:subItem];
                }
                item.submenu = sub;
            }
        }

        [menu addItem:item];
    }

    NSPoint menuOrigin = NSMakePoint(0, self.bounds.size.height + 3);
    [menu popUpMenuPositioningItem:nil atLocation:menuOrigin inView:self];
}

- (void)selectChatModel:(NSMenuItem *)sender {
    NSDictionary *m = sender.representedObject;
    NSMutableDictionary *cfg = DPLoadChatModelConfig();
    cfg[@"activeModel"] = m[@"id"];
    cfg[@"activeThinkingLevel"] = @"adaptive";
    DPSaveChatModelConfig(cfg);
    DPUpdateAllPickerButtons();
}

- (void)selectChatModelWithLevel:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    NSDictionary *m = info[@"model"];
    NSDictionary *lvl = info[@"level"];

    NSMutableDictionary *cfg = DPLoadChatModelConfig();
    cfg[@"activeModel"] = m[@"id"];
    cfg[@"activeThinkingLevel"] = lvl[@"id"] ?: @"adaptive";
    DPSaveChatModelConfig(cfg);
    DPUpdateAllPickerButtons();
}

@end
