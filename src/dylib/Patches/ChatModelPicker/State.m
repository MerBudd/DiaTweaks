#import "ChatModelPicker.h"
#import "Settings/Settings.h"

static NSString *DPAppSupportPath(NSString *subpath) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"DiaPatches"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return subpath ? [dir stringByAppendingPathComponent:subpath] : dir;
}

NSString *DPFriendlyModelName(NSString *modelId, NSString *catalogName) {
    if (catalogName.length && ![catalogName isEqualToString:modelId]) {
        return catalogName;
    }
    if (!modelId.length) return @"Model";
    NSString *clean = modelId;

    if ([clean isEqualToString:@"claude-opus-4-6"]) return @"Claude Opus 4.6";
    if ([clean isEqualToString:@"claude-opus-4-8"]) return @"Claude Opus 4.8";
    if ([clean isEqualToString:@"claude-opus-5-5"]) return @"Claude Opus 5.5";
    if ([clean isEqualToString:@"claude-sonnet-5-5"]) return @"Claude Sonnet 5.5";
    if ([clean isEqualToString:@"claude-haiku-5-5"]) return @"Claude Haiku 5.5";

    if ([clean hasPrefix:@"claude-"]) {
        clean = [clean stringByReplacingOccurrencesOfString:@"claude-" withString:@"Claude "];
    }

    // Strip date suffixes like -20250219 or -20241022
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"-\\d{8}$" options:0 error:nil];
    clean = [regex stringByReplacingMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@""];

    return clean;
}

NSDictionary *DPGetModelThinkingCapabilities(NSString *modelId) {
    if (!modelId.length) return @{@"supported": @NO, @"levels": @[]};
    NSString *lowId = modelId.lowercaseString;

    NSMutableArray *levels = [NSMutableArray arrayWithArray:@[
        @{@"id": @"adaptive", @"label": @"Adaptive (Default)"},
        @{@"id": @"low", @"label": @"Low"},
        @{@"id": @"medium", @"label": @"Medium"},
        @{@"id": @"high", @"label": @"High"},
        @{@"id": @"off", @"label": @"Off"},
    ]];

    if ([lowId containsString:@"opus"] || [lowId containsString:@"5-5"] || [lowId containsString:@"4-6"]) {
        [levels insertObject:@{@"id": @"max", @"label": @"Max (64k)"} atIndex:4];
    }

    return @{
        @"supported": @YES,
        @"defaultLevel": @"adaptive",
        @"levels": levels,
    };
}

NSMutableDictionary *DPLoadChatModelConfig(void) {
    NSString *path = DPAppSupportPath(@"chat-model.json");
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) return [parsed mutableCopy];
    }
    return [NSMutableDictionary dictionaryWithDictionary:@{
        @"activeModel": @"claude-opus-4-6",
        @"activeThinkingLevel": @"adaptive",
    }];
}

void DPSaveChatModelConfig(NSDictionary *dict) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToFile:DPAppSupportPath(@"chat-model.json") atomically:YES];
}

static NSHashTable<DPChatModelPickerButton *> *gActivePickerButtons;

void DPRegisterPickerButton(DPChatModelPickerButton *btn) {
    if (!gActivePickerButtons) gActivePickerButtons = [NSHashTable weakObjectsHashTable];
    [gActivePickerButtons addObject:btn];
}

void DPUpdateAllPickerButtons(void) {
    for (DPChatModelPickerButton *btn in gActivePickerButtons.allObjects) {
        [btn reloadFromConfig];
        btn.needsDisplay = YES;
    }
}

void DPRemoveAllPickerButtons(void) {
    for (DPChatModelPickerButton *btn in gActivePickerButtons.allObjects) {
        [btn removeFromSuperview];
    }
    [gActivePickerButtons removeAllObjects];
}

void DPResetToDefaultModel(void) {
    NSString *pref = DPChoice(&DPChatModelPicker) ?: @"claude-opus-4-6";
    NSMutableDictionary *cfg = DPLoadChatModelConfig();
    cfg[@"activeModel"] = pref;
    cfg[@"activeThinkingLevel"] = @"adaptive";
    DPSaveChatModelConfig(cfg);
    DPUpdateAllPickerButtons();
}
