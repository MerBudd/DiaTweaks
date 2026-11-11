#import "Patches/BYOK/BYOK.h"

NSString *const DPBYOKDiaDefaultModel = @"__dia_default__";
NSNotificationName const DPBYOKStateDidChangeNotification = @"DPBYOKStateDidChange";

__attribute__((weak)) extern DPPatch DPBYOK;
__attribute__((weak)) extern DPPatch DPBYOKBriefs;
__attribute__((weak)) extern DPPatch DPBYOKBriefsModel;
__attribute__((weak)) void DPUpdateAllBYOKPickers(void);

static NSUserDefaults *DPBYOKDefaults(void) {
    static NSUserDefaults *defaults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.diapatches"];
    });
    return defaults;
}

#pragma mark - Providers

NSArray<NSDictionary<NSString *, NSString *> *> *DPBYOKProviders(void) {
    return @[
        @{ @"id": @"gemini",     @"title": @"Google Gemini" },
        @{ @"id": @"openai",     @"title": @"OpenAI" },
        @{ @"id": @"anthropic",  @"title": @"Anthropic" },
        @{ @"id": @"openrouter", @"title": @"OpenRouter" }
    ];
}

NSString *DPBYOKProviderTitle(NSString *provider) {
    if (!provider || provider.length == 0) return @"";
    for (NSDictionary<NSString *, NSString *> *item in DPBYOKProviders()) {
        if ([item[@"id"] isEqualToString:provider]) {
            return item[@"title"];
        }
    }
    return provider.capitalizedString;
}

NSString *DPBYOKProvider(void) {
    NSString *p = [DPBYOKDefaults() stringForKey:@"byokProvider"];
    return (p && p.length > 0) ? p : @"gemini";
}

void DPBYOKSetProvider(NSString *provider) {
    if (!provider || provider.length == 0) provider = @"gemini";
    NSString *current = DPBYOKProvider();
    BOOL changed = ![current isEqualToString:provider];
    [DPBYOKDefaults() setObject:provider forKey:@"byokProvider"];

    if (changed) {
        NSString *active = DPBYOKActiveModel();
        if (![active isEqualToString:DPBYOKDiaDefaultModel]) {
            NSString *newDefault = DPBYOKDefaultModel(provider);
            if (newDefault.length > 0) {
                [DPBYOKDefaults() setObject:newDefault forKey:@"byokActiveModel"];
            }
        }
    }
    DPBYOKNotifyStateChanged();
}

#pragma mark - API Keys

NSString *DPBYOKApiKey(NSString *provider) {
    return DPBYOKLoadKey(provider);
}

void DPBYOKSetApiKey(NSString *provider, NSString *key) {
    DPBYOKSaveKey(provider, key);
    DPBYOKNotifyStateChanged();
}

#pragma mark - Fetched Models

NSArray<NSDictionary *> *DPBYOKFetchedModels(NSString *provider) {
    if (!provider || provider.length == 0) return @[];
    NSString *key = [NSString stringWithFormat:@"byokModels_%@", provider];
    NSArray *models = [DPBYOKDefaults() arrayForKey:key];
    return [models isKindOfClass:[NSArray class]] ? models : @[];
}

void DPBYOKSetFetchedModels(NSString *provider, NSArray<NSDictionary *> *models) {
    if (!provider || provider.length == 0) return;
    NSString *key = [NSString stringWithFormat:@"byokModels_%@", provider];
    if (models) {
        [DPBYOKDefaults() setObject:models forKey:key];
    } else {
        [DPBYOKDefaults() removeObjectForKey:key];
    }
    DPBYOKNotifyStateChanged();
}

#pragma mark - Default Model

