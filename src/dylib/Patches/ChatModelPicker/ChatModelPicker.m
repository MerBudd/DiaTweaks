#import "ChatModelPicker.h"
#import "Settings/Settings.h"
#import <objc/runtime.h>

static const void *kChatModelPickerButtonKey = &kChatModelPickerButtonKey;

static NSView *DPFindPlusAttachButton(NSView *view) {
    if (!view) return nil;
    if (DPHasLabel(view, @"Add a tab or file") || DPHasLabel(view, @"add") || DPHasLabel(view, @"Attach")) {
        return view;
    }
    for (NSView *sub in view.subviews) {
        NSView *found = DPFindPlusAttachButton(sub);
        if (found) return found;
    }
    return nil;
}

static CGFloat DPFindRightControlsMinX(NSView *container, CGFloat defaultMinX) {
    CGFloat minX = defaultMinX;
    for (NSView *sub in container.subviews) {
        if (DPHasLabel(sub, @"Send prompt") ||
            DPHasLabel(sub, @"Add a screen capture") ||
            DPHasLabel(sub, @"Speak to type") ||
            [NSStringFromClass(sub.class) containsString:@"ResponseCommandGroupView"]) {
            NSRect r = [container convertRect:sub.bounds fromView:sub];
            if (r.origin.x > 50.0 && r.origin.x < minX) {
                minX = r.origin.x;
            }
        }
        for (NSView *child in sub.subviews) {
            if (DPHasLabel(child, @"Send prompt") ||
                DPHasLabel(child, @"Add a screen capture") ||
                DPHasLabel(child, @"Speak to type") ||
                [NSStringFromClass(child.class) containsString:@"ResponseCommandGroupView"]) {
                NSRect r = [container convertRect:child.bounds fromView:child];
                if (r.origin.x > 50.0 && r.origin.x < minX) {
                    minX = r.origin.x;
                }
            }
        }
    }
    return minX;
}

static NSView *DPFindAncestorOfClass(NSView *view, const char *clsName) {
    Class target = objc_getClass(clsName);
    if (!target) return nil;
    NSView *v = view;
    while (v) {
        if ([v isKindOfClass:target]) return v;
        v = v.superview;
    }
    return nil;
}

static void DPUpdateCommandBarLayout(NSView *triggerView) {
    if (!DPChatModelPicker.on) {
        DPRemoveAllPickerButtons();
        return;
    }

    NSView *rootView = DPFindAncestorOfClass(triggerView, DPDiaBoostRootView) ?: triggerView;
    NSView *plusBtn = DPFindPlusAttachButton(rootView);

    if (!plusBtn && triggerView != rootView) {
        plusBtn = DPFindPlusAttachButton(triggerView);
    }
    if (!plusBtn && triggerView.window) {
        plusBtn = DPFindPlusAttachButton(triggerView.window.contentView);
    }
    if (!plusBtn) return;

    DPChatModelPickerButton *pickerBtn = objc_getAssociatedObject(rootView, kChatModelPickerButtonKey);
    if (!pickerBtn) {
        pickerBtn = [[DPChatModelPickerButton alloc] initWithFrame:NSMakeRect(0, 0, 140, 26)];
        objc_setAssociatedObject(rootView, kChatModelPickerButtonKey, pickerBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DPRegisterPickerButton(pickerBtn);
    }

    NSView *toolbar = plusBtn.superview;
    while (toolbar && toolbar != rootView && ![toolbar isKindOfClass:objc_getClass(DPDiaBoostToolbar)]) {
        toolbar = toolbar.superview;
    }
    if (!toolbar) toolbar = plusBtn.superview;

    // Detect floating chat vs sidebar / new tab chat
    BOOL isFloating = NO;
    if (toolbar && rootView && rootView.bounds.size.width > 0) {
        NSRect toolbarInRoot = [rootView convertRect:toolbar.bounds fromView:toolbar];
        if (toolbarInRoot.origin.x > 80.0 || toolbarInRoot.size.width < rootView.bounds.size.width * 0.6) {
            isFloating = YES;
        }
    }

    CGFloat btnHeight = 26.0;

    if (isFloating) {
        // Floating pop-up chat: button is to the LEFT of the plus button
        NSRect plusFrameInRoot = [rootView convertRect:plusBtn.bounds fromView:plusBtn];
        CGFloat btnY = plusFrameInRoot.origin.y + (plusFrameInRoot.size.height - btnHeight) / 2.0;

        CGFloat maxAvailable = plusFrameInRoot.origin.x - 16.0;
        NSSize idealSize = [pickerBtn sizeThatFits:NSMakeSize(maxAvailable, btnHeight)];
        CGFloat btnWidth = MIN(idealSize.width, MAX(maxAvailable, 70.0));
        CGFloat btnX = plusFrameInRoot.origin.x - btnWidth - 8.0;
        if (btnX < 8.0) {
            btnX = 8.0;
            btnWidth = MAX(plusFrameInRoot.origin.x - 16.0, 60.0);
        }

        pickerBtn.frame = NSMakeRect(btnX, btnY, btnWidth, btnHeight);

        // In floating chat, MUST be added directly to rootView so the full hitbox registers clicks
        if (pickerBtn.superview != rootView) {
            [rootView addSubview:pickerBtn positioned:NSWindowAbove relativeTo:toolbar];
        }
    } else {
        // Sidebar chat and New Tab Page: button is to the RIGHT of the plus button
        NSView *parentContainer = toolbar ?: rootView;
        NSRect plusFrame = [parentContainer convertRect:plusBtn.bounds fromView:plusBtn];
        CGFloat btnX = plusFrame.origin.x + plusFrame.size.width + 8.0;
        CGFloat btnY = plusFrame.origin.y + (plusFrame.size.height - btnHeight) / 2.0;

        CGFloat rightLimit = DPFindRightControlsMinX(parentContainer, parentContainer.bounds.size.width - 110.0);
        CGFloat maxAvailable = (rightLimit - 8.0) - btnX;
        if (maxAvailable < 60.0) maxAvailable = 60.0;

        NSSize idealSize = [pickerBtn sizeThatFits:NSMakeSize(maxAvailable, btnHeight)];
        CGFloat btnWidth = MIN(idealSize.width, maxAvailable);

        pickerBtn.frame = NSMakeRect(btnX, btnY, btnWidth, btnHeight);

        if (pickerBtn.superview != parentContainer) {
            [parentContainer addSubview:pickerBtn];
        }
    }
}

static void DPBoostToolbar_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(DPBoostToolbar_layout, self);
    DPUpdateCommandBarLayout(self);
}

