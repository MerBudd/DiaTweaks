#import <objc/runtime.h>
#import "Patches/BYOK/BYOK.h"

static char kDPBYOKMenuConfigKey;

@interface DPBYOKMenuActionConfig : NSObject
@property (nonatomic, copy) NSString *provider;
@property (nonatomic, copy) NSString *modelId;
@property (nonatomic, copy) NSString *thinkingLevel;
@property (nonatomic, assign) BOOL isDefaultPicker;
@property (nonatomic, assign) BOOL isBriefsPicker;
@end

@implementation DPBYOKMenuActionConfig
@end

@interface DPBYOKMenuActionHandler : NSObject
+ (instancetype)sharedInstance;
- (void)selectModel:(NSMenuItem *)sender;
- (void)selectThinkingLevel:(NSMenuItem *)sender;
@end

@implementation DPBYOKMenuActionHandler

+ (instancetype)sharedInstance {
    static DPBYOKMenuActionHandler *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [DPBYOKMenuActionHandler new];
    });
    return instance;
}

- (void)selectModel:(NSMenuItem *)sender {
    DPBYOKMenuActionConfig *cfg = objc_getAssociatedObject(sender, &kDPBYOKMenuConfigKey);
    BOOL isDefault = cfg ? cfg.isDefaultPicker : NO;
    BOOL isBriefs = cfg ? cfg.isBriefsPicker : NO;

    if ([sender.representedObject isEqual:DPBYOKDiaDefaultModel]) {
        if (isBriefs) {
            DPBYOKSetBriefsModel(DPBYOKProvider(), DPBYOKDiaDefaultModel);
        } else if (isDefault) {
            DPBYOKSetDefaultModel(DPBYOKProvider(), DPBYOKDiaDefaultModel);
        } else {
            DPBYOKSetActiveModel(DPBYOKDiaDefaultModel);
        }
        DPBYOKNotifyStateChanged();
        return;
    }

    NSString *modelId = cfg ? cfg.modelId : (NSString *)sender.representedObject;
    NSString *provider = cfg ? cfg.provider : DPBYOKProvider();

    if (provider.length > 0) {
        DPBYOKSetProvider(provider);
    }

    if (isBriefs) {
        DPBYOKSetBriefsModel(provider, modelId);
    } else if (isDefault) {
        DPBYOKSetDefaultModel(provider, modelId);
    } else {
        DPBYOKSetActiveModel(modelId);
    }
    DPBYOKNotifyStateChanged();
}

- (void)selectThinkingLevel:(NSMenuItem *)sender {
    DPBYOKMenuActionConfig *cfg = objc_getAssociatedObject(sender, &kDPBYOKMenuConfigKey);
    if (!cfg) return;

    if (cfg.provider.length > 0) {
        DPBYOKSetProvider(cfg.provider);
    }

    DPBYOKSetThinkingLevel(cfg.provider, cfg.modelId, cfg.thinkingLevel);
    if (cfg.isBriefsPicker) {
        DPBYOKSetBriefsModel(cfg.provider, cfg.modelId);
    } else if (cfg.isDefaultPicker) {
        DPBYOKSetDefaultModel(cfg.provider, cfg.modelId);
    } else {
        DPBYOKSetActiveModel(cfg.modelId);
    }
    DPBYOKNotifyStateChanged();
}

@end