NSString *DPBYOKDefaultModel(NSString *provider) {
    if (!provider || provider.length == 0) return nil;
    NSString *key = [NSString stringWithFormat:@"byokDefaultModel_%@", provider];
    NSString *saved = [DPBYOKDefaults() stringForKey:key];
    if (saved && saved.length > 0) {
        return saved;
    }
    NSArray<NSDictionary *> *models = DPBYOKFetchedModels(provider);
    if (models.count > 0) {
        NSDictionary *first = models.firstObject;
        if ([first isKindOfClass:[NSDictionary class]]) {
            NSString *modelId = first[@"id"];
            if ([modelId isKindOfClass:[NSString class]] && modelId.length > 0) {
                return modelId;
            }
        }
    }
    return nil;
}

void DPBYOKSetDefaultModel(NSString *provider, NSString *modelId) {
    if (!provider || provider.length == 0) return;
    NSString *key = [NSString stringWithFormat:@"byokDefaultModel_%@", provider];
    if (modelId && modelId.length > 0) {
        [DPBYOKDefaults() setObject:modelId forKey:key];
    } else {
        [DPBYOKDefaults() removeObjectForKey:key];
    }
    DPBYOKSetActiveModel(modelId);
}

#pragma mark - Briefs Model

NSString *DPBYOKGetBriefsModel(NSString *provider) {
    if (!provider || provider.length == 0) provider = DPBYOKProvider() ?: @"gemini";
    NSString *key = [NSString stringWithFormat:@"byokBriefsModel_%@", provider];
    NSString *saved = [DPBYOKDefaults() stringForKey:key];
    if (saved && saved.length > 0) {
        return saved;
    }
    return DPBYOKDefaultModel(provider);
}

void DPBYOKSetBriefsModel(NSString *provider, NSString *modelId) {
    if (!provider || provider.length == 0) provider = DPBYOKProvider() ?: @"gemini";
    NSString *key = [NSString stringWithFormat:@"byokBriefsModel_%@", provider];
    if (modelId && modelId.length > 0) {
        [DPBYOKDefaults() setObject:modelId forKey:key];
    } else {
        [DPBYOKDefaults() removeObjectForKey:key];
    }
    DPBYOKNotifyStateChanged();
}

#pragma mark - Active Model

NSString *DPBYOKActiveModel(void) {
    NSString *saved = [DPBYOKDefaults() stringForKey:@"byokActiveModel"];
    if (saved && [saved isEqualToString:DPBYOKDiaDefaultModel]) {
        return DPBYOKDiaDefaultModel;
    }
    NSString *provider = DPBYOKProvider();
    NSArray<NSDictionary *> *models = DPBYOKFetchedModels(provider);

    if (saved && saved.length > 0) {
        if (models.count > 0) {
            BOOL found = NO;
            for (NSDictionary *m in models) {
                if ([m isKindOfClass:[NSDictionary class]] && [m[@"id"] isEqualToString:saved]) {
                    found = YES;
                    break;
                }
            }
            if (found) {
                return saved;
            }
        } else {
            return saved;
        }
    }

    NSString *def = DPBYOKDefaultModel(provider);
    if (def && def.length > 0) {
        return def;
    }
    return DPBYOKDiaDefaultModel;
}

void DPBYOKSetActiveModel(NSString *modelId) {
    if (modelId && modelId.length > 0) {
        [DPBYOKDefaults() setObject:modelId forKey:@"byokActiveModel"];
    } else {
        [DPBYOKDefaults() removeObjectForKey:@"byokActiveModel"];
    }
    DPBYOKNotifyStateChanged();
}

#pragma mark - Thinking Level

NSString *DPBYOKThinkingLevel(NSString *provider, NSString *modelId) {
    if (!provider || provider.length == 0 || !modelId || modelId.length == 0) {
        return @"medium";
    }
    NSString *key = [NSString stringWithFormat:@"byokThinking_%@_%@", provider, modelId];
    NSString *saved = [DPBYOKDefaults() stringForKey:key];
    if (saved && saved.length > 0) {
        return saved;
    }
    NSArray<NSString *> *levels = DPBYOKThinkingLevelsForModel(provider, modelId);
    if (levels.count > 0) {
        if ([levels containsObject:@"medium"]) {
            return @"medium";
        }
        if ([levels containsObject:@"adaptive"]) {
            return @"adaptive";
        }
        return levels.firstObject;
    }
    return @"medium";
}