static void DPBoostRootView_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(DPBoostRootView_layout, self);
    DPUpdateCommandBarLayout(self);
}

static void DPHoverableControl_mouseDown(NSControl *self, SEL _cmd, NSEvent *event) {
    if (DPHasLabel(self, @"New chat")) {
        DPResetToDefaultModel();
    }
    DPCallOriginal(DPHoverableControl_mouseDown, self, event);
}

static void DPInstallChatModelPicker(void) {
    DPHook(DPDiaBoostToolbar, @selector(layout), (IMP)DPBoostToolbar_layout);
    DPHook(DPDiaBoostRootView, @selector(layout), (IMP)DPBoostRootView_layout);
    DPHook("_TtC5ARCUI16HoverableControl", @selector(mouseDown:), (IMP)DPHoverableControl_mouseDown);

    DPOnLaunch(^{
        DPResetToDefaultModel();
    });
}

static void DPApplyChatModelPicker(DPPatch *patch) {
    if (!patch->on) {
        DPRemoveAllPickerButtons();
    } else {
        DPUpdateAllPickerButtons();
    }
}

static NSString *DPVerifyChatModelPicker(DPPatch *patch) {
    if (patch->on) {
        Class cls = objc_getClass(DPDiaBoostToolbar);
        if (!cls) return @"BoostToolbar class missing";
    }
    return nil;
}

static NSMenu *DPChatModelPickerChoices(void) {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Default Model For New Chats"];
    NSArray *models = @[
        @{@"id": @"claude-opus-4-6", @"title": @"Claude Opus 4.6 (Default)"},
        @{@"id": @"claude-opus-4-8", @"title": @"Claude Opus 4.8"},
        @{@"id": @"claude-opus-5-5", @"title": @"Claude Opus 5.5"},
        @{@"id": @"claude-sonnet-5-5", @"title": @"Claude Sonnet 5.5"},
        @{@"id": @"claude-haiku-5-5", @"title": @"Claude Haiku 5.5"},
    ];
    for (NSDictionary *m in models) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:m[@"title"] action:nil keyEquivalent:@""];
        item.representedObject = m[@"id"];
        [menu addItem:item];
    }
    return menu;
}

DP_PATCH(DPChatModelPicker) {
    .key = @"chatModelPicker",
    .order = 51,
    .defaultOn = YES,
    .title = @"Model Picker in Chat",
    .detail = @"Choose models and thinking levels directly from the chat prompt bar.",
    .symbol = @"sparkles",
    .tint = @"systemPurpleColor",
    .choice = @"chatDefaultModel",
    .defaultChoice = @"claude-opus-4-6",
    .choices = DPChatModelPickerChoices,
    .classes = DPClasses(DPDiaBoostToolbar),
    .install = DPInstallChatModelPicker,
    .apply = DPApplyChatModelPicker,
    .verify = DPVerifyChatModelPicker,
};
