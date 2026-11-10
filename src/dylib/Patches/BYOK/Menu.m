#import <objc/runtime.h>
#import "Patches/BYOK/BYOK.h"

static char kDPBYOKMenuConfigKey;

@interface DPBYOKMenuActionConfig : NSObject
@property (nonatomic, copy) NSString *provider;
@property (nonatomic, copy) NSString *modelId;
@property (nonatomic, copy) NSString *thinkingLevel;
@property (nonatomic, assign) BOOL isDefaultPicker;
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
    if ([sender.representedObject isEqual:DPBYOKDiaDefaultModel]) {
        DPBYOKSetActiveModel(DPBYOKDiaDefaultModel);
        DPBYOKNotifyStateChanged();
        return;
    }

    DPBYOKMenuActionConfig *cfg = objc_getAssociatedObject(sender, &kDPBYOKMenuConfigKey);
    NSString *modelId = cfg ? cfg.modelId : (NSString *)sender.representedObject;
    NSString *provider = cfg ? cfg.provider : DPBYOKProvider();
    BOOL isDefault = cfg ? cfg.isDefaultPicker : NO;

    if (isDefault) {
        DPBYOKSetDefaultModel(provider, modelId);
    } else {
        DPBYOKSetActiveModel(modelId);
    }
    DPBYOKNotifyStateChanged();
}

- (void)selectThinkingLevel:(NSMenuItem *)sender {
    DPBYOKMenuActionConfig *cfg = objc_getAssociatedObject(sender, &kDPBYOKMenuConfigKey);
    if (!cfg) return;

    DPBYOKSetThinkingLevel(cfg.provider, cfg.modelId, cfg.thinkingLevel);
    if (cfg.isDefaultPicker) {
        DPBYOKSetDefaultModel(cfg.provider, cfg.modelId);
    } else {
        DPBYOKSetActiveModel(cfg.modelId);
    }
    DPBYOKNotifyStateChanged();
}

@end

static NSMenuItem *DPBYOKCreateModelMenuItem(NSDictionary *model, NSString *provider, NSString *selectedModelId, BOOL isDefaultPicker, BOOL showDefaultBadge) {
    NSString *modelId = model[@"id"];
    NSString *displayName = model[@"name"] ?: modelId;
    BOOL isSelected = [modelId isEqualToString:selectedModelId];

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
    objc_setAssociatedObject(item, &kDPBYOKMenuConfigKey, cfg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (thinkingLevels.count > 0) {
        NSMenu *submenu = [[NSMenu alloc] initWithTitle:displayName];
        for (NSString *level in thinkingLevels) {
            NSString *levelLabel = DPBYOKThinkingLabel(level);
            if (levelLabel.length == 0) levelLabel = level;

            NSMenuItem *levelItem = [[NSMenuItem alloc] initWithTitle:levelLabel action:@selector(selectThinkingLevel:) keyEquivalent:@""];
            levelItem.target = [DPBYOKMenuActionHandler sharedInstance];
            levelItem.representedObject = level;
            levelItem.state = [level isEqualToString:currentLevel] ? NSControlStateValueOn : NSControlStateValueOff;

            DPBYOKMenuActionConfig *levelCfg = [DPBYOKMenuActionConfig new];
            levelCfg.provider = provider;
            levelCfg.modelId = modelId;
            levelCfg.thinkingLevel = level;
            levelCfg.isDefaultPicker = isDefaultPicker;
            objc_setAssociatedObject(levelItem, &kDPBYOKMenuConfigKey, levelCfg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            [submenu addItem:levelItem];
        }
        item.submenu = submenu;
    }

    return item;
}

NSMenu *DPBYOKBuildModelMenu(BOOL includeDiaDefault, BOOL isDefaultPicker) {
    NSString *provider = DPBYOKProvider() ?: @"gemini";
    NSArray<NSDictionary *> *models = DPBYOKFetchedModels(provider) ?: @[];
    NSString *activeModel = DPBYOKActiveModel();
    NSString *defaultModelId = DPBYOKDefaultModel(provider);
    NSString *selectedModelId = isDefaultPicker ? defaultModelId : activeModel;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:DPBYOKProviderTitle(provider) ?: @"Models"];

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
            NSMenuItem *topItem = DPBYOKCreateModelMenuItem(defaultModelDict, provider, selectedModelId, isDefaultPicker, YES);
            [menu addItem:topItem];
            [menu addItem:[NSMenuItem separatorItem]];
        }

        for (NSDictionary *m in models) {
            if (defaultModelDict && [m[@"id"] isEqualToString:defaultModelId]) {
                continue;
            }
            NSMenuItem *item = DPBYOKCreateModelMenuItem(m, provider, selectedModelId, isDefaultPicker, NO);
            [menu addItem:item];
        }

        if (models.count == 0) {
            NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"No Models Fetched" action:nil keyEquivalent:@""];
            none.enabled = NO;
            [menu addItem:none];
        }

        [menu addItem:[NSMenuItem separatorItem]];

        BOOL isDiaDefaultSelected = [activeModel isEqualToString:DPBYOKDiaDefaultModel];
        NSMenuItem *diaDefaultItem = [[NSMenuItem alloc] initWithTitle:@"Dia Default" action:@selector(selectModel:) keyEquivalent:@""];
        diaDefaultItem.target = [DPBYOKMenuActionHandler sharedInstance];
        diaDefaultItem.representedObject = DPBYOKDiaDefaultModel;
        diaDefaultItem.state = isDiaDefaultSelected ? NSControlStateValueOn : NSControlStateValueOff;

        NSMutableAttributedString *diaAttr = [[NSMutableAttributedString alloc] initWithString:@"Dia Default" attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:13 weight:isDiaDefaultSelected ? NSFontWeightSemibold : NSFontWeightRegular],
            NSForegroundColorAttributeName: NSColor.labelColor
        }];
        diaDefaultItem.attributedTitle = diaAttr;

        [menu addItem:diaDefaultItem];
    } else {
        if (models.count == 0) {
            NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"No Models Available" action:nil keyEquivalent:@""];
            none.enabled = NO;
            [menu addItem:none];
        } else {
            for (NSDictionary *m in models) {
                NSMenuItem *item = DPBYOKCreateModelMenuItem(m, provider, selectedModelId, isDefaultPicker, NO);
                [menu addItem:item];
            }
        }
    }

    return menu;
}
