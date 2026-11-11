#import "Patches/BYOK/BYOK.h"

@interface DPBYOKModelPopUpButton : NSPopUpButton
@property (nonatomic, assign) BOOL hasModels;
@end

@implementation DPBYOKModelPopUpButton
- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled && self.hasModels && DPBYOK.on];
}
@end

@interface DPBYOKSettingsController : NSObject <NSTextFieldDelegate>
@property (nonatomic, strong) NSPopUpButton *providerPicker;
@property (nonatomic, strong) NSSecureTextField *apiKeyField;
@property (nonatomic, strong) NSButton *pasteButton;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) DPBYOKModelPopUpButton *defaultModelPicker;
@property (nonatomic, strong) NSButton *fetchButton;
@property (nonatomic, strong) DPBYOKModelPopUpButton *briefsModelPicker;

+ (instancetype)sharedController;
- (void)providerChanged:(NSPopUpButton *)sender;
- (void)pasteApiKey:(id)sender;
- (void)submitApiKey:(id)sender;
- (void)fetchModelsManual:(id)sender;
- (void)defaultModelPickerChanged:(NSPopUpButton *)sender;
- (void)briefsModelPickerChanged:(NSPopUpButton *)sender;
- (void)saveAndFetchWithKey:(NSString *)key;
- (void)refreshDefaultModelPicker;
- (void)refreshBriefsModelPicker;
- (void)syncControls;
@end

@implementation DPBYOKSettingsController

+ (instancetype)sharedController {
    static DPBYOKSettingsController *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [DPBYOKSettingsController new];
    });
    return shared;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleStateChanged:)
                                                 name:DPBYOKStateDidChangeNotification
                                               object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleStateChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self syncControls];
    });
}

- (void)syncControls {
    NSString *provider = DPBYOKProvider() ?: @"gemini";

    for (NSMenuItem *item in self.providerPicker.itemArray) {
        if ([item.representedObject isEqual:provider]) {
            [self.providerPicker selectItem:item];
            break;
        }
    }

    NSString *apiKey = DPBYOKApiKey(provider) ?: @"";
    self.apiKeyField.stringValue = apiKey;

    NSArray<NSDictionary *> *models = DPBYOKFetchedModels(provider) ?: @[];
    if (models.count > 0) {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu models available", (unsigned long)models.count];
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
    } else if (apiKey.length > 0) {
        self.statusLabel.stringValue = @"No models fetched yet";
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
    } else {
        self.statusLabel.stringValue = @"";
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
    }

    [self refreshDefaultModelPicker];
    [self refreshBriefsModelPicker];
}

- (void)providerChanged:(NSPopUpButton *)sender {
    NSString *selectedProvider = sender.selectedItem.representedObject;
    if (!selectedProvider) return;

    DPBYOKSetProvider(selectedProvider);

    NSString *apiKey = DPBYOKApiKey(selectedProvider) ?: @"";
    self.apiKeyField.stringValue = apiKey;

    NSArray<NSDictionary *> *models = DPBYOKFetchedModels(selectedProvider) ?: @[];
    if (models.count > 0) {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu models available", (unsigned long)models.count];
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
    } else if (apiKey.length > 0) {
        self.statusLabel.stringValue = @"No models fetched yet";
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
    } else {
        self.statusLabel.stringValue = @"";
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
    }

    [self refreshDefaultModelPicker];
    [self refreshBriefsModelPicker];
    DPBYOKNotifyStateChanged();
}

