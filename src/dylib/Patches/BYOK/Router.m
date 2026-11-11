#import "Patches/BYOK/BYOK.h"

__attribute__((weak)) extern DPPatch DPBYOK;
__attribute__((weak)) extern DPPatch DPBYOKBriefs;
__attribute__((weak)) extern DPPatch DPBYOKBriefsModel;

#pragma mark - Anthropic SSE Error Formatter

static NSString *DPBYOKAnthropicSSEError(NSString *message) {
    NSString *prefixed = [NSString stringWithFormat:@"⚠️ BYOK Error: %@", message ?: @"Unknown error"];
    NSDictionary *deltaDict = @{
        @"type": @"content_block_delta",
        @"index": @0,
        @"delta": @{
            @"type": @"text_delta",
            @"text": prefixed
        }
    };
    NSData *deltaData = [NSJSONSerialization dataWithJSONObject:deltaDict options:0 error:nil];
    NSString *deltaJSON = deltaData ? [[NSString alloc] initWithData:deltaData encoding:NSUTF8StringEncoding] : @"{}";

    return [NSString stringWithFormat:
        @"event: message_start\n"
        @"data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_byok_err\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"byok\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n"
        @"event: content_block_start\n"
        @"data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
        @"event: content_block_delta\n"
        @"data: %@\n\n"
        @"event: content_block_stop\n"
        @"data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
        @"event: message_delta\n"
        @"data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":1}}\n\n"
        @"event: message_stop\n"
        @"data: {\"type\":\"message_stop\"}\n\n",
        deltaJSON];
}

#pragma mark - Helper Functions for Anthropic Body Sanitization

static void DPBYOKStripThinkingBlocksFromMessages(NSMutableDictionary *body) {
    NSArray *messages = body[@"messages"];
    if (![messages isKindOfClass:[NSArray class]]) return;

    NSMutableArray *cleanedMessages = [NSMutableArray arrayWithCapacity:messages.count];
    for (id msgObj in messages) {
        if (![msgObj isKindOfClass:[NSDictionary class]]) {
            [cleanedMessages addObject:msgObj];
            continue;
        }
        NSMutableDictionary *msg = [msgObj mutableCopy];
        if ([msg[@"role"] isEqualToString:@"assistant"]) {
            id content = msg[@"content"];
            if ([content isKindOfClass:[NSArray class]]) {
                NSMutableArray *cleanedBlocks = [NSMutableArray array];
                for (id blockObj in content) {
                    if ([blockObj isKindOfClass:[NSDictionary class]]) {
                        NSString *type = blockObj[@"type"];
                        if ([type isEqualToString:@"thinking"] || [type isEqualToString:@"redacted_thinking"]) {
                            continue;
                        }
                    }
                    [cleanedBlocks addObject:blockObj];
                }
                if (cleanedBlocks.count == 0) {
                    cleanedBlocks = [NSMutableArray arrayWithObject:@{@"type": @"text", @"text": @"..."}];
                }
                msg[@"content"] = cleanedBlocks;
            }
        }
        [cleanedMessages addObject:msg];
    }
    body[@"messages"] = cleanedMessages;
}

