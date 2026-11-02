#import "BYOKControls.h"
#import "Settings.h"
#import "Patches/BYOK/BYOK.h"

static NSString *DPAppSupportPath(NSString *subpath) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"DiaPatches"];
    return subpath ? [dir stringByAppendingPathComponent:subpath] : dir;
}

static NSUserDefaults *DPBYOKDefaults(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:@"com.diapatches"];
}

static NSString *DPFindNodeBinary(void) {
    for (NSString *candidate in @[@"/opt/homebrew/bin/node", @"/usr/local/bin/node", @"/usr/bin/node"]) {
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return @"/usr/bin/env";
}

@interface DPBYOKSettingsController : NSObject <NSTextFieldDelegate>
@property (nonatomic, strong) NSPopUpButton *providerPopup;
@property (nonatomic, strong) NSSecureTextField *keyField;
@property (nonatomic, strong) NSButton *verifyButton;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSPopUpButton *modelPopup;
@end

@implementation DPBYOKSettingsController

- (instancetype)init {
    if (!(self = [super init])) return nil;
    return self;
}

- (void)providerChanged:(NSPopUpButton *)sender {
    NSString *selectedId = sender.selectedItem.representedObject;
    NSUserDefaults *defs = DPBYOKDefaults();
    [defs setObject:selectedId forKey:@"byokProvider"];

    // Update default fallback models based on provider
    [self populateModelsForProvider:selectedId cachedModels:nil];
    DPSyncBYOKConfig();
}

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == self.keyField) {
        NSUserDefaults *defs = DPBYOKDefaults();
        [defs setObject:self.keyField.stringValue forKey:@"byokApiKey"];
        self.statusLabel.stringValue = @"Key changed (click Verify to test)";
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
        DPSyncBYOKConfig();
    }
}

- (void)pasteKey:(NSButton *)sender {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *str = [pb stringForType:NSPasteboardTypeString];
    if (str.length) {
        self.keyField.stringValue = [str stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSUserDefaults *defs = DPBYOKDefaults();
        [defs setObject:self.keyField.stringValue forKey:@"byokApiKey"];
        self.statusLabel.stringValue = @"Key pasted (click Verify to test)";
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
        DPSyncBYOKConfig();
    }
}

- (void)modelChanged:(NSPopUpButton *)sender {
    NSString *model = sender.selectedItem.representedObject ?: sender.selectedItem.title;
    NSUserDefaults *defs = DPBYOKDefaults();
    [defs setObject:model forKey:@"byokModel"];
    DPSyncBYOKConfig();
}

- (void)populateModelsForProvider:(NSString *)provider cachedModels:(NSArray *)cached {
    [self.modelPopup removeAllItems];
    NSUserDefaults *defs = DPBYOKDefaults();
    NSString *currentModel = [defs stringForKey:@"byokModel"];

    NSArray *models = cached;
    if (!models || models.count == 0) {
        if ([provider isEqualToString:@"google"]) {
            models = @[
                @{@"id": @"gemini-3.8-flash", @"name": @"Gemini 3.8 Flash"},
                @{@"id": @"gemini-3.1-pro-preview", @"name": @"Gemini 3.1 Pro Preview"},
                @{@"id": @"gemini-2.5-flash", @"name": @"Gemini 2.5 Flash"},
                @{@"id": @"gemini-2.5-pro", @"name": @"Gemini 2.5 Pro"}
            ];
        } else if ([provider isEqualToString:@"openai"]) {
            models = @[
                @{@"id": @"gpt-6.1-terra", @"name": @"GPT-6.1 Terra"},
                @{@"id": @"gpt-6.1-sol", @"name": @"GPT-6.1 Sol"},
                @{@"id": @"gpt-6", @"name": @"GPT-6"},
                @{@"id": @"gpt-5", @"name": @"GPT-5"},
                @{@"id": @"o3-mini", @"name": @"o3-mini"},
                @{@"id": @"gpt-4o", @"name": @"GPT-4o"}
            ];
        } else if ([provider isEqualToString:@"openrouter"]) {
            models = @[
                @{@"id": @"anthropic/claude-sonnet-5-5", @"name": @"Claude Sonnet 5.5 (OpenRouter)"},
                @{@"id": @"openai/gpt-6.1-terra", @"name": @"GPT-6.1 Terra (OpenRouter)"},
                @{@"id": @"google/gemini-3.8-flash", @"name": @"Gemini 3.8 Flash (OpenRouter)"},
                @{@"id": @"deepseek/deepseek-chat", @"name": @"DeepSeek V3 (OpenRouter)"}
            ];
        } else {
            // Anthropic
            models = @[
                @{@"id": @"claude-sonnet-5-5", @"name": @"Claude Sonnet 5.5"},
                @{@"id": @"claude-opus-5-5", @"name": @"Claude Opus 5.5"},
                @{@"id": @"claude-haiku-5-5", @"name": @"Claude Haiku 5.5"},
                @{@"id": @"claude-fable-5-1", @"name": @"Claude Fable 5.1"},
                @{@"id": @"claude-3-7-sonnet-20250219", @"name": @"Claude 3.7 Sonnet"}
            ];
        }
    }

    NSInteger selectedIndex = 0;
    for (NSInteger i = 0; i < (NSInteger)models.count; i++) {
        id item = models[i];
        NSString *mId = nil;
        NSString *name = nil;
        if ([item isKindOfClass:[NSDictionary class]]) {
            mId = item[@"id"];
            name = item[@"name"] ?: mId;
        } else if ([item isKindOfClass:[NSString class]]) {
            mId = (NSString *)item;
            name = mId;
        }
        if (!mId.length) continue;

        NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:name action:nil keyEquivalent:@""];
        menuItem.representedObject = mId;
        [self.modelPopup.menu addItem:menuItem];
        if (currentModel && [currentModel isEqualToString:mId]) {
            selectedIndex = self.modelPopup.numberOfItems - 1;
        }
    }

    [self.modelPopup selectItemAtIndex:selectedIndex];
    if (!currentModel || currentModel.length == 0) {
        NSString *firstId = models.firstObject[@"id"];
        if (firstId) {
            [defs setObject:firstId forKey:@"byokModel"];
            DPSyncBYOKConfig();
        }
    }
}

