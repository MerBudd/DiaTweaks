#import "Patches/BYOK/BYOK.h"

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

static void DPBYOKSanitizeAnthropicBody(NSMutableDictionary *body) {
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
    }

    NSString *chunkStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!chunkStr || chunkStr.length == 0) return;

    BOOL hasStop = [chunkStr containsString:@"event: message_stop"] ||
                   [chunkStr containsString:@"\"type\":\"message_stop\""] ||
                   [chunkStr containsString:@"\"type\": \"message_stop\""] ||
                   [chunkStr containsString:@"message_stop"];

    if (hasStop) {
        DPBYOKStreamCallback cb = nil;
        @synchronized (self) {
            if (self.finished) return;
            self.finished = YES;
            cb = self.callback;
            self.callback = nil;
        }

        if (cb) {
            cb(200, @{@"content-type": @"text/event-stream"}, chunkStr, NO, nil);
            cb(200, @{@"content-type": @"text/event-stream"}, @"", YES, nil);
        }

        [dataTask cancel];
        NSURLSession *sess = self.session;
        self.session = nil;
        self.task = nil;
        [sess invalidateAndCancel];
    } else {
        DPBYOKStreamCallback cb = nil;
        @synchronized (self) {
            cb = self.callback;
        }
        if (cb) {
            cb(200, @{@"content-type": @"text/event-stream"}, chunkStr, NO, nil);
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
        if (cb) {
            cb(200, @{@"content-type": @"text/event-stream"}, @"", YES, nil);
        }
    }

    [sess invalidateAndCancel];
}

@end

#pragma mark - Main Entry Point

void DPBYOKExecuteLLMRequest(NSString *endpoint, NSDictionary *headers, NSString *bodyString, DPBYOKStreamCallback callback) {
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
    NSString *provider = DPBYOKProvider();
    NSString *apiKey = DPBYOKApiKey(provider);
    NSString *modelId = DPBYOKActiveModel();
    if (!modelId || [modelId isEqualToString:DPBYOKDiaDefaultModel] || modelId.length == 0) {
        modelId = DPBYOKDefaultModel(provider);
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

        NSArray<NSString *> *supportedThinkingLevels = DPBYOKThinkingLevelsForModel(provider, modelId);
        BOOL supportsThinking = (supportedThinkingLevels.count > 0);

        if (supportsThinking) {
            if ([thinkingLevel isEqualToString:@"off"]) {
                [body removeObjectForKey:@"thinking"];
                DPBYOKStripThinkingBlocksFromMessages(body);
                if (!body[@"max_tokens"] || [body[@"max_tokens"] integerValue] <= 0) {
                    body[@"max_tokens"] = @4096;
                }
            } else if ([thinkingLevel isEqualToString:@"adaptive"]) {
                body[@"thinking"] = @{@"type": @"adaptive"};
                NSInteger currentMax = [body[@"max_tokens"] integerValue];
                NSInteger targetMax = MAX(currentMax, 16384);
                body[@"max_tokens"] = @(targetMax);
                [body removeObjectForKey:@"temperature"];
                [body removeObjectForKey:@"top_k"];
                [body removeObjectForKey:@"top_p"];
            } else {
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