void DPBYOKSetThinkingLevel(NSString *provider, NSString *modelId, NSString *level) {
    if (!provider || provider.length == 0 || !modelId || modelId.length == 0) return;
    NSString *key = [NSString stringWithFormat:@"byokThinking_%@_%@", provider, modelId];
    if (level && level.length > 0) {
        [DPBYOKDefaults() setObject:level forKey:key];
    } else {
        [DPBYOKDefaults() removeObjectForKey:key];
    }
    DPBYOKNotifyStateChanged();
}

#pragma mark - Model Info & Metadata

NSDictionary *DPBYOKModelInfo(NSString *provider, NSString *modelId) {
    if (!provider || !modelId) return nil;
    NSArray<NSDictionary *> *models = DPBYOKFetchedModels(provider);
    for (NSDictionary *m in models) {
        if ([m isKindOfClass:[NSDictionary class]] && [m[@"id"] isEqualToString:modelId]) {
            return m;
        }
    }
    return nil;
}

NSString *DPBYOKDisplayNameForModel(NSString *provider, NSString *modelId) {
    if (!modelId || [modelId isEqualToString:DPBYOKDiaDefaultModel]) {
        return @"Dia Default";
    }
    NSDictionary *info = DPBYOKModelInfo(provider, modelId);
    if (info) {
        NSString *name = info[@"name"];
        if ([name isKindOfClass:[NSString class]] && name.length > 0) {
            return name;
        }
    }
    return modelId;
}

NSArray<NSString *> *DPBYOKThinkingLevelsForModel(NSString *provider, NSString *modelId) {
    NSDictionary *info = DPBYOKModelInfo(provider, modelId);
    if (info && [info[@"thinking"] boolValue]) {
        NSArray *levels = info[@"thinkingLevels"];
        if ([levels isKindOfClass:[NSArray class]]) {
            return levels;
        }
    }
    return @[];
}

NSString *DPBYOKThinkingLabel(NSString *level) {
    if (!level || level.length == 0) return @"";
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"minimal":  @"Minimal",
            @"low":      @"Low",
            @"medium":   @"Medium",
            @"high":     @"High",
            @"xhigh":    @"Extra High",
            @"max":      @"Max",
            @"adaptive": @"Adaptive",
            @"off":      @"Off"
        };
    });
    NSString *label = map[level.lowercaseString];
    return label ?: level.capitalizedString;
}

#pragma mark - Routing & Notifications

BOOL DPBYOKShouldRoute(NSString *agentSpec) {
    BOOL byokOn = (&DPBYOK != NULL) ? DPBYOK.on : NO;
    if (!byokOn || DPTurnOffAI.on) {
        return NO;
    }
    NSString *spec = agentSpec ?: @"default";
    if (![spec isEqualToString:@"default"]) {
        BOOL briefsOn = (&DPBYOKBriefs != NULL) ? DPBYOKBriefs.on : NO;
        if (!briefsOn) {
            return NO;
        }
        NSString *provider = DPBYOKProvider();
        NSString *key = DPBYOKApiKey(provider);
        if (!key || key.length == 0) {
            return NO;
        }
        return YES;
    }
    NSString *activeModel = DPBYOKActiveModel();
    if (!activeModel || activeModel.length == 0 || [activeModel isEqualToString:DPBYOKDiaDefaultModel]) {
        return NO;
    }
    NSString *provider = DPBYOKProvider();
    NSString *key = DPBYOKApiKey(provider);
    if (!key || key.length == 0) {
        return NO;
    }
    return YES;
}

void DPBYOKNotifyStateChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DPBYOKStateDidChangeNotification object:nil];
        if (DPUpdateAllBYOKPickers) {
            DPUpdateAllBYOKPickers();
        }
    });
}