- (void)verifyKey:(NSButton *)sender {
    NSString *provider = self.providerPopup.selectedItem.representedObject ?: @"anthropic";
    NSString *apiKey = self.keyField.stringValue;

    if (!apiKey.length) {
        self.statusLabel.stringValue = @"Please enter an API key first";
        self.statusLabel.textColor = NSColor.systemRedColor;
        return;
    }

    self.statusLabel.stringValue = @"Checking key with provider...";
    self.statusLabel.textColor = NSColor.systemOrangeColor;
    self.verifyButton.enabled = NO;

    NSString *verifyScript = DPAppSupportPath(@"byok/verify.js");
    if (![NSFileManager.defaultManager fileExistsAtPath:verifyScript]) {
        // Fallback to local repo/bundle path
        verifyScript = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Resources/agent-server-resources/dist/verify.js"];
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        NSString *node = DPFindNodeBinary();
        if ([node isEqualToString:@"/usr/bin/env"]) {
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
            task.arguments = @[@"node", verifyScript, provider, apiKey];
        } else {
            task.executableURL = [NSURL fileURLWithPath:node];
            task.arguments = @[verifyScript, provider, apiKey];
        }

        NSPipe *outPipe = [NSPipe pipe];
        NSPipe *errPipe = [NSPipe pipe];
        task.standardOutput = outPipe;
        task.standardError = errPipe;

        NSError *launchError = nil;
        if (![task launchAndReturnError:&launchError]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.verifyButton.enabled = YES;
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Failed to run verification: %@", launchError.localizedDescription];
                self.statusLabel.textColor = NSColor.systemRedColor;
            });
            return;
        }

        NSData *outData = [outPipe.fileHandleForReading readDataToEndOfFile];
        NSData *errData = [errPipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.verifyButton.enabled = YES;
            NSError *jsonErr = nil;
            NSDictionary *resp = nil;
            if (outData.length) {
                resp = [NSJSONSerialization JSONObjectWithData:outData options:0 error:&jsonErr];
                if (!resp) {
                    NSString *outString = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
                    NSString *trimmed = [outString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (trimmed.length) {
                        NSData *trimmedData = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
                        resp = [NSJSONSerialization JSONObjectWithData:trimmedData options:0 error:nil];
                    }
                }
            }

            if (resp && [resp[@"valid"] boolValue]) {
                NSArray *models = resp[@"models"] ?: @[];
                self.statusLabel.stringValue = [NSString stringWithFormat:@"✓ Key valid — %lu models available", (unsigned long)models.count];
                self.statusLabel.textColor = NSColor.systemGreenColor;

                // Save cached models and populate dropdown
                NSUserDefaults *defs = DPBYOKDefaults();
                [defs setObject:models forKey:[NSString stringWithFormat:@"byok_models_%@", provider]];
                [self populateModelsForProvider:provider cachedModels:models];
                DPSyncBYOKConfig();
            } else {
                NSString *errStr = resp[@"error"];
                if (!errStr.length && errData.length) {
                    errStr = [[[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                }
                if (!errStr.length && jsonErr) {
                    errStr = [NSString stringWithFormat:@"Failed to parse response: %@", jsonErr.localizedDescription];
                }
                if (!errStr.length) {
                    errStr = @"Verification failed (unknown error)";
                } else if (errStr.length > 150) {
                    errStr = [[errStr substringToIndex:150] stringByAppendingString:@"…"];
                }
                self.statusLabel.stringValue = [NSString stringWithFormat:@"✕ %@", errStr];
                self.statusLabel.textColor = NSColor.systemRedColor;
            }
        });
    });
}

@end

