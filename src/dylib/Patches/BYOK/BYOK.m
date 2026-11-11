#import "Patches/BYOK/BYOK.h"

static void DPApplyBYOK(DPPatch *patch) {
    DPBYOKNotifyStateChanged();
    DPApplyBYOKPicker(patch);
}

static void DPApplyBYOKMultipleProviders(DPPatch *patch) {
    (void)patch;
    DPBYOKNotifyStateChanged();
}

static void DPApplyBYOKBriefs(DPPatch *patch) {
    (void)patch;
    DPBYOKNotifyStateChanged();
}

DP_PATCH(DPBYOK) {
    .key = @"byok",
    .order = 95,
    .section = @"AI",
    .title = @"Bring Your Own Key",
    .detail = @"Route Dia Chat through your own Google Gemini, OpenAI, Anthropic, or OpenRouter API key while keeping Dia's full browser context, attachments, skills, and tools. Keys are stored securely in the macOS Keychain.",
    .symbol = @"key.fill",
    .tint = @"systemPurpleColor",
    .disabledBy = @"turnOffAI",
    .rows = DPBYOKRows,
    .install = DPInstallBYOKProxy,
    .apply = DPApplyBYOK,
    .verify = DPVerifyBYOKProxy,
};

DP_PATCH(DPBYOKMultipleProviders) {
    .key = @"byokMultipleProviders",
    .requires = @"byok",
    .section = @"Options",
    .title = @"Use multiple providers",
    .detail = @"Enable selecting models from any provider with a configured API key across chat and settings menus.",
    .symbol = @"square.grid.2x2",
    .tint = @"systemPurpleColor",
    .disabledBy = @"turnOffAI",
    .apply = DPApplyBYOKMultipleProviders,
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

DP_PATCH(DPBYOKBriefs) {
    .key = @"byokBriefs",
    .requires = @"byok",
    .section = @"Briefs & Daily Summaries",
    .title = @"Use key for briefs and summaries",
    .detail = @"Route automated requests such as daily briefs, morning summaries, proactive tasks, and background agent tasks through your configured API key.",
    .symbol = @"sun.max",
    .tint = @"systemPurpleColor",
    .disabledBy = @"turnOffAI",
    .apply = DPApplyBYOKBriefs,
};

DP_PATCH(DPBYOKBriefsModel) {
    .key = @"byokBriefsModel",
    .requires = @"byok",
    .section = @"Briefs & Daily Summaries",
    .title = @"Custom Model for Briefs and Summaries",
    .detail = @"Choose a dedicated model for automated briefs and background summaries. When disabled, briefs use your default model.",
    .symbol = @"cpu",
    .tint = @"systemPurpleColor",
    .disabledBy = @"turnOffAI",
    .rows = DPBYOKBriefsRows,
    .apply = DPApplyBYOKBriefs,
};
