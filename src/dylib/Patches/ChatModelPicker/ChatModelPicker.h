#import "StdPatch/StdPatch.h"

extern DPPatch DPChatModelPicker;

@class DPChatModelPickerButton;

// State and configuration helpers
NSString *DPFriendlyModelName(NSString *modelId, NSString *catalogName);
NSDictionary *DPGetModelThinkingCapabilities(NSString *modelId);
NSMutableDictionary *DPLoadChatModelConfig(void);
void DPSaveChatModelConfig(NSDictionary *dict);
void DPResetToDefaultModel(void);
void DPRegisterPickerButton(DPChatModelPickerButton *btn);
void DPUpdateAllPickerButtons(void);
void DPRemoveAllPickerButtons(void);

// Chat Model Picker Button View
@interface DPChatModelPickerButton : NSControl
@property (nonatomic, copy) NSString *modelId;
@property (nonatomic, copy) NSString *modelTitle;
@property (nonatomic, copy) NSString *thinkingLevel;
@property (nonatomic, assign) BOOL isHovered;
@property (nonatomic, strong) NSTrackingArea *trackingArea;

- (void)reloadFromConfig;
@end

@interface DPChatModelPickerButton (Menu)
- (void)showModelMenu:(id)sender;
@end
