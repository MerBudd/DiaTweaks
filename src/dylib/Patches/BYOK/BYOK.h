#import "StdPatch/StdPatch.h"
#import "Settings/Settings.h"
#import "Patches/TurnOffAI/TurnOffAI.h"
#import "Patches/CompactCommandBar/CompactCommandBar.h"

extern DPPatch DPBYOK, DPBYOKModelPicker, DPBYOKMultipleProviders, DPBYOKBriefs, DPBYOKBriefsModel;

extern NSString *const DPBYOKDiaDefaultModel;
extern NSNotificationName const DPBYOKStateDidChangeNotification;

// Keychain.m
NSString *DPBYOKLoadKey(NSString *provider);
BOOL DPBYOKSaveKey(NSString *provider, NSString *apiKey);

// State.m
NSArray<NSDictionary<NSString *, NSString *> *> *DPBYOKProviders(void);
NSString *DPBYOKProviderTitle(NSString *provider);
NSString *DPBYOKProvider(void);
void DPBYOKSetProvider(NSString *provider);

NSString *DPBYOKApiKey(NSString *provider);
void DPBYOKSetApiKey(NSString *provider, NSString *key);

NSArray<NSDictionary *> *DPBYOKFetchedModels(NSString *provider);
void DPBYOKSetFetchedModels(NSString *provider, NSArray<NSDictionary *> *models);

NSString *DPBYOKDefaultModel(NSString *provider);
void DPBYOKSetDefaultModel(NSString *provider, NSString *modelId);

NSString *DPBYOKGetBriefsModel(NSString *provider);
void DPBYOKSetBriefsModel(NSString *provider, NSString *modelId);

#define DPBYOK_OVERLOAD(_0, _1, NAME, ...) NAME
#define DPBYOKBriefsModel0() DPBYOKGetBriefsModel(nil)
#define DPBYOKBriefsModel1(p) DPBYOKGetBriefsModel(p)
#define DPBYOKBriefsModel(...) DPBYOK_OVERLOAD(dummy, ##__VA_ARGS__, DPBYOKBriefsModel1, DPBYOKBriefsModel0)(__VA_ARGS__)

NSString *DPBYOKActiveModel(void);
void DPBYOKSetActiveModel(NSString *modelId);

NSString *DPBYOKThinkingLevel(NSString *provider, NSString *modelId);
void DPBYOKSetThinkingLevel(NSString *provider, NSString *modelId, NSString *level);

NSDictionary *DPBYOKModelInfo(NSString *provider, NSString *modelId);
NSString *DPBYOKDisplayNameForModel(NSString *provider, NSString *modelId);
NSArray<NSString *> *DPBYOKThinkingLevelsForModel(NSString *provider, NSString *modelId);
NSString *DPBYOKThinkingLabel(NSString *level);
BOOL DPBYOKShouldRoute(NSString *agentSpec);
void DPBYOKNotifyStateChanged(void);

// Models.m
void DPBYOKFetchModels(NSString *provider, NSString *apiKey, void (^completion)(NSArray<NSDictionary *> *models, NSError *error));

// Menu.m
NSMenu *DPBYOKBuildModelMenu(BOOL includeDiaDefault, BOOL isDefaultPicker);
NSMenu *DPBYOKBuildBriefsModelMenu(BOOL includeDiaDefault);

// Settings.m
NSArray<NSView *> *DPBYOKRows(void);
NSArray<NSView *> *DPBYOKBriefsRows(void);

// Picker.m
void DPInstallBYOKPicker(void);
void DPApplyBYOKPicker(DPPatch *patch);
NSString *DPVerifyBYOKPicker(DPPatch *patch);
void DPUpdateAllBYOKPickers(void);

// Proxy.m
void DPInstallBYOKProxy(void);
NSString *DPVerifyBYOKProxy(DPPatch *patch);
void DPBYOKRestartAgentServersIfNeeded(void);

// Router.m / Translator.m / Gemini.m
typedef void (^DPBYOKStreamCallback)(NSInteger statusCode, NSDictionary *headers, NSString *data, BOOL done, NSString *errorMessage);

void DPBYOKExecuteLLMRequest(NSString *endpoint, NSDictionary *headers, NSString *bodyString, NSString *agentSpec, DPBYOKStreamCallback callback);
NSDictionary *DPBYOKTranslateAnthropicToOpenAI(NSDictionary *anthropicBody, NSString *provider, NSString *modelId, NSString *thinkingLevel);
void DPBYOKStreamOpenAIResponse(NSURLRequest *request, NSString *modelId, DPBYOKStreamCallback callback);
void DPBYOKExecuteGeminiRequest(NSDictionary *anthropicBody, NSString *apiKey, NSString *modelId, NSString *thinkingLevel, DPBYOKStreamCallback callback);