static NSMenuItem *DPBYOKCreateModelMenuItem(NSDictionary *model, NSString *provider, NSString *selectedModelId, BOOL isDefaultPicker, BOOL isBriefsPicker, BOOL showDefaultBadge) {
    NSString *modelId = model[@"id"];
    NSString *displayName = model[@"name"] ?: modelId;
    NSString *activeProvider = DPBYOKProvider();
    BOOL isSelected = [modelId isEqualToString:selectedModelId] && [provider isEqualToString:activeProvider];

    NSFont *nameFont = [NSFont systemFontOfSize:13 weight:isSelected ? NSFontWeightSemibold : NSFontWeightRegular];
    NSMutableAttributedString *attrTitle = [[NSMutableAttributedString alloc] initWithString:displayName attributes:@{
        NSFontAttributeName: nameFont,
        NSForegroundColorAttributeName: NSColor.labelColor
    }];

    if (showDefaultBadge) {
        NSAttributedString *badgeAttr = [[NSAttributedString alloc] initWithString:@"  Default" attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: NSColor.secondaryLabelColor
        }];
        [attrTitle appendAttributedString:badgeAttr];
    }

    NSArray<NSString *> *thinkingLevels = model[@"thinkingLevels"];
    if (![thinkingLevels isKindOfClass:NSArray.class]) {
        thinkingLevels = DPBYOKThinkingLevelsForModel(provider, modelId);
    }

    NSString *currentLevel = nil;
    if (thinkingLevels.count > 0) {
        currentLevel = DPBYOKThinkingLevel(provider, modelId);
        NSString *levelLabel = DPBYOKThinkingLabel(currentLevel);
        if (levelLabel.length > 0) {
            NSAttributedString *levelAttr = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %@", levelLabel] attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor
            }];
            [attrTitle appendAttributedString:levelAttr];
        }
    }

    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:displayName action:@selector(selectModel:) keyEquivalent:@""];
    item.target = [DPBYOKMenuActionHandler sharedInstance];
    item.representedObject = modelId;
    item.attributedTitle = attrTitle;
    item.state = isSelected ? NSControlStateValueOn : NSControlStateValueOff;

    DPBYOKMenuActionConfig *cfg = [DPBYOKMenuActionConfig new];
    cfg.provider = provider;
    cfg.modelId = modelId;
    cfg.isDefaultPicker = isDefaultPicker;
    cfg.isBriefsPicker = isBriefsPicker;
    objc_setAssociatedObject(item, &kDPBYOKMenuConfigKey, cfg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (thinkingLevels.count > 0) {
        NSMenu *submenu = [[NSMenu alloc] initWithTitle:displayName];
        for (NSString *level in thinkingLevels) {
            NSString *levelLabel = DPBYOKThinkingLabel(level);
            if (levelLabel.length == 0) levelLabel = level;

            NSMenuItem *levelItem = [[NSMenuItem alloc] initWithTitle:levelLabel action:@selector(selectThinkingLevel:) keyEquivalent:@""];
            levelItem.target = [DPBYOKMenuActionHandler sharedInstance];
            levelItem.representedObject = level;
            levelItem.state = (isSelected && [level isEqualToString:currentLevel]) ? NSControlStateValueOn : NSControlStateValueOff;

            DPBYOKMenuActionConfig *levelCfg = [DPBYOKMenuActionConfig new];
            levelCfg.provider = provider;
            levelCfg.modelId = modelId;
            levelCfg.thinkingLevel = level;
            levelCfg.isDefaultPicker = isDefaultPicker;
            levelCfg.isBriefsPicker = isBriefsPicker;
            objc_setAssociatedObject(levelItem, &kDPBYOKMenuConfigKey, levelCfg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            [submenu addItem:levelItem];
        }
        item.submenu = submenu;
    }

    return item;
}

static NSMenu *DPBYOKBuildModelMenuEx(BOOL includeDiaDefault, BOOL isDefaultPicker, BOOL isBriefsPicker) {
    BOOL multiProvider = DPBYOKMultipleProviders.on;
    NSString *currentProvider = DPBYOKProvider() ?: @"gemini";
    NSString *activeModel = DPBYOKActiveModel();
    NSString *defaultModelId = DPBYOKDefaultModel(currentProvider);
    NSString *briefsModelId = DPBYOKBriefsModel(currentProvider);
    NSString *selectedModelId = isBriefsPicker ? briefsModelId : (isDefaultPicker ? defaultModelId : activeModel);

    if (multiProvider) {
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Models"];
        NSUInteger providerCount = 0;

        for (NSDictionary *p in DPBYOKProviders()) {
            NSString *pid = p[@"id"] ?: p[@"key"];
            NSString *title = p[@"title"] ?: p[@"name"] ?: DPBYOKProviderTitle(pid);
            NSString *key = DPBYOKApiKey(pid);
            if (key.length == 0) continue;

            providerCount++;
            NSMenuItem *providerItem = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
            BOOL isCurrentProvider = [pid isEqualToString:currentProvider] && ![selectedModelId isEqualToString:DPBYOKDiaDefaultModel];
            providerItem.state = isCurrentProvider ? NSControlStateValueOn : NSControlStateValueOff;

            NSMenu *providerSubmenu = [[NSMenu alloc] initWithTitle:title];
            NSArray<NSDictionary *> *models = DPBYOKFetchedModels(pid) ?: @[];
            NSString *providerDefault = isBriefsPicker ? DPBYOKBriefsModel(pid) : DPBYOKDefaultModel(pid);

            for (NSDictionary *m in models) {
                BOOL isDef = [m[@"id"] isEqualToString:providerDefault];
                NSMenuItem *modelItem = DPBYOKCreateModelMenuItem(m, pid, selectedModelId, isDefaultPicker, isBriefsPicker, (!isDefaultPicker && !isBriefsPicker && isDef));
                [providerSubmenu addItem:modelItem];
            }

            if (models.count == 0) {
                NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"No Models Fetched" action:nil keyEquivalent:@""];
                none.enabled = NO;
                [providerSubmenu addItem:none];
            }

            providerItem.submenu = providerSubmenu;
            [menu addItem:providerItem];
        }

        if (providerCount == 0) {
            NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"No Configured Providers" action:nil keyEquivalent:@""];
            none.enabled = NO;
            [menu addItem:none];
        }

        [menu addItem:[NSMenuItem separatorItem]];

        BOOL isDiaDefaultSelected = [selectedModelId isEqualToString:DPBYOKDiaDefaultModel];
        NSMenuItem *diaDefaultItem = [[NSMenuItem alloc] initWithTitle:@"Dia Default" action:@selector(selectModel:) keyEquivalent:@""];
        diaDefaultItem.target = [DPBYOKMenuActionHandler sharedInstance];
        diaDefaultItem.representedObject = DPBYOKDiaDefaultModel;
        diaDefaultItem.state = isDiaDefaultSelected ? NSControlStateValueOn : NSControlStateValueOff;

        NSMutableAttributedString *diaAttr = [[NSMutableAttributedString alloc] initWithString:@"Dia Default" attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:13 weight:isDiaDefaultSelected ? NSFontWeightSemibold : NSFontWeightRegular],
            NSForegroundColorAttributeName: NSColor.labelColor
        }];
        diaDefaultItem.attributedTitle = diaAttr;

        DPBYOKMenuActionConfig *diaCfg = [DPBYOKMenuActionConfig new];
        diaCfg.modelId = DPBYOKDiaDefaultModel;
        diaCfg.isDefaultPicker = isDefaultPicker;
        diaCfg.isBriefsPicker = isBriefsPicker;
        objc_setAssociatedObject(diaDefaultItem, &kDPBYOKMenuConfigKey, diaCfg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        [menu addItem:diaDefaultItem];
        return menu;
    }

    NSArray<NSDictionary *> *models = DPBYOKFetchedModels(currentProvider) ?: @[];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:DPBYOKProviderTitle(currentProvider) ?: @"Models"];

    if (includeDiaDefault) {
        NSDictionary *defaultModelDict = nil;
        if (defaultModelId.length > 0) {
            for (NSDictionary *m in models) {
                if ([m[@"id"] isEqualToString:defaultModelId]) {
                    defaultModelDict = m;
                    break;
                }
            }
        }

        if (defaultModelDict) {
            NSMenuItem *topItem = DPBYOKCreateModelMenuItem(defaultModelDict, currentProvider, selectedModelId, isDefaultPicker, isBriefsPicker, YES);
            [menu addItem:topItem];
            [menu addItem:[NSMenuItem separatorItem]];
        }

        for (NSDictionary *m in models) {
            if (defaultModelDict && [m[@"id"] isEqualToString:defaultModelId]) {
                continue;
            }
            NSMenuItem *item = DPBYOKCreateModelMenuItem(m, currentProvider, selectedModelId, isDefaultPicker, isBriefsPicker, NO);
            [menu addItem:item];
        }

        if (models.count == 0) {
            NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"No Models Fetched" action:nil keyEquivalent:@""];
            none.enabled = NO;
            [menu addItem:none];
        }

        [menu addItem:[NSMenuItem separatorItem]];

        BOOL isDiaDefaultSelected = [selectedModelId isEqualToString:DPBYOKDiaDefaultModel];
        NSMenuItem *diaDefaultItem = [[NSMenuItem alloc] initWithTitle:@"Dia Default" action:@selector(selectModel:) keyEquivalent:@""];
        diaDefaultItem.target = [DPBYOKMenuActionHandler sharedInstance];
        diaDefaultItem.representedObject = DPBYOKDiaDefaultModel;
        diaDefaultItem.state = isDiaDefaultSelected ? NSControlStateValueOn : NSControlStateValueOff;

        NSMutableAttributedString *diaAttr = [[NSMutableAttributedString alloc] initWithString:@"Dia Default" attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:13 weight:isDiaDefaultSelected ? NSFontWeightSemibold : NSFontWeightRegular],
            NSForegroundColorAttributeName: NSColor.labelColor
        }];
        diaDefaultItem.attributedTitle = diaAttr;

        DPBYOKMenuActionConfig *diaCfg = [DPBYOKMenuActionConfig new];
        diaCfg.modelId = DPBYOKDiaDefaultModel;
        diaCfg.isDefaultPicker = isDefaultPicker;
        diaCfg.isBriefsPicker = isBriefsPicker;
        objc_setAssociatedObject(diaDefaultItem, &kDPBYOKMenuConfigKey, diaCfg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        [menu addItem:diaDefaultItem];
    } else {
        if (models.count == 0) {
            NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"No Models Available" action:nil keyEquivalent:@""];
            none.enabled = NO;
            [menu addItem:none];
        } else {
            for (NSDictionary *m in models) {
                NSMenuItem *item = DPBYOKCreateModelMenuItem(m, currentProvider, selectedModelId, isDefaultPicker, isBriefsPicker, NO);
                [menu addItem:item];
            }
        }
    }

    return menu;
}

NSMenu *DPBYOKBuildModelMenu(BOOL includeDiaDefault, BOOL isDefaultPicker) {
    return DPBYOKBuildModelMenuEx(includeDiaDefault, isDefaultPicker, NO);
}

NSMenu *DPBYOKBuildBriefsModelMenu(BOOL includeDiaDefault) {
    return DPBYOKBuildModelMenuEx(includeDiaDefault, NO, YES);
}
