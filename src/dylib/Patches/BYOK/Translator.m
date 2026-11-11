#import "Patches/BYOK/BYOK.h"

#pragma mark - SSE Error Formatter

static NSString *DPBYOKOpenAISSEError(NSString *message) {
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

static NSString *DPBYOKFormatSSEEvent(NSString *eventName, NSDictionary *dataDict) {
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dataDict options:0 error:nil];
    NSString *jsonStr = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : @"{}";
    return [NSString stringWithFormat:@"event: %@\ndata: %@\n\n", eventName, jsonStr];
}

#pragma mark - Anthropic to OpenAI Request Translation

NSDictionary *DPBYOKTranslateAnthropicToOpenAI(NSDictionary *anthropicBody, NSString *provider, NSString *modelId, NSString *thinkingLevel) {
    NSMutableDictionary *openAIBody = [NSMutableDictionary dictionary];

    // Determine reasoning model support
    NSString *lowerModelId = [modelId lowercaseString];
    NSArray<NSString *> *levels = DPBYOKThinkingLevelsForModel(provider, modelId);
    BOOL isReasoningModel = (levels.count > 0) ||
                            [lowerModelId hasPrefix:@"o1"] ||
                            [lowerModelId hasPrefix:@"o3"] ||
                            [lowerModelId hasPrefix:@"o4"] ||
                            [lowerModelId hasPrefix:@"gpt-5"] ||
                            [lowerModelId containsString:@"o1-"] ||
                            [lowerModelId containsString:@"o3-"] ||
                            [lowerModelId containsString:@"o4-"] ||
                            [lowerModelId containsString:@"gpt-5"];

    // 1. Basic configuration
    openAIBody[@"stream"] = @YES;
    openAIBody[@"stream_options"] = @{ @"include_usage": @YES };
    openAIBody[@"model"] = modelId ?: @"";

    id maxTokens = anthropicBody[@"max_tokens"];
    NSInteger requestedTokens = [maxTokens respondsToSelector:@selector(integerValue)] ? [maxTokens integerValue] : 8192;
    if (requestedTokens <= 0) requestedTokens = 8192;
    if (isReasoningModel) {
        openAIBody[@"max_completion_tokens"] = @(MAX(16384, requestedTokens));
    } else {
        openAIBody[@"max_completion_tokens"] = @(requestedTokens);
    }

    NSMutableArray *messages = [NSMutableArray array];

    // 2. System prompt
    id rawSystem = anthropicBody[@"system"];
    NSString *systemText = nil;
    if ([rawSystem isKindOfClass:[NSString class]]) {
        systemText = (NSString *)rawSystem;
    } else if ([rawSystem isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *systemParts = [NSMutableArray array];
        for (id block in (NSArray *)rawSystem) {
            if ([block isKindOfClass:[NSDictionary class]]) {
                NSString *bType = block[@"type"];
                if (!bType || [bType isEqualToString:@"text"]) {
                    NSString *bText = block[@"text"];
                    if ([bText isKindOfClass:[NSString class]] && bText.length > 0) {
                        [systemParts addObject:bText];
                    }
                }
            } else if ([block isKindOfClass:[NSString class]]) {
                if (((NSString *)block).length > 0) {
                    [systemParts addObject:(NSString *)block];
                }
            }
        }
        if (systemParts.count > 0) {
            systemText = [systemParts componentsJoinedByString:@"\n\n"];
        }
    }

    if (systemText && systemText.length > 0) {
        NSString *systemRole = isReasoningModel ? @"developer" : @"system";
        [messages addObject:@{
            @"role": systemRole,
            @"content": systemText
        }];
    }

    // 3. Messages conversion
    id rawMessages = anthropicBody[@"messages"];
    if ([rawMessages isKindOfClass:[NSArray class]]) {
        for (id msgObj in (NSArray *)rawMessages) {
            if (![msgObj isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *msg = (NSDictionary *)msgObj;
            NSString *role = msg[@"role"] ?: @"user";
            id content = msg[@"content"];

            if ([content isKindOfClass:[NSString class]]) {
                [messages addObject:@{
                    @"role": role,
                    @"content": content
                }];
                continue;
            }

            if ([content isKindOfClass:[NSArray class]]) {
                if ([role isEqualToString:@"user"]) {
                    // First, collect tool_result blocks
                    for (id blockObj in (NSArray *)content) {
                        if (![blockObj isKindOfClass:[NSDictionary class]]) continue;
                        NSDictionary *block = (NSDictionary *)blockObj;
                        if ([block[@"type"] isEqualToString:@"tool_result"]) {
                            NSString *toolUseId = block[@"tool_use_id"] ?: @"";
                            id resContent = block[@"content"];
                            NSString *resultText = @"";
                            if ([resContent isKindOfClass:[NSString class]]) {
                                resultText = (NSString *)resContent;
                            } else if ([resContent isKindOfClass:[NSArray class]]) {
                                NSMutableArray<NSString *> *textPieces = [NSMutableArray array];
                                for (id partObj in (NSArray *)resContent) {
                                    if ([partObj isKindOfClass:[NSDictionary class]]) {
                                        NSDictionary *part = (NSDictionary *)partObj;
                                        NSString *pType = part[@"type"];
                                        if ([pType isEqualToString:@"text"]) {
                                            NSString *t = part[@"text"];
                                            if (t) [textPieces addObject:t];
                                        } else if ([pType isEqualToString:@"image"]) {
                                            [textPieces addObject:@"[Image]"];
                                        }
                                    } else if ([partObj isKindOfClass:[NSString class]]) {
                                        [textPieces addObject:(NSString *)partObj];
                                    }
                                }
                                resultText = [textPieces componentsJoinedByString:@"\n"];
                            } else if (resContent) {
                                resultText = [resContent description];
                            }

                            [messages addObject:@{
                                @"role": @"tool",
                                @"tool_call_id": toolUseId,
                                @"content": resultText ?: @""
                            }];
                        }
                    }

                    // Next, collect remaining user blocks (text, image, document)
                    NSMutableArray *userParts = [NSMutableArray array];
                    for (id blockObj in (NSArray *)content) {
                        if (![blockObj isKindOfClass:[NSDictionary class]]) continue;
                        NSDictionary *block = (NSDictionary *)blockObj;
                        NSString *type = block[@"type"];

                        if ([type isEqualToString:@"tool_result"]) {
                            continue;
                        }

                        if ([type isEqualToString:@"text"]) {
                            NSString *txt = block[@"text"] ?: @"";
                            [userParts addObject:@{
                                @"type": @"text",
                                @"text": txt
                            }];
                        } else if ([type isEqualToString:@"image"]) {
                            NSDictionary *source = [block[@"source"] isKindOfClass:[NSDictionary class]] ? block[@"source"] : nil;
                            NSString *srcType = source[@"type"];
                            if ([srcType isEqualToString:@"base64"]) {
                                NSString *mediaType = source[@"media_type"] ?: @"image/jpeg";
                                NSString *dataStr = source[@"data"] ?: @"";
                                NSString *dataUrl = [NSString stringWithFormat:@"data:%@;base64,%@", mediaType, dataStr];
                                [userParts addObject:@{
                                    @"type": @"image_url",
                                    @"image_url": @{ @"url": dataUrl }
                                }];
                            } else if ([srcType isEqualToString:@"url"]) {
                                NSString *urlStr = source[@"url"] ?: @"";
                                [userParts addObject:@{
                                    @"type": @"image_url",
                                    @"image_url": @{ @"url": urlStr }
                                }];
                            }
                        } else if ([type isEqualToString:@"document"]) {
                            NSDictionary *source = [block[@"source"] isKindOfClass:[NSDictionary class]] ? block[@"source"] : nil;
                            NSString *srcType = source[@"type"];
                            NSString *mediaType = source[@"media_type"];
                            if ([mediaType isEqualToString:@"application/pdf"] && [srcType isEqualToString:@"base64"]) {
                                NSString *filename = block[@"title"] ?: @"document.pdf";
                                NSString *dataStr = source[@"data"] ?: @"";
                                NSString *dataUrl = [NSString stringWithFormat:@"data:application/pdf;base64,%@", dataStr];
                                [userParts addObject:@{
                                    @"type": @"file",
                                    @"file": @{
                                        @"filename": filename,
                                        @"file_data": dataUrl
                                    }
                                }];
                            } else if ([srcType isEqualToString:@"text"]) {
                                NSString *txtData = source[@"data"] ?: @"";
                                [userParts addObject:@{
                                    @"type": @"text",
                                    @"text": txtData
                                }];
                            }
                        }
                    }

                    if (userParts.count > 0) {
                        if (userParts.count == 1 && [userParts[0][@"type"] isEqualToString:@"text"]) {
                            [messages addObject:@{
                                @"role": @"user",
                                @"content": userParts[0][@"text"] ?: @""
                            }];
                        } else {
                            [messages addObject:@{
                                @"role": @"user",
                                @"content": userParts
                            }];
                        }
                    }
                } else if ([role isEqualToString:@"assistant"]) {
                    NSMutableString *assistantText = [NSMutableString string];
                    NSMutableArray *toolCalls = [NSMutableArray array];

                    for (id blockObj in (NSArray *)content) {
                        if (![blockObj isKindOfClass:[NSDictionary class]]) continue;
                        NSDictionary *block = (NSDictionary *)blockObj;
                        NSString *type = block[@"type"];

                        if ([type isEqualToString:@"text"]) {
                            NSString *t = block[@"text"];
                            if ([t isKindOfClass:[NSString class]] && t.length > 0) {
                                [assistantText appendString:t];
                            }
                        } else if ([type isEqualToString:@"tool_use"]) {
                            NSString *callId = block[@"id"] ?: @"call_1";
                            NSString *name = block[@"name"] ?: @"";
                            id inputObj = block[@"input"] ?: @{};
                            NSString *argsStr = @"{}";
                            if ([inputObj isKindOfClass:[NSString class]]) {
                                argsStr = (NSString *)inputObj;
                            } else if ([NSJSONSerialization isValidJSONObject:inputObj]) {
                                NSData *argsData = [NSJSONSerialization dataWithJSONObject:inputObj options:0 error:nil];
                                if (argsData) {
                                    argsStr = [[NSString alloc] initWithData:argsData encoding:NSUTF8StringEncoding] ?: @"{}";
                                }
                            }
                            [toolCalls addObject:@{
                                @"id": callId,
                                @"type": @"function",
                                @"function": @{
                                    @"name": name,
                                    @"arguments": argsStr
                                }
                            }];
                        }
                        // Ignore thinking / redacted_thinking blocks
                    }

                    NSMutableDictionary *assistantMsg = [NSMutableDictionary dictionaryWithObject:@"assistant" forKey:@"role"];
                    if (assistantText.length > 0) {
                        assistantMsg[@"content"] = assistantText;
                    } else {
                        assistantMsg[@"content"] = (toolCalls.count > 0) ? [NSNull null] : @"";
                    }
                    if (toolCalls.count > 0) {
                        assistantMsg[@"tool_calls"] = toolCalls;
                    }
                    [messages addObject:assistantMsg];
                }
            }
        }
    }
    // Validate assistant tool_calls matching tool responses
    NSMutableSet<NSString *> *availableToolResponses = [NSMutableSet set];
    for (NSDictionary *m in messages) {
        if ([m[@"role"] isEqualToString:@"tool"]) {
            NSString *callId = m[@"tool_call_id"];
            if ([callId isKindOfClass:[NSString class]] && callId.length > 0) {
                [availableToolResponses addObject:callId];
            }
        }
    }

    NSMutableSet<NSString *> *declaredToolCalls = [NSMutableSet set];
    for (NSDictionary *m in messages) {
        if ([m[@"role"] isEqualToString:@"assistant"]) {
            NSArray *tcs = m[@"tool_calls"];
            if ([tcs isKindOfClass:[NSArray class]]) {
                for (NSDictionary *tc in tcs) {
                    NSString *cid = tc[@"id"];
                    if ([cid isKindOfClass:[NSString class]] && cid.length > 0) {
                        [declaredToolCalls addObject:cid];
                    }
                }
            }
        }
    }

    NSMutableSet<NSString *> *validToolCallIds = [NSMutableSet setWithSet:declaredToolCalls];
    [validToolCallIds intersectSet:availableToolResponses];

    NSMutableArray *validatedMessages = [NSMutableArray arrayWithCapacity:messages.count];
    for (id mObj in messages) {
        if (![mObj isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *m = [mObj mutableCopy];
        NSString *role = m[@"role"];

        if ([role isEqualToString:@"tool"]) {
            NSString *callId = m[@"tool_call_id"];
            if (!callId || ![validToolCallIds containsObject:callId]) {
                // Strip orphaned tool response
                continue;
            }
            [validatedMessages addObject:m];
        } else if ([role isEqualToString:@"assistant"]) {
            NSArray *tcs = m[@"tool_calls"];
            if ([tcs isKindOfClass:[NSArray class]] && tcs.count > 0) {
                NSMutableArray *validTCs = [NSMutableArray array];
                for (NSDictionary *tc in tcs) {
                    NSString *cid = tc[@"id"];
                    if (cid && [validToolCallIds containsObject:cid]) {
                        [validTCs addObject:tc];
                    }
                }
                if (validTCs.count > 0) {
                    m[@"tool_calls"] = validTCs;
                } else {
                    [m removeObjectForKey:@"tool_calls"];
                    if (m[@"content"] == [NSNull null] || !m[@"content"] || ([m[@"content"] isKindOfClass:[NSString class]] && ((NSString *)m[@"content"]).length == 0)) {
                        m[@"content"] = @" ";
                    }
                }
            }
            [validatedMessages addObject:m];
        } else {
            [validatedMessages addObject:m];
        }
    }
    openAIBody[@"messages"] = validatedMessages;

    // 4. Tools conversion
    id toolsObj = anthropicBody[@"tools"];
    if ([toolsObj isKindOfClass:[NSArray class]] && ((NSArray *)toolsObj).count > 0) {
        NSMutableArray *openAITools = [NSMutableArray array];
        for (id toolObj in (NSArray *)toolsObj) {
            if (![toolObj isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *tool = (NSDictionary *)toolObj;
            NSMutableDictionary *funcDict = [NSMutableDictionary dictionary];
            funcDict[@"name"] = tool[@"name"] ?: @"";
            if (tool[@"description"]) {
                funcDict[@"description"] = tool[@"description"];
            }
            funcDict[@"parameters"] = tool[@"input_schema"] ?: @{ @"type": @"object", @"properties": @{} };
            [openAITools addObject:@{
                @"type": @"function",
                @"function": funcDict
            }];
        }
        if (openAITools.count > 0) {
            openAIBody[@"tools"] = openAITools;
        }
    }

    // 5. Tool choice conversion
    id toolChoice = anthropicBody[@"tool_choice"];
    if (toolChoice) {
        if ([toolChoice isKindOfClass:[NSString class]]) {
            NSString *tcStr = (NSString *)toolChoice;
            if ([tcStr isEqualToString:@"auto"]) {
                openAIBody[@"tool_choice"] = @"auto";
            } else if ([tcStr isEqualToString:@"any"]) {
                openAIBody[@"tool_choice"] = @"required";
            } else if ([tcStr isEqualToString:@"none"]) {
                openAIBody[@"tool_choice"] = @"none";
            } else {
                openAIBody[@"tool_choice"] = tcStr;
            }
        } else if ([toolChoice isKindOfClass:[NSDictionary class]]) {
            NSString *type = toolChoice[@"type"];
            if ([type isEqualToString:@"auto"]) {
                openAIBody[@"tool_choice"] = @"auto";
            } else if ([type isEqualToString:@"any"]) {
                openAIBody[@"tool_choice"] = @"required";
            } else if ([type isEqualToString:@"none"]) {
                openAIBody[@"tool_choice"] = @"none";
            } else if ([type isEqualToString:@"tool"]) {
                NSString *name = toolChoice[@"name"] ?: @"";
                openAIBody[@"tool_choice"] = @{
                    @"type": @"function",
                    @"function": @{ @"name": name }
                };
            } else if (toolChoice[@"name"]) {
                openAIBody[@"tool_choice"] = @{
                    @"type": @"function",
                    @"function": @{ @"name": toolChoice[@"name"] }
                };
            }
        }
    }

    // 6. Reasoning / Thinking level
    if (isReasoningModel && thinkingLevel.length > 0) {
        if ([thinkingLevel isEqualToString:@"off"]) {
            // Omit reasoning_effort on gpt-5* and when off (do not set to "none")
        } else if ([@"minimal" isEqualToString:thinkingLevel]) {
            openAIBody[@"reasoning_effort"] = @"low";
        } else {
            openAIBody[@"reasoning_effort"] = thinkingLevel;
        }
        // Omit temperature and top_p for reasoning models
    } else if (anthropicBody[@"temperature"] != nil) {
        if (!isReasoningModel) {
            openAIBody[@"temperature"] = anthropicBody[@"temperature"];
        }
    }

    return openAIBody;
}

#pragma mark - OpenAI Stream Delegate

typedef NS_ENUM(NSInteger, DPBYOKOpenAIBlockType) {
    DPBYOKOpenAIBlockTypeNone = 0,
    DPBYOKOpenAIBlockTypeThinking,
    DPBYOKOpenAIBlockTypeText,
    DPBYOKOpenAIBlockTypeToolUse
};

@interface DPBYOKOpenAIStreamDelegate : NSObject <NSURLSessionDataDelegate>

@property (nonatomic, copy) NSString *modelId;
@property (nonatomic, copy) DPBYOKStreamCallback callback;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong) NSMutableData *accumulatedErrorData;
@property (nonatomic, strong) NSMutableData *streamBuffer;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;

// Anthropic state machine
@property (nonatomic, assign) BOOL sentMessageStart;
@property (nonatomic, assign) DPBYOKOpenAIBlockType currentBlockType;
@property (nonatomic, assign) NSInteger currentBlockIndex;
@property (nonatomic, assign) BOOL hasOpenedToolCall;
@property (nonatomic, copy) NSString *rawFinishReason;
@property (nonatomic, assign) NSInteger outputTokens;
@property (nonatomic, assign) NSInteger inputTokens;

// Tool call streaming tracking
@property (nonatomic, assign) NSInteger lastToolCallIndex;
@property (nonatomic, copy) NSString *lastToolCallId;
@property (nonatomic, copy) NSString *lastToolCallName;

@end

@implementation DPBYOKOpenAIStreamDelegate

- (instancetype)initWithModelId:(NSString *)modelId callback:(DPBYOKStreamCallback)callback {
    self = [super init];
    if (self) {
        _modelId = [modelId copy];
        _callback = [callback copy];
        _accumulatedErrorData = [NSMutableData data];
        _streamBuffer = [NSMutableData data];
        _currentBlockType = DPBYOKOpenAIBlockTypeNone;
        _currentBlockIndex = -1;
        _lastToolCallIndex = -1;
        _outputTokens = 0;
        _inputTokens = 0;
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

        [self.streamBuffer appendData:data];
        [self processStreamBuffer];
    }
}

- (void)processStreamBuffer {
    const char *bytes = (const char *)self.streamBuffer.bytes;
    NSUInteger length = self.streamBuffer.length;
    NSUInteger lineStart = 0;

    for (NSUInteger i = 0; i < length; i++) {
        if (self.finished) return;

        if (bytes[i] == '\n') {
            NSUInteger lineLen = i - lineStart;
            if (lineLen > 0 && bytes[lineStart + lineLen - 1] == '\r') {
                lineLen--;
            }
            if (lineLen > 0) {
                NSData *lineData = [NSData dataWithBytesNoCopy:(void *)(bytes + lineStart) length:lineLen freeWhenDone:NO];
                NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
                if (line) {
                    [self processSSELine:line];
                }
            }
            lineStart = i + 1;
        }
    }

    if (lineStart > 0) {
        [self.streamBuffer replaceBytesInRange:NSMakeRange(0, lineStart) withBytes:NULL length:0];
    }
}

- (void)processSSELine:(NSString *)line {
    if (self.finished) return;
    if (line.length == 0) return;

    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([trimmed hasPrefix:@":"]) {
        return;
    }
    if (![trimmed hasPrefix:@"data:"]) {
        return;
    }

    NSString *payload = [trimmed substringFromIndex:5];
    payload = [payload stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if ([payload isEqualToString:@"[DONE]"]) {
        [self finishStreamNormally];
        return;
    }

    NSData *jsonData = [payload dataUsingEncoding:NSUTF8StringEncoding];
    if (!jsonData) return;

    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&err];
    if (err || ![parsed isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *chunk = (NSDictionary *)parsed;

    if (chunk[@"error"]) {
        id errObj = chunk[@"error"];
        NSString *errMsg = nil;
        if ([errObj isKindOfClass:[NSDictionary class]]) {
            errMsg = errObj[@"message"] ?: [errObj description];
        } else {
            errMsg = [errObj description];
        }
        [self handleStreamError:errMsg ?: @"OpenAI streaming error"];
        return;
    }

    id usageObj = chunk[@"usage"];
    if ([usageObj isKindOfClass:[NSDictionary class]]) {
        id completionTokens = usageObj[@"completion_tokens"];
        if ([completionTokens respondsToSelector:@selector(integerValue)]) {
            NSInteger ct = [completionTokens integerValue];
            if (ct > 0) {
                self.outputTokens = ct;
            }
        }
        id promptTokens = usageObj[@"prompt_tokens"];
        if ([promptTokens respondsToSelector:@selector(integerValue)]) {
            NSInteger pt = [promptTokens integerValue];
            if (pt > 0) {
                self.inputTokens = pt;
            }
        }
    }

    NSArray *choices = chunk[@"choices"];
    if (![choices isKindOfClass:[NSArray class]] || choices.count == 0) {
        return;
    }

    NSDictionary *choice = choices.firstObject;
    if (![choice isKindOfClass:[NSDictionary class]]) return;

    id rawFinish = choice[@"finish_reason"];
    if ([rawFinish isKindOfClass:[NSString class]] && ((NSString *)rawFinish).length > 0) {
        self.rawFinishReason = (NSString *)rawFinish;
    }

    NSDictionary *delta = choice[@"delta"];
    if (![delta isKindOfClass:[NSDictionary class]]) return;

    // 1. Thinking / Reasoning delta
    NSString *reasoningText = delta[@"reasoning_content"];
    if (![reasoningText isKindOfClass:[NSString class]] || reasoningText.length == 0) {
        reasoningText = delta[@"reasoning"];
    }
    if ([reasoningText isKindOfClass:[NSString class]] && reasoningText.length > 0) {
        [self ensureMessageStartSent];
        if (self.currentBlockType != DPBYOKOpenAIBlockTypeThinking) {
            [self closeCurrentBlockIfNeeded];
            self.currentBlockIndex++;
            self.currentBlockType = DPBYOKOpenAIBlockTypeThinking;
            NSDictionary *startDict = @{
                @"type": @"content_block_start",
                @"index": @(self.currentBlockIndex),
                @"content_block": @{
                    @"type": @"thinking",
                    @"thinking": @""
                }
            };
            [self emitEvent:@"content_block_start" data:startDict];
        }
        NSDictionary *deltaDict = @{
            @"type": @"content_block_delta",
            @"index": @(self.currentBlockIndex),
            @"delta": @{
                @"type": @"thinking_delta",
                @"thinking": reasoningText
            }
        };
        [self emitEvent:@"content_block_delta" data:deltaDict];
        self.outputTokens++;
    }

    // 2. Content delta
    id contentObj = delta[@"content"];
    if ([contentObj isKindOfClass:[NSString class]] && ((NSString *)contentObj).length > 0) {
        NSString *contentText = (NSString *)contentObj;
        [self ensureMessageStartSent];
        if (self.currentBlockType != DPBYOKOpenAIBlockTypeText) {
            [self closeCurrentBlockIfNeeded];
            self.currentBlockIndex++;
            self.currentBlockType = DPBYOKOpenAIBlockTypeText;
            NSDictionary *startDict = @{
                @"type": @"content_block_start",
                @"index": @(self.currentBlockIndex),
                @"content_block": @{
                    @"type": @"text",
                    @"text": @""
                }
            };
            [self emitEvent:@"content_block_start" data:startDict];
        }
        NSDictionary *deltaDict = @{
            @"type": @"content_block_delta",
            @"index": @(self.currentBlockIndex),
            @"delta": @{
                @"type": @"text_delta",
                @"text": contentText
            }
        };
        [self emitEvent:@"content_block_delta" data:deltaDict];
        self.outputTokens++;
    }

    // 3. Tool calls delta
    NSArray *toolCalls = delta[@"tool_calls"];
    if ([toolCalls isKindOfClass:[NSArray class]]) {
        for (id tcObj in toolCalls) {
            if (![tcObj isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *tc = (NSDictionary *)tcObj;
            NSNumber *toolIndex = tc[@"index"];
            NSString *callId = tc[@"id"];
            NSDictionary *func = [tc[@"function"] isKindOfClass:[NSDictionary class]] ? tc[@"function"] : nil;
            NSString *funcName = func[@"name"];

            BOOL isNewToolCall = NO;
            if (callId.length > 0) {
                if (!self.lastToolCallId || ![callId isEqualToString:self.lastToolCallId]) {
                    isNewToolCall = YES;
                }
            } else if (funcName.length > 0) {
                if (self.currentBlockType != DPBYOKOpenAIBlockTypeToolUse ||
                    (toolIndex && [toolIndex integerValue] != self.lastToolCallIndex)) {
                    isNewToolCall = YES;
                }
            }

            if (isNewToolCall) {
                [self ensureMessageStartSent];
                [self closeCurrentBlockIfNeeded];
                self.currentBlockIndex++;
                self.currentBlockType = DPBYOKOpenAIBlockTypeToolUse;
                self.hasOpenedToolCall = YES;

                if (!callId || callId.length == 0) {
                    callId = [NSString stringWithFormat:@"call_%ld", (long)(self.currentBlockIndex + 1)];
                }
                self.lastToolCallId = callId;
                self.lastToolCallName = funcName ?: @"";
                if (toolIndex) self.lastToolCallIndex = [toolIndex integerValue];

                NSDictionary *startDict = @{
                    @"type": @"content_block_start",
                    @"index": @(self.currentBlockIndex),
                    @"content_block": @{
                        @"type": @"tool_use",
                        @"id": callId,
                        @"name": funcName ?: @"",
                        @"input": @{}
                    }
                };
                [self emitEvent:@"content_block_start" data:startDict];
            }

            NSString *argsFragment = func[@"arguments"];
            if ([argsFragment isKindOfClass:[NSString class]] && argsFragment.length > 0) {
                NSDictionary *deltaDict = @{
                    @"type": @"content_block_delta",
                    @"index": @(self.currentBlockIndex),
                    @"delta": @{
                        @"type": @"input_json_delta",
                        @"partial_json": argsFragment
                    }
                };
                [self emitEvent:@"content_block_delta" data:deltaDict];
                self.outputTokens++;
            }
        }
    }
}

- (void)ensureMessageStartSent {
    if (!self.sentMessageStart) {
        self.sentMessageStart = YES;
        NSString *msgId = [NSString stringWithFormat:@"msg_byok_%@", [[NSUUID UUID] UUIDString]];
        NSDictionary *startDict = @{
            @"type": @"message_start",
            @"message": @{
                @"id": msgId,
                @"type": @"message",
                @"role": @"assistant",
                @"content": @[],
                @"model": self.modelId ?: @"openai",
                @"stop_reason": [NSNull null],
                @"stop_sequence": [NSNull null],
                @"usage": @{ @"input_tokens": @1, @"output_tokens": @1 }
            }
        };
        [self emitEvent:@"message_start" data:startDict];
    }
}

- (void)closeCurrentBlockIfNeeded {
    [self closeCurrentBlockIfNeededWithBuffer:nil];
}

- (void)closeCurrentBlockIfNeededWithBuffer:(NSMutableString *)buffer {
    if (self.currentBlockType != DPBYOKOpenAIBlockTypeNone && self.currentBlockIndex >= 0) {
        NSDictionary *stopDict = @{
            @"type": @"content_block_stop",
            @"index": @(self.currentBlockIndex)
        };
        NSString *eventStr = DPBYOKFormatSSEEvent(@"content_block_stop", stopDict);
        if (buffer) {
            [buffer appendString:eventStr];
        } else {
            [self emitRawSSE:eventStr];
        }
        self.currentBlockType = DPBYOKOpenAIBlockTypeNone;
    }
}

- (NSString *)mappedStopReason {
    if (self.hasOpenedToolCall) {
        if (!self.rawFinishReason ||
            [self.rawFinishReason isEqualToString:@"stop"] ||
            [self.rawFinishReason isEqualToString:@"tool_calls"]) {
            return @"tool_use";
        }
    }
    if ([self.rawFinishReason isEqualToString:@"tool_calls"]) {
        return @"tool_use";
    }
    if ([self.rawFinishReason isEqualToString:@"length"]) {
        return @"max_tokens";
    }
    if ([self.rawFinishReason isEqualToString:@"stop"]) {
        return @"end_turn";
    }
    return @"end_turn";
}

- (void)emitEvent:(NSString *)name data:(NSDictionary *)data {
    NSString *eventStr = DPBYOKFormatSSEEvent(name, data);
    [self emitRawSSE:eventStr];
}

- (void)emitRawSSE:(NSString *)sseText {
    DPBYOKStreamCallback cb = nil;
    @synchronized (self) {
        if (self.finished) return;
        cb = self.callback;
    }
    if (cb) {
        cb(200, @{@"content-type": @"text/event-stream"}, sseText, NO, nil);
    }
}

- (void)handleStreamError:(NSString *)errMsg {
    DPBYOKStreamCallback cb = nil;
    @synchronized (self) {
        if (self.finished) return;
        self.finished = YES;
        cb = self.callback;
        self.callback = nil;
    }
    if (!cb) return;

    if (!self.sentMessageStart) {
        NSString *sseErr = DPBYOKOpenAISSEError(errMsg);
        cb(200, @{@"content-type": @"text/event-stream"}, sseErr, YES, nil);
    } else {
        NSMutableString *errSSE = [NSMutableString string];
        [self closeCurrentBlockIfNeededWithBuffer:errSSE];
        self.currentBlockIndex++;
        self.currentBlockType = DPBYOKOpenAIBlockTypeText;

        NSDictionary *startDict = @{
            @"type": @"content_block_start",
            @"index": @(self.currentBlockIndex),
            @"content_block": @{
                @"type": @"text",
                @"text": @""
            }
        };
        [errSSE appendString:DPBYOKFormatSSEEvent(@"content_block_start", startDict)];

        NSString *prefixed = [NSString stringWithFormat:@"\n\n⚠️ BYOK Error: %@", errMsg ?: @"Unknown error"];
        NSDictionary *deltaDict = @{
            @"type": @"content_block_delta",
            @"index": @(self.currentBlockIndex),
            @"delta": @{
                @"type": @"text_delta",
                @"text": prefixed
            }
        };
        [errSSE appendString:DPBYOKFormatSSEEvent(@"content_block_delta", deltaDict)];

        NSDictionary *stopDict = @{
            @"type": @"content_block_stop",
            @"index": @(self.currentBlockIndex)
        };
        [errSSE appendString:DPBYOKFormatSSEEvent(@"content_block_stop", stopDict)];

        NSDictionary *msgDeltaDict = @{
            @"type": @"message_delta",
            @"delta": @{
                @"stop_reason": @"end_turn",
                @"stop_sequence": [NSNull null]
            },
            @"usage": @{ @"output_tokens": @(MAX(1, self.outputTokens)) }
        };
        [errSSE appendString:DPBYOKFormatSSEEvent(@"message_delta", msgDeltaDict)];
        [errSSE appendString:@"event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"];

        cb(200, @{@"content-type": @"text/event-stream"}, errSSE, NO, nil);
        cb(200, @{@"content-type": @"text/event-stream"}, @"", YES, nil);
    }

    [self.task cancel];
    NSURLSession *sess = self.session;
    self.session = nil;
    self.task = nil;
    [sess invalidateAndCancel];
}

- (void)finishStreamNormally {
    DPBYOKStreamCallback cb = nil;
    @synchronized (self) {
        if (self.finished) return;
        self.finished = YES;
        cb = self.callback;
        self.callback = nil;
    }
    if (!cb) return;

    NSMutableString *finalSSE = [NSMutableString string];

    if (!self.sentMessageStart) {
        self.sentMessageStart = YES;
        NSString *msgId = [NSString stringWithFormat:@"msg_byok_%@", [[NSUUID UUID] UUIDString]];
        NSDictionary *startDict = @{
            @"type": @"message_start",
            @"message": @{
                @"id": msgId,
                @"type": @"message",
                @"role": @"assistant",
                @"content": @[],
                @"model": self.modelId ?: @"openai",
                @"stop_reason": [NSNull null],
                @"stop_sequence": [NSNull null],
                @"usage": @{ @"input_tokens": @1, @"output_tokens": @1 }
            }
        };
        [finalSSE appendString:DPBYOKFormatSSEEvent(@"message_start", startDict)];

        self.currentBlockIndex++;
        NSDictionary *blockStart = @{
            @"type": @"content_block_start",
            @"index": @(self.currentBlockIndex),
            @"content_block": @{
                @"type": @"text",
                @"text": @""
            }
        };
        [finalSSE appendString:DPBYOKFormatSSEEvent(@"content_block_start", blockStart)];

        NSDictionary *blockStop = @{
            @"type": @"content_block_stop",
            @"index": @(self.currentBlockIndex)
        };
        [finalSSE appendString:DPBYOKFormatSSEEvent(@"content_block_stop", blockStop)];
        self.currentBlockType = DPBYOKOpenAIBlockTypeNone;
    } else {
        [self closeCurrentBlockIfNeededWithBuffer:finalSSE];
    }

    NSString *stopReason = [self mappedStopReason];
    NSMutableDictionary *usageDict = [NSMutableDictionary dictionary];
    usageDict[@"output_tokens"] = @(MAX(1, self.outputTokens));
    if (self.inputTokens > 0) {
        usageDict[@"input_tokens"] = @(self.inputTokens);
    }
    NSDictionary *msgDeltaDict = @{
        @"type": @"message_delta",
        @"delta": @{
            @"stop_reason": stopReason,
            @"stop_sequence": [NSNull null]
        },
        @"usage": usageDict
    };
    [finalSSE appendString:DPBYOKFormatSSEEvent(@"message_delta", msgDeltaDict)];
    [finalSSE appendString:@"event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"];

    cb(200, @{@"content-type": @"text/event-stream"}, finalSSE, NO, nil);
    cb(200, @{@"content-type": @"text/event-stream"}, @"", YES, nil);

    [self.task cancel];
    NSURLSession *sess = self.session;
    self.session = nil;
    self.task = nil;
    [sess invalidateAndCancel];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    @synchronized (self) {
        if (self.finished) {
            NSURLSession *sess = self.session ?: session;
            self.session = nil;
            self.task = nil;
            [sess invalidateAndCancel];
            return;
        }
    }

    if (self.statusCode >= 400) {
        NSString *errMsg = nil;
        if (self.accumulatedErrorData.length > 0) {
            id parsed = [NSJSONSerialization JSONObjectWithData:self.accumulatedErrorData options:0 error:nil];
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
                errMsg = [[NSString alloc] initWithData:self.accumulatedErrorData encoding:NSUTF8StringEncoding];
            }
        }
        if (!errMsg || errMsg.length == 0) {
            errMsg = [NSString stringWithFormat:@"HTTP error %ld", (long)self.statusCode];
        }
        [self handleStreamError:errMsg];
    } else if (error && error.code != NSURLErrorCancelled) {
        [self handleStreamError:error.localizedDescription];
    } else {
        if (self.streamBuffer.length > 0) {
            NSString *remaining = [[NSString alloc] initWithData:self.streamBuffer encoding:NSUTF8StringEncoding];
            if (remaining && remaining.length > 0) {
                [self processSSELine:remaining];
            }
            [self.streamBuffer setLength:0];
        }
        [self finishStreamNormally];
    }
}

@end

#pragma mark - OpenAI Stream Entry Point

void DPBYOKStreamOpenAIResponse(NSURLRequest *request, NSString *modelId, DPBYOKStreamCallback callback) {
    DPBYOKOpenAIStreamDelegate *streamDelegate = [[DPBYOKOpenAIStreamDelegate alloc] initWithModelId:modelId callback:callback];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 300.0;
    config.timeoutIntervalForResource = 300.0;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:streamDelegate delegateQueue:nil];
    streamDelegate.session = session;

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    streamDelegate.task = task;
    [task resume];
}