static char DPBYOKControllerKey;

NSView *DPCreateBYOKSettingsGroup(void) {
    DPBYOKSettingsController *ctrl = [DPBYOKSettingsController new];
    NSUserDefaults *defs = DPBYOKDefaults();
    NSString *currentProvider = [defs stringForKey:@"byokProvider"] ?: @"anthropic";
    NSString *currentKey = [defs stringForKey:@"byokApiKey"] ?: @"";

    // 1. Provider row
    NSPopUpButton *providerPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 180, 24) pullsDown:NO];
    providerPopup.lineBreakMode = NSLineBreakByTruncatingTail;
    [providerPopup.widthAnchor constraintLessThanOrEqualToConstant:200].active = YES;
    NSArray *providers = @[
        @{@"id": @"anthropic", @"title": @"Anthropic (Claude)"},
        @{@"id": @"google", @"title": @"Google (Gemini)"},
        @{@"id": @"openai", @"title": @"OpenAI (ChatGPT)"},
        @{@"id": @"openrouter", @"title": @"OpenRouter (Multi-model)"},
    ];

    NSInteger selectedProviderIdx = 0;
    for (NSInteger i = 0; i < (NSInteger)providers.count; i++) {
        NSDictionary *p = providers[i];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:p[@"title"] action:nil keyEquivalent:@""];
        item.representedObject = p[@"id"];
        [providerPopup.menu addItem:item];
        if ([currentProvider isEqualToString:p[@"id"]]) {
            selectedProviderIdx = i;
        }
    }
    [providerPopup selectItemAtIndex:selectedProviderIdx];
    providerPopup.target = ctrl;
    providerPopup.action = @selector(providerChanged:);
    ctrl.providerPopup = providerPopup;

    NSView *providerLeading = DPColumn(@[
        DPLabel(@"AI Provider", 13, NSFontWeightRegular, NSColor.labelColor),
        DPLabel(@"Service that powers Chat and Briefs", 11, NSFontWeightRegular, NSColor.secondaryLabelColor)
    ], 2);
    NSView *providerRow = DPRow(providerLeading, providerPopup);

    // 2. API Key row
    NSSecureTextField *keyField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 180, 22)];
    keyField.placeholderString = @"Paste your API key...";
    keyField.stringValue = currentKey;
    keyField.delegate = ctrl;
    [keyField.widthAnchor constraintEqualToConstant:180].active = YES;
    ctrl.keyField = keyField;

    NSButton *pasteBtn = [NSButton buttonWithTitle:@"Paste" target:ctrl action:@selector(pasteKey:)];
    pasteBtn.bezelStyle = NSBezelStyleRounded;
    pasteBtn.controlSize = NSControlSizeSmall;

    NSStackView *keyTrailing = [NSStackView stackViewWithViews:@[keyField, pasteBtn]];
    keyTrailing.spacing = 6;

    NSView *keyLeading = DPColumn(@[
        DPLabel(@"API Key", 13, NSFontWeightRegular, NSColor.labelColor),
        DPLabel(@"Kept locally in Dia's preferences", 11, NSFontWeightRegular, NSColor.secondaryLabelColor)
    ], 2);
    NSView *keyRow = DPRow(keyLeading, keyTrailing);

    // 3. Verify & status row
    NSTextField *statusLabel = DPLabel(currentKey.length ? @"Click Verify to check key & load models" : @"Enter an API key above", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    ctrl.statusLabel = statusLabel;

    NSButton *verifyBtn = [NSButton buttonWithTitle:@"Verify & Fetch Models" target:ctrl action:@selector(verifyKey:)];
    verifyBtn.bezelStyle = NSBezelStyleRounded;
    ctrl.verifyButton = verifyBtn;

    NSView *verifyRow = DPRow(statusLabel, verifyBtn);

    // 4. Default Model row
    NSPopUpButton *modelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 200, 24) pullsDown:NO];
    modelPopup.lineBreakMode = NSLineBreakByTruncatingTail;
    [modelPopup.widthAnchor constraintLessThanOrEqualToConstant:220].active = YES;
    modelPopup.target = ctrl;
    modelPopup.action = @selector(modelChanged:);
    ctrl.modelPopup = modelPopup;

    NSArray *cached = [defs arrayForKey:[NSString stringWithFormat:@"byok_models_%@", currentProvider]];
    [ctrl populateModelsForProvider:currentProvider cachedModels:cached];

    NSView *modelLeading = DPColumn(@[
        DPLabel(@"Default Model", 13, NSFontWeightRegular, NSColor.labelColor),
        DPLabel(@"Model for queries, tools and MCP requests", 11, NSFontWeightRegular, NSColor.secondaryLabelColor)
    ], 2);
    NSView *modelRow = DPRow(modelLeading, modelPopup);

    NSView *group = DPGroup(@[providerRow, keyRow, verifyRow, modelRow]);
    DPSet(group, &DPBYOKControllerKey, ctrl);
    return group;
}
