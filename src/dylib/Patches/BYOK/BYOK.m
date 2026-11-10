#import "Patches/BYOK/BYOK.h"

static void DPApplyBYOK(DPPatch *patch) {
    DPBYOKNotifyStateChanged();
    DPApplyBYOKPicker(patch);
}

DP_PATCH(DPBYOK) {
    .key = @"byok",
    .order = 95,
    .section = @"AI",
    .title = @"Bring Your Own Key",
    .detail = @"Route Dia Chat through your own Google Gemini, OpenAI, Anthropic, or OpenRouter API key while keeping Dia's full browser context, attachments, skills, and tools.",
    .symbol = @"key.fill",
    .tint = @"systemPurpleColor",
    .disabledBy = @"turnOffAI",
    .rows = DPBYOKRows,
    .install = DPInstallBYOKProxy,
    .apply = DPApplyBYOK,
    .verify = DPVerifyBYOKProxy,
};

DP_PATCH(DPBYOKModelPicker) {
    .key = @"byokModelPicker",
    .defaultOn = YES,
    .requires = @"byok",
    .section = @"Options",
    .title = @"Model Picker in Chat",
    .detail = @"Show a dropdown in the New Tab command bar and Chat input bars to switch between your fetched models, thinking levels, and Dia Default.",
    .symbol = @"slider.horizontal.3",
    .tint = @"systemPurpleColor",
    .disabledBy = @"turnOffAI",
    .classes = DPClasses(DPDiaCommandBar, DPDiaCommandBarInput, DPDiaCommandBarText, DPDiaCommandBarToolbar, DPDiaCommandBarButton, DPDiaCapabilityButton),
    .install = DPInstallBYOKPicker,
    .apply = DPApplyBYOKPicker,
    .verify = DPVerifyBYOKPicker,
};