static void DPBYOKStripUnsignedThinkingBlocksFromMessages(NSMutableDictionary *body) {
    NSArray *messages = body[@"messages"];
    if (![messages isKindOfClass:[NSArray class]]) return;

    NSMutableArray *cleanedMessages = [NSMutableArray arrayWithCapacity:messages.count];
    for (id msgObj in messages) {
        if (![msgObj isKindOfClass:[NSDictionary class]]) {
            [cleanedMessages addObject:msgObj];
            continue;
        }
        NSMutableDictionary *msg = [msgObj mutableCopy];
        if ([msg[@"role"] isEqualToString:@"assistant"]) {
            id content = msg[@"content"];
            if ([content isKindOfClass:[NSArray class]]) {
                NSMutableArray *cleanedBlocks = [NSMutableArray array];
                for (id blockObj in content) {
                    if ([blockObj isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *block = (NSDictionary *)blockObj;
                        NSString *type = block[@"type"];
                        if ([type isEqualToString:@"thinking"]) {
                            id sig = block[@"signature"];
                            if (![sig isKindOfClass:[NSString class]] || ((NSString *)sig).length == 0) {
                                // Strip unsigned thinking block across provider/model transitions
                                continue;
                            }
                        }
                    }
                    [cleanedBlocks addObject:blockObj];
                }
                if (cleanedBlocks.count == 0) {
                    cleanedBlocks = [NSMutableArray arrayWithObject:@{@"type": @"text", @"text": @"..."}];
                }
                msg[@"content"] = cleanedBlocks;
            }
        }
        [cleanedMessages addObject:msg];
    }
    body[@"messages"] = cleanedMessages;
}

void DPBYOKSanitizeAnthropicBody(NSMutableDictionary *body) {
    NSSet *standardKeys = [NSSet setWithObjects:
        @"system",
        @"messages",
        @"tools",
        @"tool_choice",
        @"max_tokens",
        @"temperature",
        @"top_p",
        @"top_k",
        @"stop_sequences",
        @"stream",
        @"thinking",
        @"model",
        @"output_config",
        nil
    ];

    id metadata = body[@"metadata"];
    if ([metadata isKindOfClass:[NSDictionary class]]) {
        NSString *userId = metadata[@"user_id"];
        if ([userId isKindOfClass:[NSString class]] && userId.length > 0) {
            body[@"metadata"] = @{@"user_id": userId};
        } else {
            [body removeObjectForKey:@"metadata"];
        }
    } else {
        [body removeObjectForKey:@"metadata"];
    }

    // Strip unsupported tool fields injected by Dia (DeferredToolPlaceholder and defer_loading)
    id toolsObj = body[@"tools"];
    if ([toolsObj isKindOfClass:[NSArray class]]) {
        NSMutableArray *cleanedTools = [NSMutableArray array];
        for (id toolItem in (NSArray *)toolsObj) {
            if (![toolItem isKindOfClass:[NSDictionary class]]) continue;
            NSString *toolName = toolItem[@"name"];
            if ([toolName isKindOfClass:[NSString class]] && [toolName isEqualToString:@"DeferredToolPlaceholder"]) {
                continue;
            }
            NSMutableDictionary *cleanedTool = [toolItem mutableCopy];
            [cleanedTool removeObjectForKey:@"defer_loading"];
            [cleanedTools addObject:cleanedTool];
        }
        if (cleanedTools.count > 0) {
            body[@"tools"] = cleanedTools;
        } else {
            [body removeObjectForKey:@"tools"];
            [body removeObjectForKey:@"tool_choice"];
        }
    }

    // Strip unsigned thinking blocks across provider transitions
    DPBYOKStripUnsignedThinkingBlocksFromMessages(body);

    for (NSString *key in body.allKeys) {
        if (![standardKeys containsObject:key] && ![key isEqualToString:@"metadata"]) {
            [body removeObjectForKey:key];
        }
    }

    if ([body[@"tools"] isKindOfClass:[NSArray class]] && ((NSArray *)body[@"tools"]).count == 0) {
        [body removeObjectForKey:@"tools"];
        [body removeObjectForKey:@"tool_choice"];
    }
}

#pragma mark - Anthropic / OpenRouter Stream Delegate

@interface DPBYOKAnthropicStreamDelegate : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, copy) DPBYOKStreamCallback callback;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong) NSMutableData *accumulatedErrorData;
@property (nonatomic, strong) NSMutableData *byteBuffer;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation DPBYOKAnthropicStreamDelegate

- (instancetype)initWithCallback:(DPBYOKStreamCallback)callback {
    self = [super init];
    if (self) {
        _callback = [callback copy];
        _accumulatedErrorData = [NSMutableData data];
        _byteBuffer = [NSMutableData data];
    }
    return self;
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        self.statusCode = ((NSHTTPURLResponse *)response).statusCode;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    @synchronized (self) {
        if (self.finished) return;

        if (self.statusCode >= 400) {
            [self.accumulatedErrorData appendData:data];
            return;
        }

        [self.byteBuffer appendData:data];
        [self processByteBuffer];
    }
}

