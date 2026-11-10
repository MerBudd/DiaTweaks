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

+ (instancetype)sharedController;
- (void)providerChanged:(NSPopUpButton *)sender;
- (void)pasteApiKey:(id)sender;
- (void)submitApiKey:(id)sender;
- (void)defaultModelPickerChanged:(NSPopUpButton *)sender;
- (void)saveAndFetchWithKey:(NSString *)key;
- (void)refreshDefaultModelPicker;
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
    DPBYOKNotifyStateChanged();
}

- (void)pasteApiKey:(id)sender {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *pasted = [pb stringForType:NSPasteboardTypeString];
    if (pasted.length > 0) {
        NSString *trimmed = [pasted stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        self.apiKeyField.stringValue = trimmed;
        [self saveAndFetchWithKey:trimmed];
    }
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

- (void)saveAndFetchWithKey:(NSString *)key {
    NSString *provider = DPBYOKProvider() ?: @"gemini";
    DPBYOKSetApiKey(provider, key);

    if (key.length == 0) {
        self.statusLabel.stringValue = @"";
        DPBYOKSetFetchedModels(provider, @[]);
        [self refreshDefaultModelPicker];
        DPBYOKNotifyStateChanged();
        return;
    }

    self.statusLabel.stringValue = @"Fetching models…";
    self.statusLabel.textColor = NSColor.secondaryLabelColor;

    DPBYOKFetchModels(provider, key, ^(NSArray<NSDictionary *> *models, NSError *error) {
        if (error) {
            self.statusLabel.stringValue = @"Error fetching models";
            self.statusLabel.textColor = NSColor.systemRedColor;

            NSAlert *alert = [NSAlert new];
            alert.alertStyle = NSAlertStyleWarning;
            NSString *title = DPBYOKProviderTitle(provider) ?: provider;
            alert.messageText = [NSString stringWithFormat:@"%@ API Error", title];
            alert.informativeText = error.localizedDescription ?: @"Unknown error occurred.";
            [alert runModal];
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
        DPBYOKNotifyStateChanged();
    });
}

- (void)refreshDefaultModelPicker {
    NSString *provider = DPBYOKProvider() ?: @"gemini";
    NSMenu *menu = DPBYOKBuildModelMenu(NO, YES);
    self.defaultModelPicker.menu = menu;

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
    NSView *row1 = DPBYOKSettingsRow(providerLabel, providerPicker);

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
    [defaultModelPicker.widthAnchor constraintGreaterThanOrEqualToConstant:200].active = YES;
    controller.defaultModelPicker = defaultModelPicker;

    NSView *row3 = DPBYOKSettingsRow(defaultModelLabel, defaultModelPicker);

    // Initial sync
    [controller syncControls];

    return @[ row1, row2, row3 ];
}