- (void)pasteApiKey:(id)sender {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *pasted = [pb stringForType:NSPasteboardTypeString];
    if (pasted.length > 0) {
        NSString *trimmed = [pasted stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        self.apiKeyField.stringValue = trimmed;
        [self saveAndFetchWithKey:trimmed];

        if (self.apiKeyField.window) {
            [self.apiKeyField.window makeFirstResponder:self.apiKeyField];
            NSText *editor = [self.apiKeyField currentEditor];
            if (editor) {
                NSRange endRange = NSMakeRange(trimmed.length, 0);
                [editor setSelectedRange:endRange];
                [editor scrollRangeToVisible:endRange];
            }
        }
    }
}

- (void)fetchModelsManual:(id)sender {
    NSString *provider = DPBYOKProvider() ?: @"gemini";
    NSString *apiKey = DPBYOKApiKey(provider) ?: @"";
    [self saveAndFetchWithKey:apiKey];
}

- (void)submitApiKey:(id)sender {
    NSString *key = [self.apiKeyField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self saveAndFetchWithKey:key];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (control == self.apiKeyField && commandSelector == @selector(insertNewline:)) {
        NSString *key = [textView.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        self.apiKeyField.stringValue = key;
        [self saveAndFetchWithKey:key];
        return YES;
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    if (obj.object == self.apiKeyField) {
        NSString *provider = DPBYOKProvider() ?: @"gemini";
        NSString *current = [self.apiKeyField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        DPBYOKSetApiKey(provider, current);
        if (current.length == 0) {
            self.statusLabel.stringValue = @"";
            DPBYOKSetFetchedModels(provider, @[]);
            [self refreshDefaultModelPicker];
            [self refreshBriefsModelPicker];
            DPBYOKNotifyStateChanged();
        }
    }
}

- (void)defaultModelPickerChanged:(NSPopUpButton *)sender {
    NSMenuItem *item = sender.selectedItem;
    if (item && [item.representedObject isKindOfClass:NSString.class]) {
        NSString *provider = DPBYOKProvider() ?: @"gemini";
        DPBYOKSetDefaultModel(provider, item.representedObject);
        DPBYOKNotifyStateChanged();
    }
}

- (void)briefsModelPickerChanged:(NSPopUpButton *)sender {
    NSMenuItem *item = sender.selectedItem;
    if (item && [item.representedObject isKindOfClass:NSString.class]) {
        NSString *provider = DPBYOKProvider() ?: @"gemini";
        DPBYOKSetBriefsModel(provider, item.representedObject);
        DPBYOKNotifyStateChanged();
    }
}

- (void)saveAndFetchWithKey:(NSString *)key {
    NSString *provider = DPBYOKProvider() ?: @"gemini";
    DPBYOKSetApiKey(provider, key);

    if (key.length == 0) {
        self.statusLabel.stringValue = @"";
        DPBYOKSetFetchedModels(provider, @[]);
        [self refreshDefaultModelPicker];
        [self refreshBriefsModelPicker];
        DPBYOKNotifyStateChanged();
        return;
    }

    self.statusLabel.stringValue = @"Fetching models…";
    self.statusLabel.textColor = NSColor.secondaryLabelColor;

    DPBYOKFetchModels(provider, key, ^(NSArray<NSDictionary *> *models, NSError *error) {
        if (error) {
            self.statusLabel.stringValue = @"Error fetching models";
            self.statusLabel.textColor = NSColor.systemRedColor;
            DPBYOKSetFetchedModels(provider, @[]);
            [self refreshDefaultModelPicker];
            [self refreshBriefsModelPicker];
            DPBYOKNotifyStateChanged();

            NSAlert *alert = [NSAlert new];
            alert.alertStyle = NSAlertStyleWarning;
            NSString *title = DPBYOKProviderTitle(provider) ?: provider;
            alert.messageText = [NSString stringWithFormat:@"%@ API Error", title];
            alert.informativeText = error.localizedDescription ?: @"Unknown error occurred.";
            if (!DPTesting) [alert runModal];
            return;
        }

        self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu models available", (unsigned long)models.count];
        self.statusLabel.textColor = NSColor.secondaryLabelColor;

        DPBYOKSetFetchedModels(provider, models);

        NSString *currentDefault = DPBYOKDefaultModel(provider);
        BOOL found = NO;
        for (NSDictionary *m in models) {
            if ([m[@"id"] isEqualToString:currentDefault]) {
                found = YES;
                break;
            }
        }
        if (!found && models.count > 0) {
            DPBYOKSetDefaultModel(provider, models.firstObject[@"id"]);
        }

        [self refreshDefaultModelPicker];
        [self refreshBriefsModelPicker];
        DPBYOKNotifyStateChanged();
    });
}

- (void)refreshDefaultModelPicker {
    NSString *provider = DPBYOKProvider() ?: @"gemini";
    BOOL multiProvider = DPBYOKMultipleProviders.on;
    NSMenu *menu = DPBYOKBuildModelMenu(!multiProvider ? NO : YES, YES);
    self.defaultModelPicker.menu = menu;

    if (multiProvider) {
        BOOL anyKey = NO;
        for (NSDictionary *p in DPBYOKProviders()) {
            NSString *pid = p[@"id"] ?: p[@"key"];
            if (DPBYOKApiKey(pid).length > 0) {
                anyKey = YES;
                break;
            }
        }
        self.defaultModelPicker.hasModels = anyKey;
        if (!anyKey) {
            self.defaultModelPicker.enabled = NO;
            self.defaultModelPicker.title = @"No Configured Providers";
            return;
        }
        self.defaultModelPicker.enabled = DPBYOK.on;

        NSString *defaultModelId = DPBYOKDefaultModel(provider);
        NSString *modelTitle = DPBYOKDisplayNameForModel(provider, defaultModelId);
        NSString *pTitle = DPBYOKProviderTitle(provider);
        if ([defaultModelId isEqualToString:DPBYOKDiaDefaultModel]) {
            self.defaultModelPicker.title = @"Dia Default";
        } else if (pTitle.length > 0 && modelTitle.length > 0) {
            self.defaultModelPicker.title = [NSString stringWithFormat:@"%@: %@", pTitle, modelTitle];
        } else {
            self.defaultModelPicker.title = modelTitle ?: @"Default Model";
        }
    } else {
        NSArray<NSDictionary *> *models = DPBYOKFetchedModels(provider) ?: @[];
        self.defaultModelPicker.hasModels = (models.count > 0);
        if (models.count == 0) {
            self.defaultModelPicker.enabled = NO;
            self.defaultModelPicker.title = @"No Models Available";
            return;
        }
        self.defaultModelPicker.enabled = DPBYOK.on;

        NSString *defaultModelId = DPBYOKDefaultModel(provider);
        NSMenuItem *selectedItem = nil;
        for (NSMenuItem *item in menu.itemArray) {
            if ([item.representedObject isEqual:defaultModelId]) {
                selectedItem = item;
                break;
            }
        }

        if (selectedItem) {
            [self.defaultModelPicker selectItem:selectedItem];
            if (selectedItem.attributedTitle) {
                self.defaultModelPicker.attributedTitle = selectedItem.attributedTitle;
            } else {
                self.defaultModelPicker.title = selectedItem.title;
            }
        } else if (menu.itemArray.count > 0) {
            NSMenuItem *first = menu.itemArray.firstObject;
            [self.defaultModelPicker selectItem:first];
            if (first.attributedTitle) {
                self.defaultModelPicker.attributedTitle = first.attributedTitle;
            } else {
                self.defaultModelPicker.title = first.title;
            }
        }
    }
}

- (void)refreshBriefsModelPicker {
    if (!self.briefsModelPicker) return;
    NSString *provider = DPBYOKProvider() ?: @"gemini";
    BOOL multiProvider = DPBYOKMultipleProviders.on;
    NSMenu *menu = DPBYOKBuildBriefsModelMenu(!multiProvider ? NO : YES);
    self.briefsModelPicker.menu = menu;

    if (multiProvider) {
        BOOL anyKey = NO;
        for (NSDictionary *p in DPBYOKProviders()) {
            NSString *pid = p[@"id"] ?: p[@"key"];
            if (DPBYOKApiKey(pid).length > 0) {
                anyKey = YES;
                break;
            }
        }
        self.briefsModelPicker.hasModels = anyKey;
        if (!anyKey) {
            self.briefsModelPicker.enabled = NO;
            self.briefsModelPicker.title = @"No Configured Providers";
            return;
        }
        self.briefsModelPicker.enabled = DPBYOK.on;

        NSString *briefsModelId = DPBYOKBriefsModel(provider);
        NSString *modelTitle = DPBYOKDisplayNameForModel(provider, briefsModelId);
        NSString *pTitle = DPBYOKProviderTitle(provider);
        if ([briefsModelId isEqualToString:DPBYOKDiaDefaultModel]) {
            self.briefsModelPicker.title = @"Dia Default";
        } else if (pTitle.length > 0 && modelTitle.length > 0) {
            self.briefsModelPicker.title = [NSString stringWithFormat:@"%@: %@", pTitle, modelTitle];
        } else {
            self.briefsModelPicker.title = modelTitle ?: @"Briefs Model";
        }
    } else {
        NSArray<NSDictionary *> *models = DPBYOKFetchedModels(provider) ?: @[];
        self.briefsModelPicker.hasModels = (models.count > 0);
        if (models.count == 0) {
            self.briefsModelPicker.enabled = NO;
            self.briefsModelPicker.title = @"No Models Available";
            return;
        }
        self.briefsModelPicker.enabled = DPBYOK.on;

        NSString *briefsModelId = DPBYOKBriefsModel(provider);
        NSMenuItem *selectedItem = nil;
        for (NSMenuItem *item in menu.itemArray) {
            if ([item.representedObject isEqual:briefsModelId]) {
                selectedItem = item;
                break;
            }
        }

        if (selectedItem) {
            [self.briefsModelPicker selectItem:selectedItem];
            if (selectedItem.attributedTitle) {
                self.briefsModelPicker.attributedTitle = selectedItem.attributedTitle;
            } else {
                self.briefsModelPicker.title = selectedItem.title;
            }
        } else if (menu.itemArray.count > 0) {
            NSMenuItem *first = menu.itemArray.firstObject;
            [self.briefsModelPicker selectItem:first];
            if (first.attributedTitle) {
                self.briefsModelPicker.attributedTitle = first.attributedTitle;
            } else {
                self.briefsModelPicker.title = first.title;
            }
        }
    }
}

@end

static NSView *DPBYOKSettingsRow(NSView *leading, NSView *trailing) {
    NSView *row = [NSView new];
    leading.translatesAutoresizingMaskIntoConstraints = NO;
    trailing.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:leading];
    [row addSubview:trailing];

    [trailing setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [trailing setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

    [NSLayoutConstraint activateConstraints:@[
        [leading.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [leading.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [leading.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor],
        [leading.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor],

        [trailing.leadingAnchor constraintGreaterThanOrEqualToAnchor:leading.trailingAnchor constant:12],
        [trailing.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [trailing.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [trailing.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor],
        [trailing.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor],

        [row.heightAnchor constraintGreaterThanOrEqualToConstant:28],
    ]];
    return row;
}

NSArray<NSView *> *DPBYOKRows(void) {
    DPBYOKSettingsController *controller = [DPBYOKSettingsController sharedController];
    NSString *currentProvider = DPBYOKProvider() ?: @"gemini";

    // Row 1: Provider
    NSTextField *providerLabel = DPLabel(@"Provider", 13, NSFontWeightRegular, NSColor.labelColor);
    NSTextField *providerSubtitle = DPLabel(@"API keys entered for each provider persist across provider switches.", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSStackView *providerLeading = DPColumn(@[ providerLabel, providerSubtitle ], 2);
    NSPopUpButton *providerPicker = [NSPopUpButton new];
    providerPicker.controlSize = NSControlSizeRegular;
    providerPicker.target = controller;
    providerPicker.action = @selector(providerChanged:);

    NSArray<NSDictionary<NSString *, NSString *> *> *providers = DPBYOKProviders();
    if (providers.count > 0) {
        for (NSDictionary *p in providers) {
            NSString *pid = p[@"id"] ?: p[@"key"];
            NSString *name = p[@"name"] ?: p[@"title"] ?: DPBYOKProviderTitle(pid);
            [providerPicker addItemWithTitle:name];
            providerPicker.lastItem.representedObject = pid;
        }
    } else {
        NSArray *fallback = @[
            @[ @"Google Gemini", @"gemini" ],
            @[ @"OpenAI", @"openai" ],
            @[ @"Anthropic", @"anthropic" ],
            @[ @"OpenRouter", @"openrouter" ],
        ];
        for (NSArray *pair in fallback) {
            [providerPicker addItemWithTitle:pair[0]];
            providerPicker.lastItem.representedObject = pair[1];
        }
    }

    for (NSMenuItem *item in providerPicker.itemArray) {
        if ([item.representedObject isEqual:currentProvider]) {
            [providerPicker selectItem:item];
            break;
        }
    }
    controller.providerPicker = providerPicker;
    NSView *row1 = DPBYOKSettingsRow(providerLeading, providerPicker);

    // Row 2: API Key
    NSTextField *keyLabel = DPLabel(@"API Key", 13, NSFontWeightRegular, NSColor.labelColor);
    NSTextField *statusLabel = DPLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    controller.statusLabel = statusLabel;

    NSStackView *leadingStack = DPColumn(@[ keyLabel, statusLabel ], 2);

    NSSecureTextField *apiKeyField = [NSSecureTextField new];
    apiKeyField.placeholderString = @"Enter API key…";
    apiKeyField.font = [NSFont systemFontOfSize:12];
    apiKeyField.target = controller;
    apiKeyField.action = @selector(submitApiKey:);
    apiKeyField.delegate = controller;
    apiKeyField.usesSingleLineMode = YES;
    apiKeyField.cell.scrollable = YES;
    apiKeyField.cell.wraps = NO;
    apiKeyField.cell.lineBreakMode = NSLineBreakByClipping;
    [apiKeyField.widthAnchor constraintEqualToConstant:210].active = YES;
    controller.apiKeyField = apiKeyField;

    NSButton *pasteButton = [NSButton buttonWithTitle:@"Paste" target:controller action:@selector(pasteApiKey:)];
    pasteButton.bezelStyle = NSBezelStyleRounded;
    pasteButton.controlSize = NSControlSizeRegular;
    controller.pasteButton = pasteButton;

    NSStackView *trailingStack = [NSStackView stackViewWithViews:@[ apiKeyField, pasteButton ]];
    trailingStack.spacing = 8;
    trailingStack.alignment = NSLayoutAttributeCenterY;
    NSView *row2 = DPBYOKSettingsRow(leadingStack, trailingStack);

    // Row 3: Default Model
    NSTextField *defaultModelLabel = DPLabel(@"Default Model", 13, NSFontWeightRegular, NSColor.labelColor);
    DPBYOKModelPopUpButton *defaultModelPicker = [DPBYOKModelPopUpButton new];
    defaultModelPicker.controlSize = NSControlSizeRegular;
    defaultModelPicker.target = controller;
    defaultModelPicker.action = @selector(defaultModelPickerChanged:);
    [defaultModelPicker.widthAnchor constraintGreaterThanOrEqualToConstant:180].active = YES;
    controller.defaultModelPicker = defaultModelPicker;

    NSButton *fetchButton = [NSButton buttonWithTitle:@"Fetch models" target:controller action:@selector(fetchModelsManual:)];
    fetchButton.bezelStyle = NSBezelStyleRounded;
    fetchButton.controlSize = NSControlSizeRegular;
    controller.fetchButton = fetchButton;

    NSStackView *trailingModelStack = [NSStackView stackViewWithViews:@[ defaultModelPicker, fetchButton ]];
    trailingModelStack.spacing = 8;
    trailingModelStack.alignment = NSLayoutAttributeCenterY;

    NSView *row3 = DPBYOKSettingsRow(defaultModelLabel, trailingModelStack);

    // Initial sync
    [controller syncControls];

    return @[ row1, row2, row3 ];
}

NSArray<NSView *> *DPBYOKBriefsRows(void) {
    DPBYOKSettingsController *controller = [DPBYOKSettingsController sharedController];
    NSTextField *modelLabel = DPLabel(@"Model", 13, NSFontWeightRegular, NSColor.labelColor);
    DPBYOKModelPopUpButton *briefsModelPicker = [DPBYOKModelPopUpButton new];
    briefsModelPicker.controlSize = NSControlSizeRegular;
    briefsModelPicker.target = controller;
    briefsModelPicker.action = @selector(briefsModelPickerChanged:);
    [briefsModelPicker.widthAnchor constraintGreaterThanOrEqualToConstant:180].active = YES;
    controller.briefsModelPicker = briefsModelPicker;

    [controller refreshBriefsModelPicker];

    NSView *row = DPBYOKSettingsRow(modelLabel, briefsModelPicker);
    return @[ row ];
}