- (void)processByteBuffer {
    while (self.byteBuffer.length > 0) {
        if (self.finished) return;
        const uint8_t *bytes = (const uint8_t *)self.byteBuffer.bytes;
        NSUInteger len = self.byteBuffer.length;
        const void *nl = memchr(bytes, '\n', len);
        if (!nl) break;

        NSUInteger lineLen = (const uint8_t *)nl - bytes;
        NSData *lineData = [self.byteBuffer subdataWithRange:NSMakeRange(0, lineLen)];
        [self.byteBuffer replaceBytesInRange:NSMakeRange(0, lineLen + 1) withBytes:NULL length:0];

        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (!line) continue;

        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
        trimmed = [trimmed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        BOOL hasStop = [trimmed isEqualToString:@"event: message_stop"] ||
                       [trimmed isEqualToString:@"data: {\"type\":\"message_stop\"}"] ||
                       [trimmed isEqualToString:@"data: {\"type\": \"message_stop\"}"];

        NSString *lineWithNL = [line stringByAppendingString:@"\n"];

        if (hasStop) {
            DPBYOKStreamCallback cb = nil;
            @synchronized (self) {
                if (self.finished) return;
                self.finished = YES;
                cb = self.callback;
                self.callback = nil;
            }

            if (cb) {
                cb(200, @{@"content-type": @"text/event-stream"}, lineWithNL, NO, nil);
                cb(200, @{@"content-type": @"text/event-stream"}, @"", YES, nil);
            }

            [self.task cancel];
            NSURLSession *sess = self.session;
            self.session = nil;
            self.task = nil;
            [sess invalidateAndCancel];
            return;
        } else {
            DPBYOKStreamCallback cb = nil;
            @synchronized (self) {
                if (self.finished) return;
                cb = self.callback;
            }
            if (cb) {
                cb(200, @{@"content-type": @"text/event-stream"}, lineWithNL, NO, nil);
            }
        }
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    DPBYOKStreamCallback cb = nil;
    NSInteger status = 0;
    NSData *errData = nil;

    @synchronized (self) {
        if (self.finished) {
            NSURLSession *sess = self.session ?: session;
            self.session = nil;
            self.task = nil;
            [sess invalidateAndCancel];
            return;
        }
        self.finished = YES;
        cb = self.callback;
        self.callback = nil;
        status = self.statusCode;
        errData = [self.accumulatedErrorData copy];
    }

    NSURLSession *sess = self.session ?: session;
    self.session = nil;
    self.task = nil;

    if (status >= 400) {
        NSString *errMsg = nil;
        if (errData.length > 0) {
            id parsed = [NSJSONSerialization JSONObjectWithData:errData options:0 error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                id errObj = parsed[@"error"];
                if ([errObj isKindOfClass:[NSDictionary class]]) {
                    if (errObj[@"message"]) {
                        errMsg = [errObj[@"message"] description];
                    } else if (errObj[@"detail"]) {
                        errMsg = [errObj[@"detail"] description];
                    }
                } else if ([errObj isKindOfClass:[NSString class]]) {
                    errMsg = errObj;
                } else if (parsed[@"message"]) {
                    errMsg = [parsed[@"message"] description];
                } else if (parsed[@"detail"]) {
                    errMsg = [parsed[@"detail"] description];
                }
            }
            if (!errMsg || errMsg.length == 0) {
                errMsg = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
            }
        }
        if (!errMsg || errMsg.length == 0) {
            errMsg = [NSString stringWithFormat:@"HTTP error %ld", (long)status];
        }

        NSString *sseErr = DPBYOKAnthropicSSEError(errMsg);
        if (cb) {
            cb(200, @{@"content-type": @"text/event-stream"}, sseErr, YES, nil);
        }
    } else if (error && error.code != NSURLErrorCancelled) {
        NSString *sseErr = DPBYOKAnthropicSSEError(error.localizedDescription);
        if (cb) {
            cb(200, @{@"content-type": @"text/event-stream"}, sseErr, YES, nil);
        }
    } else {
        if (self.byteBuffer.length > 0) {
            NSString *remaining = [[NSString alloc] initWithData:self.byteBuffer encoding:NSUTF8StringEncoding];
            if (remaining && remaining.length > 0 && cb) {
                cb(200, @{@"content-type": @"text/event-stream"}, remaining, NO, nil);
            }
            [self.byteBuffer setLength:0];
        }
        if (cb) {
            cb(200, @{@"content-type": @"text/event-stream"}, @"", YES, nil);
        }
    }

    [sess invalidateAndCancel];
}

@end

#pragma mark - Main Entry Point

void DPBYOKExecuteLLMRequest(NSString *endpoint, NSDictionary *headers, NSString *bodyString, NSString *agentSpec, DPBYOKStreamCallback callback) {
    // 1. Handle count-tokens
    if (endpoint && ([endpoint isEqualToString:@"count-tokens"] ||
                     [endpoint hasSuffix:@"count_tokens"] ||
                     [endpoint hasSuffix:@"count-tokens"])) {
        NSInteger length = bodyString ? (NSInteger)bodyString.length : 0;
        NSInteger estimatedTokens = MAX(1, length / 4);
        NSString *jsonBody = [NSString stringWithFormat:@"{\"input_tokens\":%ld}", (long)estimatedTokens];
        if (callback) {
            callback(200, @{@"content-type": @"application/json"}, jsonBody, YES, nil);
        }
        return;
    }

    // 2. Parse bodyString as JSON into a mutable dictionary
    NSData *bodyData = [bodyString dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jsonError = nil;
    id parsedJSON = bodyData ? [NSJSONSerialization JSONObjectWithData:bodyData options:NSJSONReadingMutableContainers error:&jsonError] : nil;

    if (![parsedJSON isKindOfClass:[NSDictionary class]] || jsonError != nil) {
        if (callback) {
            callback(400, @{@"content-type": @"application/json"}, nil, YES, @"Invalid JSON body in LLM_REQUEST");
        }
        return;
    }

    NSMutableDictionary *anthropicBody = [parsedJSON isKindOfClass:[NSMutableDictionary class]] ?
        (NSMutableDictionary *)parsedJSON : [parsedJSON mutableCopy];

    // 3. Read active BYOK settings
    NSString *spec = agentSpec ?: @"default";
    BOOL isBrief = ![spec isEqualToString:@"default"];
    NSString *provider = DPBYOKProvider();
    NSString *apiKey = DPBYOKApiKey(provider);
    NSString *modelId = nil;

    if (isBrief && (&DPBYOKBriefs != NULL && DPBYOKBriefs.on)) {
        if (&DPBYOKBriefsModel != NULL && DPBYOKBriefsModel.on) {
            modelId = DPBYOKBriefsModel(provider);
        }
        if (!modelId || [modelId isEqualToString:DPBYOKDiaDefaultModel] || modelId.length == 0) {
            modelId = DPBYOKDefaultModel(provider);
        }
    } else {
        modelId = DPBYOKActiveModel();
        if (!modelId || [modelId isEqualToString:DPBYOKDiaDefaultModel] || modelId.length == 0) {
            modelId = DPBYOKDefaultModel(provider);
        }
    }
    if (!modelId || [modelId isEqualToString:DPBYOKDiaDefaultModel] || modelId.length == 0) {
        NSArray<NSDictionary *> *models = DPBYOKFetchedModels(provider);
        if (models.count > 0) {
            modelId = models.firstObject[@"id"];
        }
    }
    NSString *thinkingLevel = DPBYOKThinkingLevel(provider, modelId);

    if (apiKey.length == 0 || modelId.length == 0) {
        NSString *err = @"event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"Missing API key or model for BYOK provider.\"}}\n\n";
        if (callback) {
            callback(200, @{@"content-type": @"text/event-stream"}, err, YES, nil);
        }
        return;
    }

    // 4. Provider Routing

    // Case 1: Google Gemini
    if ([provider isEqualToString:@"gemini"]) {
        DPBYOKExecuteGeminiRequest(anthropicBody, apiKey, modelId, thinkingLevel, callback);
        return;
    }

    // Case 2: OpenAI
    if ([provider isEqualToString:@"openai"]) {
        NSDictionary *openAIBody = DPBYOKTranslateAnthropicToOpenAI(anthropicBody, provider, modelId, thinkingLevel);
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.openai.com/v1/chat/completions"]];
        request.HTTPMethod = @"POST";
        request.timeoutInterval = 300.0;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

        NSError *err = nil;
        NSData *openAIData = [NSJSONSerialization dataWithJSONObject:openAIBody options:0 error:&err];
        if (!openAIData || err) {
            NSString *sseErr = DPBYOKAnthropicSSEError(@"Failed to serialize OpenAI request body.");
            if (callback) {
                callback(200, @{@"content-type": @"text/event-stream"}, sseErr, YES, nil);
            }
            return;
        }
        request.HTTPBody = openAIData;
        DPBYOKStreamOpenAIResponse(request, modelId, callback);
        return;
    }

    // Case 3: Anthropic / OpenRouter
    if ([provider isEqualToString:@"anthropic"] || [provider isEqualToString:@"openrouter"]) {
        NSMutableDictionary *body = [anthropicBody mutableCopy];
        body[@"model"] = modelId;
        body[@"stream"] = @YES;

        DPBYOKSanitizeAnthropicBody(body);

        // Omit thinking when tool_choice forces tool use (type == "tool" or type == "any")
        BOOL forcesToolUse = NO;
        id toolChoice = body[@"tool_choice"];
        if ([toolChoice isKindOfClass:[NSDictionary class]]) {
            NSString *tcType = toolChoice[@"type"];
            if ([tcType isEqualToString:@"tool"] || [tcType isEqualToString:@"any"] || toolChoice[@"name"]) {
                forcesToolUse = YES;
            }
        }

        NSArray<NSString *> *supportedThinkingLevels = DPBYOKThinkingLevelsForModel(provider, modelId);
        BOOL supportsThinking = (supportedThinkingLevels.count > 0);
        NSString *lowerModelId = [modelId lowercaseString];
        BOOL isAdaptiveModel = [lowerModelId containsString:@"4-6"] ||
                               [lowerModelId containsString:@"adaptive"] ||
                               [supportedThinkingLevels containsObject:@"adaptive"] ||
                               [thinkingLevel isEqualToString:@"adaptive"];

        if (supportsThinking && !forcesToolUse) {
            if ([thinkingLevel isEqualToString:@"off"]) {
                [body removeObjectForKey:@"thinking"];
                [body removeObjectForKey:@"output_config"];
                DPBYOKStripThinkingBlocksFromMessages(body);
                if (!body[@"max_tokens"] || [body[@"max_tokens"] integerValue] <= 0) {
                    body[@"max_tokens"] = @4096;
                }
            } else if (isAdaptiveModel) {
                NSString *effort = @"medium";
                if ([thinkingLevel isEqualToString:@"low"] || [thinkingLevel isEqualToString:@"minimal"]) {
                    effort = @"low";
                } else if ([thinkingLevel isEqualToString:@"high"] || [thinkingLevel isEqualToString:@"xhigh"] || [thinkingLevel isEqualToString:@"max"]) {
                    effort = @"high";
                } else if ([thinkingLevel isEqualToString:@"medium"]) {
                    effort = @"medium";
                }
                body[@"thinking"] = @{@"type": @"adaptive"};
                body[@"output_config"] = @{@"effort": effort};
                NSInteger currentMax = [body[@"max_tokens"] integerValue];
                NSInteger targetMax = MAX(currentMax, 16384);
                body[@"max_tokens"] = @(targetMax);
                [body removeObjectForKey:@"temperature"];
                [body removeObjectForKey:@"top_k"];
                [body removeObjectForKey:@"top_p"];
            } else {
                [body removeObjectForKey:@"output_config"];
                NSInteger budget = 8192;
                if ([thinkingLevel isEqualToString:@"minimal"]) {
                    budget = 1024;
                } else if ([thinkingLevel isEqualToString:@"low"]) {
                    budget = 2048;
                } else if ([thinkingLevel isEqualToString:@"medium"]) {
                    budget = 8192;
                } else if ([thinkingLevel isEqualToString:@"high"]) {
                    budget = 24576;
                } else if ([thinkingLevel isEqualToString:@"xhigh"] || [thinkingLevel isEqualToString:@"max"]) {
                    budget = 32000;
                } else {
                    NSInteger parsedInt = [thinkingLevel integerValue];
                    if (parsedInt > 0) {
                        budget = parsedInt;
                    }
                }

                NSInteger currentMax = [body[@"max_tokens"] integerValue];
                NSInteger targetMax = MAX(currentMax, budget + 8192);
                body[@"max_tokens"] = @(targetMax);
                body[@"thinking"] = @{
                    @"type": @"enabled",
                    @"budget_tokens": @(budget)
                };
                [body removeObjectForKey:@"temperature"];
                [body removeObjectForKey:@"top_k"];
                [body removeObjectForKey:@"top_p"];
            }
        } else {
            [body removeObjectForKey:@"thinking"];
            [body removeObjectForKey:@"output_config"];
            DPBYOKStripThinkingBlocksFromMessages(body);
            if (!body[@"max_tokens"] || [body[@"max_tokens"] integerValue] <= 0) {
                body[@"max_tokens"] = @4096;
            }
        }

        NSString *urlString = [provider isEqualToString:@"anthropic"] ?
            @"https://api.anthropic.com/v1/messages" :
            @"https://openrouter.ai/api/v1/messages";

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        request.HTTPMethod = @"POST";
        request.timeoutInterval = 300.0;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
        [request setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];

        if ([provider isEqualToString:@"anthropic"]) {
            [request setValue:apiKey forHTTPHeaderField:@"x-api-key"];

            NSString *incomingBeta = nil;
            for (NSString *k in headers) {
                if ([k caseInsensitiveCompare:@"anthropic-beta"] == NSOrderedSame) {
                    incomingBeta = headers[k];
                    break;
                }
            }
            if (incomingBeta && incomingBeta.length > 0) {
                NSArray *parts = [incomingBeta componentsSeparatedByString:@","];
                NSMutableArray *safeParts = [NSMutableArray array];
                for (NSString *part in parts) {
                    NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (trimmed.length == 0) continue;
                    NSString *lower = trimmed.lowercaseString;
                    if (![lower containsString:@"dia"] &&
                        ![lower containsString:@"internal"] &&
                        ![lower containsString:@"secret"]) {
                        [safeParts addObject:trimmed];
                    }
                }
                if (safeParts.count > 0) {
                    [request setValue:[safeParts componentsJoinedByString:@","] forHTTPHeaderField:@"anthropic-beta"];
                }
            }
        } else {
            [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
            [request setValue:@"https://diatweaks.app" forHTTPHeaderField:@"HTTP-Referer"];
            [request setValue:@"Dia" forHTTPHeaderField:@"X-Title"];
        }

        NSError *err = nil;
        NSData *bodyPayload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
        if (!bodyPayload || err) {
            NSString *sseErr = DPBYOKAnthropicSSEError(@"Failed to serialize Anthropic request body.");
            if (callback) {
                callback(200, @{@"content-type": @"text/event-stream"}, sseErr, YES, nil);
            }
            return;
        }
        request.HTTPBody = bodyPayload;

        DPBYOKAnthropicStreamDelegate *streamDelegate = [[DPBYOKAnthropicStreamDelegate alloc] initWithCallback:callback];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 300.0;
        config.timeoutIntervalForResource = 300.0;

        NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:streamDelegate delegateQueue:nil];
        streamDelegate.session = session;

        NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
        streamDelegate.task = task;
        [task resume];
        return;
    }

    // Fallback for unsupported provider
    NSString *unsupportedMsg = [NSString stringWithFormat:@"Unsupported BYOK provider: %@", provider];
    NSString *sseErr = DPBYOKAnthropicSSEError(unsupportedMsg);
    if (callback) {
        callback(200, @{@"content-type": @"text/event-stream"}, sseErr, YES, nil);
    }
}
