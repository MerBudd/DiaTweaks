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

#pragma mark - Tool Schema Sanitization

static id DPBYOKSanitizeGeminiSchema(id schema) {
    if (![schema isKindOfClass:[NSDictionary class]]) {
        if ([schema isKindOfClass:[NSArray class]]) {
            NSMutableArray *arr = [NSMutableArray arrayWithCapacity:[schema count]];
            for (id item in (NSArray *)schema) {
                [arr addObject:DPBYOKSanitizeGeminiSchema(item)];
            }
            return arr;
        }
        return schema;
    }

    NSDictionary *dict = (NSDictionary *)schema;
    NSMutableDictionary *sanitized = [NSMutableDictionary dictionaryWithCapacity:dict.count];

    static NSSet<NSString *> *strippedKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        strippedKeys = [NSSet setWithObjects:
            @"$schema",
            @"additionalProperties",
            @"default",
            @"examples",
            @"title",
            @"propertyNames",
            @"const",
            nil
        ];
    });

    // 1. Handle "type" array (e.g. ["string", "null"])
    id typeVal = dict[@"type"];
    BOOL isNullable = NO;
    if ([typeVal isKindOfClass:[NSArray class]]) {
        NSString *chosenType = nil;
        for (id t in (NSArray *)typeVal) {
            if ([t isKindOfClass:[NSString class]]) {
                if ([t isEqualToString:@"null"]) {
                    isNullable = YES;
                } else if (!chosenType) {
                    chosenType = t;
                }
            }
        }
        if (chosenType) {
            sanitized[@"type"] = chosenType;
        }
        if (isNullable) {
            sanitized[@"nullable"] = @YES;
        }
    } else if (typeVal) {
        sanitized[@"type"] = typeVal;
    }

    // 2. Check "properties"
    id propsObj = dict[@"properties"];
    BOOL hasEmptyProperties = NO;
    if ([propsObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *propsDict = (NSDictionary *)propsObj;
        if (propsDict.count == 0) {
            hasEmptyProperties = YES;
        } else {
            NSMutableDictionary *sanitizedProps = [NSMutableDictionary dictionaryWithCapacity:propsDict.count];
            for (NSString *key in propsDict) {
                sanitizedProps[key] = DPBYOKSanitizeGeminiSchema(propsDict[key]);
            }
            sanitized[@"properties"] = sanitizedProps;
        }
    }

    // 3. Process remaining keys
    for (NSString *key in dict) {
        if ([strippedKeys containsObject:key]) {
            continue;
        }
        if ([key isEqualToString:@"type"]) {
            continue;
        }
        if ([key isEqualToString:@"properties"]) {
            continue;
        }
        if ([key isEqualToString:@"required"]) {
            if (hasEmptyProperties) {
                continue;
            }
            sanitized[@"required"] = dict[@"required"];
            continue;
        }
        if ([key isEqualToString:@"items"]) {
            sanitized[@"items"] = DPBYOKSanitizeGeminiSchema(dict[@"items"]);
            continue;
        }
        id val = dict[key];
        if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
            sanitized[key] = DPBYOKSanitizeGeminiSchema(val);
        } else {
            sanitized[key] = val;
        }
    }

    if (sanitized[@"required"] && (!sanitized[@"properties"] || [sanitized[@"properties"] count] == 0)) {
        [sanitized removeObjectForKey:@"required"];
    }

    return sanitized;
}

#pragma mark - Gemini Stream Delegate

typedef NS_ENUM(NSInteger, DPBYOKBlockType) {
    DPBYOKBlockTypeNone = 0,
    DPBYOKBlockTypeThinking,
    DPBYOKBlockTypeText
};

@interface DPBYOKGeminiStreamDelegate : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, copy) DPBYOKStreamCallback callback;
@property (nonatomic, copy) NSString *modelId;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong) NSMutableData *accumulatedErrorData;
@property (nonatomic, strong) NSMutableString *lineBuffer;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL messageStartEmitted;
@property (nonatomic, assign) NSInteger currentBlockIndex;
@property (nonatomic, assign) DPBYOKBlockType openBlockType;
@property (nonatomic, assign) NSInteger toolCounter;
@property (nonatomic, assign) BOOL sawToolCall;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation DPBYOKGeminiStreamDelegate

- (instancetype)initWithModelId:(NSString *)modelId callback:(DPBYOKStreamCallback)callback {
    self = [super init];
    if (self) {
        _modelId = [modelId copy];
        _callback = [callback copy];
        _accumulatedErrorData = [NSMutableData data];
        _lineBuffer = [NSMutableString string];
        _currentBlockIndex = 0;
        _openBlockType = DPBYOKBlockTypeNone;
        _toolCounter = 0;
        _sawToolCall = NO;
        _messageStartEmitted = NO;
        _finished = NO;
    }
    return self;
}

- (void)cleanupSession {
    NSURLSession *sess = nil;
    NSURLSessionDataTask *t = nil;
    @synchronized (self) {
        sess = self.session;
        t = self.task;
        self.session = nil;
        self.task = nil;
    }
    [t cancel];
    [sess invalidateAndCancel];
}

- (void)emitChunk:(NSString *)chunk {
    if (!chunk || chunk.length == 0) return;
    DPBYOKStreamCallback cb = nil;
    @synchronized (self) {
        if (self.finished) return;
        cb = self.callback;
    }
    if (cb) {
        cb(200, @{@"content-type": @"text/event-stream"}, chunk, NO, nil);
    }
}

- (void)closeCurrentBlock {
    if (_openBlockType == DPBYOKBlockTypeNone) return;
    NSString *stopEvent = [NSString stringWithFormat:
        @"event: content_block_stop\n"
        @"data: {\"type\":\"content_block_stop\",\"index\":%ld}\n\n",
        (long)_currentBlockIndex];
    [self emitChunk:stopEvent];
    _currentBlockIndex++;
    _openBlockType = DPBYOKBlockTypeNone;
}

- (void)finishStream {
    DPBYOKStreamCallback cb = nil;
    NSString *closingEvent = nil;
    BOOL wasStartEmitted = NO;
    NSInteger blockIdx = 0;
    BOOL sawTool = NO;
    NSString *model = nil;

    @synchronized (self) {
        if (self.finished) return;
        self.finished = YES;
        cb = self.callback;
        self.callback = nil;

        wasStartEmitted = self.messageStartEmitted;
        self.messageStartEmitted = YES;
        blockIdx = self.currentBlockIndex;
        sawTool = self.sawToolCall;
        model = self.modelId;

        if (self.openBlockType != DPBYOKBlockTypeNone) {
            closingEvent = [NSString stringWithFormat:
                @"event: content_block_stop\n"
                @"data: {\"type\":\"content_block_stop\",\"index\":%ld}\n\n",
                (long)blockIdx];
            self.currentBlockIndex++;
            self.openBlockType = DPBYOKBlockTypeNone;
        }
    }

    if (!cb) return;

    if (!wasStartEmitted) {
        NSString *startMsg = [NSString stringWithFormat:
            @"event: message_start\n"
            @"data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_gemini_%lu\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"%@\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n",
            (unsigned long)([[NSDate date] timeIntervalSince1970] * 1000),
            model ?: @"gemini"];
        cb(200, @{@"content-type": @"text/event-stream"}, startMsg, NO, nil);
    }

    if (closingEvent) {
        cb(200, @{@"content-type": @"text/event-stream"}, closingEvent, NO, nil);
    }

    NSString *stopReason = sawTool ? @"tool_use" : @"end_turn";
    NSString *endEvents = [NSString stringWithFormat:
        @"event: message_delta\n"
        @"data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"%@\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":1}}\n\n"
        @"event: message_stop\n"
        @"data: {\"type\":\"message_stop\"}\n\n",
        stopReason];
    cb(200, @{@"content-type": @"text/event-stream"}, endEvents, NO, nil);
    cb(200, @{@"content-type": @"text/event-stream"}, @"", YES, nil);

    [self cleanupSession];
}

- (void)failWithError:(NSString *)message {
    DPBYOKStreamCallback cb = nil;
    BOOL wasStartEmitted = NO;
    NSInteger blockIdx = 0;
    NSString *closingEvent = nil;

    @synchronized (self) {
        if (self.finished) return;
        self.finished = YES;
        cb = self.callback;
        self.callback = nil;

        wasStartEmitted = self.messageStartEmitted;
        self.messageStartEmitted = YES;
        blockIdx = self.currentBlockIndex;

        if (self.openBlockType != DPBYOKBlockTypeNone) {
            closingEvent = [NSString stringWithFormat:
                @"event: content_block_stop\n"
                @"data: {\"type\":\"content_block_stop\",\"index\":%ld}\n\n",
                (long)blockIdx];
            self.currentBlockIndex++;
            blockIdx = self.currentBlockIndex;
            self.openBlockType = DPBYOKBlockTypeNone;
        }
    }

    if (!cb) return;

    NSString *errMsg = message ?: @"Unknown error";

    if (!wasStartEmitted) {
        NSString *sseErr = DPBYOKAnthropicSSEError(errMsg);
        cb(200, @{@"content-type": @"text/event-stream"}, sseErr, YES, nil);
    } else {
        if (closingEvent) {
            cb(200, @{@"content-type": @"text/event-stream"}, closingEvent, NO, nil);
        }

        NSString *prefixed = [NSString stringWithFormat:@"\n\n⚠️ BYOK Error: %@", errMsg];
        NSString *startText = [NSString stringWithFormat:
            @"event: content_block_start\n"
            @"data: {\"type\":\"content_block_start\",\"index\":%ld,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
            (long)blockIdx];
        cb(200, @{@"content-type": @"text/event-stream"}, startText, NO, nil);

        NSDictionary *deltaObj = @{
            @"type": @"content_block_delta",
            @"index": @(blockIdx),
            @"delta": @{
                @"type": @"text_delta",
                @"text": prefixed
            }
        };
        NSData *deltaData = [NSJSONSerialization dataWithJSONObject:deltaObj options:0 error:nil];
        NSString *deltaJSON = deltaData ? [[NSString alloc] initWithData:deltaData encoding:NSUTF8StringEncoding] : @"{}";
        cb(200, @{@"content-type": @"text/event-stream"}, [NSString stringWithFormat:@"event: content_block_delta\ndata: %@\n\n", deltaJSON], NO, nil);

        NSString *stopText = [NSString stringWithFormat:
            @"event: content_block_stop\n"
            @"data: {\"type\":\"content_block_stop\",\"index\":%ld}\n\n",
            (long)blockIdx];
        cb(200, @{@"content-type": @"text/event-stream"}, stopText, NO, nil);

        NSString *endEvents = @"event: message_delta\n"
            @"data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":1}}\n\n"
            @"event: message_stop\n"
            @"data: {\"type\":\"message_stop\"}\n\n";
        cb(200, @{@"content-type": @"text/event-stream"}, endEvents, NO, nil);
        cb(200, @{@"content-type": @"text/event-stream"}, @"", YES, nil);
    }

    [self cleanupSession];
}

- (void)processJSONString:(NSString *)jsonStr {
    if (!jsonStr || jsonStr.length == 0) return;
    if ([jsonStr isEqualToString:@"[DONE]"]) {
        [self finishStream];
        return;
    }

    NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *dict = (NSDictionary *)parsed;

    if (dict[@"error"]) {
        NSString *errMsg = nil;
        id errObj = dict[@"error"];
        if ([errObj isKindOfClass:[NSDictionary class]] && errObj[@"message"]) {
            errMsg = [errObj[@"message"] description];
        } else {
            errMsg = [errObj description];
        }
        [self failWithError:errMsg];
        return;
    }

    NSArray *candidates = dict[@"candidates"];
    if (![candidates isKindOfClass:[NSArray class]] || candidates.count == 0) {
        NSDictionary *pf = dict[@"promptFeedback"];
        if ([pf isKindOfClass:[NSDictionary class]] && pf[@"blockReason"]) {
            [self failWithError:[NSString stringWithFormat:@"Prompt blocked by safety filter: %@", pf[@"blockReason"]]];
            return;
        }
        return;
    }

    NSDictionary *candidate = candidates.firstObject;
    if (![candidate isKindOfClass:[NSDictionary class]]) return;

    if (!_messageStartEmitted) {
        _messageStartEmitted = YES;
        NSString *startMsg = [NSString stringWithFormat:
            @"event: message_start\n"
            @"data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_gemini_%lu\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"%@\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n",
            (unsigned long)([[NSDate date] timeIntervalSince1970] * 1000),
            _modelId ?: @"gemini"];
        [self emitChunk:startMsg];
    }

    NSDictionary *content = candidate[@"content"];
    if ([content isKindOfClass:[NSDictionary class]]) {
        NSArray *parts = content[@"parts"];
        if ([parts isKindOfClass:[NSArray class]]) {
            for (id partObj in parts) {
                if (![partObj isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *part = (NSDictionary *)partObj;

                if ([part[@"thought"] boolValue] && [part[@"text"] isKindOfClass:[NSString class]]) {
                    NSString *thoughtText = part[@"text"];
                    if (thoughtText.length > 0) {
                        if (_openBlockType == DPBYOKBlockTypeText) {
                            [self closeCurrentBlock];
                        }
                        if (_openBlockType == DPBYOKBlockTypeNone) {
                            _openBlockType = DPBYOKBlockTypeThinking;
                            NSString *start = [NSString stringWithFormat:
                                @"event: content_block_start\n"
                                @"data: {\"type\":\"content_block_start\",\"index\":%ld,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n",
                                (long)_currentBlockIndex];
                            [self emitChunk:start];
                        }
                        NSDictionary *deltaObj = @{
                            @"type": @"content_block_delta",
                            @"index": @(_currentBlockIndex),
                            @"delta": @{
                                @"type": @"thinking_delta",
                                @"thinking": thoughtText
                            }
                        };
                        NSData *deltaData = [NSJSONSerialization dataWithJSONObject:deltaObj options:0 error:nil];
                        NSString *deltaJSON = deltaData ? [[NSString alloc] initWithData:deltaData encoding:NSUTF8StringEncoding] : @"{}";
                        [self emitChunk:[NSString stringWithFormat:@"event: content_block_delta\ndata: %@\n\n", deltaJSON]];
                    }
                } else if (![part[@"thought"] boolValue] && [part[@"text"] isKindOfClass:[NSString class]]) {
                    NSString *text = part[@"text"];
                    if (text.length > 0) {
                        if (_openBlockType == DPBYOKBlockTypeThinking) {
                            [self closeCurrentBlock];
                        }
                        if (_openBlockType == DPBYOKBlockTypeNone) {
                            _openBlockType = DPBYOKBlockTypeText;
                            NSString *start = [NSString stringWithFormat:
                                @"event: content_block_start\n"
                                @"data: {\"type\":\"content_block_start\",\"index\":%ld,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
                                (long)_currentBlockIndex];
                            [self emitChunk:start];
                        }
                        NSDictionary *deltaObj = @{
                            @"type": @"content_block_delta",
                            @"index": @(_currentBlockIndex),
                            @"delta": @{
                                @"type": @"text_delta",
                                @"text": text
                            }
                        };
                        NSData *deltaData = [NSJSONSerialization dataWithJSONObject:deltaObj options:0 error:nil];
                        NSString *deltaJSON = deltaData ? [[NSString alloc] initWithData:deltaData encoding:NSUTF8StringEncoding] : @"{}";
                        [self emitChunk:[NSString stringWithFormat:@"event: content_block_delta\ndata: %@\n\n", deltaJSON]];
                    }
                } else if (part[@"functionCall"]) {
                    NSDictionary *fc = part[@"functionCall"];
                    if ([fc isKindOfClass:[NSDictionary class]]) {
                        if (_openBlockType != DPBYOKBlockTypeNone) {
                            [self closeCurrentBlock];
                        }
                        NSString *funcName = fc[@"name"] ?: @"";
                        NSDictionary *args = [fc[@"args"] isKindOfClass:[NSDictionary class]] ? fc[@"args"] : @{};

                        _toolCounter++;
                        NSString *callId = [NSString stringWithFormat:@"toolu_gemini_%ld", (long)_toolCounter];
                        id sigObj = part[@"thoughtSignature"];
                        if ([sigObj isKindOfClass:[NSString class]] && ((NSString *)sigObj).length > 0) {
                            callId = [NSString stringWithFormat:@"%@__sig__%@", callId, sigObj];
                        }

                        NSData *argsData = [NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
                        NSString *argsJson = argsData ? [[NSString alloc] initWithData:argsData encoding:NSUTF8StringEncoding] : @"{}";

                        NSDictionary *startBlock = @{
                            @"type": @"tool_use",
                            @"id": callId,
                            @"name": funcName,
                            @"input": @{}
                        };
                        NSDictionary *startObj = @{
                            @"type": @"content_block_start",
                            @"index": @(_currentBlockIndex),
                            @"content_block": startBlock
                        };
                        NSData *startData = [NSJSONSerialization dataWithJSONObject:startObj options:0 error:nil];
                        NSString *startJSON = startData ? [[NSString alloc] initWithData:startData encoding:NSUTF8StringEncoding] : @"{}";
                        [self emitChunk:[NSString stringWithFormat:@"event: content_block_start\ndata: %@\n\n", startJSON]];

                        NSDictionary *deltaObj = @{
                            @"type": @"content_block_delta",
                            @"index": @(_currentBlockIndex),
                            @"delta": @{
                                @"type": @"input_json_delta",
                                @"partial_json": argsJson
                            }
                        };
                        NSData *deltaData = [NSJSONSerialization dataWithJSONObject:deltaObj options:0 error:nil];
                        NSString *deltaJSON = deltaData ? [[NSString alloc] initWithData:deltaData encoding:NSUTF8StringEncoding] : @"{}";
                        [self emitChunk:[NSString stringWithFormat:@"event: content_block_delta\ndata: %@\n\n", deltaJSON]];

                        NSDictionary *stopObj = @{
                            @"type": @"content_block_stop",
                            @"index": @(_currentBlockIndex)
                        };
                        NSData *stopData = [NSJSONSerialization dataWithJSONObject:stopObj options:0 error:nil];
                        NSString *stopJSON = stopData ? [[NSString alloc] initWithData:stopData encoding:NSUTF8StringEncoding] : @"{}";
                        [self emitChunk:[NSString stringWithFormat:@"event: content_block_stop\ndata: %@\n\n", stopJSON]];

                        _currentBlockIndex++;
                        _sawToolCall = YES;
                    }
                }
            }
        }
    }

    NSString *finishReason = candidate[@"finishReason"];
    if ([finishReason isKindOfClass:[NSString class]] && finishReason.length > 0) {
        [self finishStream];
    }
}

- (void)processLineBuffer {
    NSMutableArray<NSString *> *linesToProcess = [NSMutableArray array];
    @synchronized (self) {
        NSRange range = [self.lineBuffer rangeOfString:@"\n"];
        while (range.location != NSNotFound) {
            NSString *line = [self.lineBuffer substringToIndex:range.location];
            [self.lineBuffer deleteCharactersInRange:NSMakeRange(0, range.location + 1)];
            [linesToProcess addObject:line];
            range = [self.lineBuffer rangeOfString:@"\n"];
        }
    }

    for (NSString *rawLine in linesToProcess) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r"]];
        if ([line hasPrefix:@"data: "]) {
            NSString *jsonStr = [line substringFromIndex:6];
            [self processJSONString:jsonStr];
        } else if ([line hasPrefix:@"data:"]) {
            NSString *jsonStr = [line substringFromIndex:5];
            [self processJSONString:jsonStr];
        }
    }
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

    @synchronized (self) {
        [self.lineBuffer appendString:chunkStr];
    }

    [self processLineBuffer];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    @synchronized (self) {
        if (self.finished) {
            [self cleanupSession];
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
                }
            }
            if (!errMsg || errMsg.length == 0) {
                errMsg = [[NSString alloc] initWithData:self.accumulatedErrorData encoding:NSUTF8StringEncoding];
            }
        }
        if (!errMsg || errMsg.length == 0) {
            errMsg = [NSString stringWithFormat:@"HTTP error %ld", (long)self.statusCode];
        }
        [self failWithError:errMsg];
        return;
    }

    if (error && error.code != NSURLErrorCancelled) {
        [self failWithError:error.localizedDescription];
        return;
    }

    NSString *remaining = nil;
    @synchronized (self) {
        if (self.lineBuffer.length > 0) {
            remaining = [self.lineBuffer copy];
            [self.lineBuffer setString:@""];
        }
    }
    if (remaining.length > 0) {
        NSArray<NSString *> *lines = [remaining componentsSeparatedByString:@"\n"];
        for (NSString *rawLine in lines) {
            NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r"]];
            if ([line hasPrefix:@"data: "]) {
                [self processJSONString:[line substringFromIndex:6]];
            } else if ([line hasPrefix:@"data:"]) {
                [self processJSONString:[line substringFromIndex:5]];
            }
        }
    }

    [self finishStream];
}

@end

#pragma mark - Main Entry Point

void DPBYOKExecuteGeminiRequest(NSDictionary *anthropicBody, NSString *apiKey, NSString *modelId, NSString *thinkingLevel, DPBYOKStreamCallback callback) {
    if (![anthropicBody isKindOfClass:[NSDictionary class]]) {
        NSString *err = DPBYOKAnthropicSSEError(@"Invalid Anthropic request body.");
        if (callback) {
            callback(200, @{@"content-type": @"text/event-stream"}, err, YES, nil);
        }
        return;
    }

    if (!apiKey || apiKey.length == 0) {
        NSString *err = DPBYOKAnthropicSSEError(@"Missing Gemini API key.");
        if (callback) {
            callback(200, @{@"content-type": @"text/event-stream"}, err, YES, nil);
        }
        return;
    }

    NSString *cleanModelId = modelId;
    if ([cleanModelId hasPrefix:@"models/"]) {
        cleanModelId = [cleanModelId substringFromIndex:7];
    }
    if (!cleanModelId || cleanModelId.length == 0) {
        cleanModelId = @"gemini-2.5-flash";
    }

    NSMutableDictionary *geminiBody = [NSMutableDictionary dictionary];

    // 1. System Instruction
    id systemObj = anthropicBody[@"system"];
    NSMutableString *systemText = [NSMutableString string];
    if ([systemObj isKindOfClass:[NSString class]]) {
        [systemText appendString:(NSString *)systemObj];
    } else if ([systemObj isKindOfClass:[NSArray class]]) {
        for (id block in (NSArray *)systemObj) {
            if ([block isKindOfClass:[NSDictionary class]] && [block[@"text"] isKindOfClass:[NSString class]]) {
                if (systemText.length > 0) [systemText appendString:@"\n\n"];
                [systemText appendString:block[@"text"]];
            } else if ([block isKindOfClass:[NSString class]]) {
                if (systemText.length > 0) [systemText appendString:@"\n\n"];
                [systemText appendString:block];
            }
        }
    }
    if (systemText.length > 0) {
        geminiBody[@"systemInstruction"] = @{
            @"parts": @[@{@"text": systemText}]
        };
    }

    // 2. Tools & Schema Sanitization
    id toolsObj = anthropicBody[@"tools"];
    if ([toolsObj isKindOfClass:[NSArray class]] && ((NSArray *)toolsObj).count > 0) {
        NSMutableArray *declarations = [NSMutableArray array];
        for (id toolItem in (NSArray *)toolsObj) {
            if (![toolItem isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = toolItem[@"name"];
            if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;

            NSMutableDictionary *decl = [NSMutableDictionary dictionary];
            decl[@"name"] = name;
            if ([toolItem[@"description"] isKindOfClass:[NSString class]] && ((NSString *)toolItem[@"description"]).length > 0) {
                decl[@"description"] = toolItem[@"description"];
            }
            id inputSchema = toolItem[@"input_schema"];
            if ([inputSchema isKindOfClass:[NSDictionary class]]) {
                decl[@"parameters"] = DPBYOKSanitizeGeminiSchema(inputSchema);
            }
            [declarations addObject:decl];
        }
        if (declarations.count > 0) {
            geminiBody[@"tools"] = @[@{@"functionDeclarations": declarations}];
        }
    }

    // 3. Messages Translation (contents)
    NSArray *messages = anthropicBody[@"messages"];
    if (![messages isKindOfClass:[NSArray class]]) {
        messages = @[];
    }

    NSMutableDictionary<NSString *, NSString *> *toolIdToName = [NSMutableDictionary dictionary];
    for (id msgObj in messages) {
        if (![msgObj isKindOfClass:[NSDictionary class]]) continue;
        id content = msgObj[@"content"];
        if ([content isKindOfClass:[NSArray class]]) {
            for (id blockObj in (NSArray *)content) {
                if ([blockObj isKindOfClass:[NSDictionary class]] && [blockObj[@"type"] isEqualToString:@"tool_use"]) {
                    NSString *tid = blockObj[@"id"];
                    NSString *tname = blockObj[@"name"];
                    if (tid && tname) {
                        toolIdToName[tid] = tname;
                        NSRange sigPos = [tid rangeOfString:@"__sig__"];
                        if (sigPos.location != NSNotFound) {
                            NSString *baseId = [tid substringToIndex:sigPos.location];
                            if (baseId.length > 0) {
                                toolIdToName[baseId] = tname;
                            }
                        }
                    }
                }
            }
        }
    }

    NSMutableArray<NSMutableDictionary *> *contents = [NSMutableArray array];

    for (id msgObj in messages) {
        if (![msgObj isKindOfClass:[NSDictionary class]]) continue;
        NSString *role = msgObj[@"role"];
        NSString *geminiRole = [role isEqualToString:@"assistant"] ? @"model" : @"user";
        NSMutableArray *parts = [NSMutableArray array];
        id content = msgObj[@"content"];

        if ([content isKindOfClass:[NSString class]]) {
            NSString *str = (NSString *)content;
            if (str.length > 0) {
                [parts addObject:@{@"text": str}];
            }
        } else if ([content isKindOfClass:[NSArray class]]) {
            for (id blockObj in (NSArray *)content) {
                if (![blockObj isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *block = (NSDictionary *)blockObj;
                NSString *type = block[@"type"];

                if ([geminiRole isEqualToString:@"user"]) {
                    if ([type isEqualToString:@"text"]) {
                        NSString *text = block[@"text"];
                        if ([text isKindOfClass:[NSString class]] && text.length > 0) {
                            [parts addObject:@{@"text": text}];
                        }
                    } else if ([type isEqualToString:@"image"]) {
                        NSDictionary *source = block[@"source"];
                        if ([source isKindOfClass:[NSDictionary class]]) {
                            NSString *mediaType = source[@"media_type"] ?: @"image/jpeg";
                            NSString *data = source[@"data"];
                            if ([data isKindOfClass:[NSString class]] && data.length > 0) {
                                [parts addObject:@{@"inlineData": @{@"mimeType": mediaType, @"data": data}}];
                            }
                        }
                    } else if ([type isEqualToString:@"document"]) {
                        NSDictionary *source = block[@"source"];
                        if ([source isKindOfClass:[NSDictionary class]]) {
                            NSString *mediaType = source[@"media_type"] ?: @"";
                            NSString *sourceType = source[@"type"] ?: @"";
                            NSString *data = source[@"data"];
                            if ([data isKindOfClass:[NSString class]] && data.length > 0) {
                                if ([mediaType isEqualToString:@"application/pdf"] || [sourceType isEqualToString:@"base64"]) {
                                    [parts addObject:@{@"inlineData": @{@"mimeType": mediaType.length > 0 ? mediaType : @"application/pdf", @"data": data}}];
                                } else if ([sourceType isEqualToString:@"text"] || [mediaType hasPrefix:@"text/"]) {
                                    [parts addObject:@{@"text": data}];
                                } else {
                                    [parts addObject:@{@"inlineData": @{@"mimeType": mediaType.length > 0 ? mediaType : @"application/octet-stream", @"data": data}}];
                                }
                            }
                        }
                    } else if ([type isEqualToString:@"tool_result"]) {
                        NSString *toolUseId = block[@"tool_use_id"] ?: @"";
                        NSString *cleanId = toolUseId;
                        NSRange sigPos = [toolUseId rangeOfString:@"__sig__"];
                        if (sigPos.location != NSNotFound) {
                            cleanId = [toolUseId substringToIndex:sigPos.location];
                        }
                        NSString *funcName = toolIdToName[cleanId] ?: toolIdToName[toolUseId];
                        if (!funcName || funcName.length == 0) {
                            funcName = cleanId.length > 0 ? cleanId : toolUseId;
                        }

                        NSMutableString *resultText = [NSMutableString string];
                        NSMutableArray *nestedImageParts = [NSMutableArray array];

                        id resultContent = block[@"content"];
                        if ([resultContent isKindOfClass:[NSString class]]) {
                            [resultText appendString:resultContent];
                        } else if ([resultContent isKindOfClass:[NSArray class]]) {
                            for (id nested in (NSArray *)resultContent) {
                                if ([nested isKindOfClass:[NSString class]]) {
                                    if (resultText.length > 0) [resultText appendString:@"\n"];
                                    [resultText appendString:nested];
                                } else if ([nested isKindOfClass:[NSDictionary class]]) {
                                    NSString *nType = nested[@"type"];
                                    if ([nType isEqualToString:@"text"] && [nested[@"text"] isKindOfClass:[NSString class]]) {
                                        if (resultText.length > 0) [resultText appendString:@"\n"];
                                        [resultText appendString:nested[@"text"]];
                                    } else if ([nType isEqualToString:@"image"]) {
                                        NSDictionary *nSource = nested[@"source"];
                                        if ([nSource isKindOfClass:[NSDictionary class]]) {
                                            NSString *nMime = nSource[@"media_type"] ?: @"image/jpeg";
                                            NSString *nData = nSource[@"data"];
                                            if ([nData isKindOfClass:[NSString class]] && nData.length > 0) {
                                                [nestedImageParts addObject:@{
                                                    @"inlineData": @{
                                                        @"mimeType": nMime,
                                                        @"data": nData
                                                    }
                                                }];
                                            }
                                        }
                                    }
                                }
                            }
                        } else if (resultContent != nil) {
                            NSData *cd = [NSJSONSerialization dataWithJSONObject:resultContent options:0 error:nil];
                            if (cd) {
                                NSString *cs = [[NSString alloc] initWithData:cd encoding:NSUTF8StringEncoding];
                                if (cs) [resultText appendString:cs];
                            }
                        }

                        if (resultText.length == 0 && [block[@"output"] isKindOfClass:[NSString class]]) {
                            [resultText appendString:block[@"output"]];
                        }

                        NSDictionary *respPart = @{
                            @"functionResponse": @{
                                @"name": funcName ?: @"",
                                @"response": @{
                                    @"result": (NSString *)resultText ?: @""
                                }
                            }
                        };
                        [parts addObject:respPart];
                        if (nestedImageParts.count > 0) {
                            [parts addObjectsFromArray:nestedImageParts];
                        }
                    }
                } else {
                    // Assistant / Model role
                    if ([type isEqualToString:@"text"]) {
                        NSString *text = block[@"text"];
                        if ([text isKindOfClass:[NSString class]] && text.length > 0) {
                            [parts addObject:@{@"text": text}];
                        }
                    } else if ([type isEqualToString:@"tool_use"]) {
                        NSString *name = block[@"name"] ?: @"";
                        NSDictionary *input = [block[@"input"] isKindOfClass:[NSDictionary class]] ? block[@"input"] : @{};
                        NSString *callId = block[@"id"];

                        NSMutableDictionary *fcPart = [NSMutableDictionary dictionary];
                        fcPart[@"functionCall"] = @{
                            @"name": name,
                            @"args": input
                        };

                        if ([callId isKindOfClass:[NSString class]] && [callId containsString:@"__sig__"]) {
                            NSArray *comps = [callId componentsSeparatedByString:@"__sig__"];
                            if (comps.count > 1) {
                                NSString *sig = comps[1];
                                if (sig.length > 0) {
                                    fcPart[@"thoughtSignature"] = sig;
                                }
                            }
                        }
                        [parts addObject:fcPart];
                    }
                }
            }
        }

        if (parts.count > 0) {
            if (contents.count > 0 && [contents.lastObject[@"role"] isEqualToString:geminiRole]) {
                NSMutableArray *prevParts = contents.lastObject[@"parts"];
                [prevParts addObjectsFromArray:parts];
            } else {
                [contents addObject:[@{
                    @"role": geminiRole,
                    @"parts": [parts mutableCopy]
                } mutableCopy]];
            }
        }
    }

    if (contents.count == 0) {
        [contents addObject:[@{
            @"role": @"user",
            @"parts": [NSMutableArray arrayWithObject:@{@"text": @"..."}]
        } mutableCopy]];
    } else if ([contents.firstObject[@"role"] isEqualToString:@"model"]) {
        [contents insertObject:[@{
            @"role": @"user",
            @"parts": [NSMutableArray arrayWithObject:@{@"text": @"..."}]
        } mutableCopy] atIndex:0];
    }

    geminiBody[@"contents"] = contents;

    // 4. Generation Config & Thinking Config
    NSMutableDictionary *genConfig = [NSMutableDictionary dictionary];
    genConfig[@"maxOutputTokens"] = anthropicBody[@"max_tokens"] ?: @8192;

    if (anthropicBody[@"temperature"]) {
        genConfig[@"temperature"] = anthropicBody[@"temperature"];
    }
    if (anthropicBody[@"top_p"]) {
        genConfig[@"topP"] = anthropicBody[@"top_p"];
    }
    if (anthropicBody[@"top_k"]) {
        genConfig[@"topK"] = anthropicBody[@"top_k"];
    }
    if (anthropicBody[@"stop_sequences"]) {
        genConfig[@"stopSequences"] = anthropicBody[@"stop_sequences"];
    }

    NSArray<NSString *> *levels = DPBYOKThinkingLevelsForModel(@"gemini", cleanModelId);
    NSString *lowerModelId = [cleanModelId lowercaseString];
    BOOL hasThinkingSupport = (levels.count > 0) ||
                              [lowerModelId containsString:@"gemini-2.5"] ||
                              [lowerModelId containsString:@"gemini-3"] ||
                              [lowerModelId containsString:@"thinking"];

    if (hasThinkingSupport && thinkingLevel.length > 0) {
        NSString *lowerLevel = [thinkingLevel lowercaseString];

        if ([lowerModelId containsString:@"gemini-3"]) {
            if ([lowerLevel isEqualToString:@"off"]) {
                genConfig[@"thinkingConfig"] = @{@"thinkingLevel": @"MINIMAL"};
            } else {
                NSString *mappedLevel = @"HIGH";
                if ([lowerLevel isEqualToString:@"minimal"]) {
                    mappedLevel = @"MINIMAL";
                } else if ([lowerLevel isEqualToString:@"low"]) {
                    mappedLevel = @"LOW";
                } else if ([lowerLevel isEqualToString:@"medium"]) {
                    mappedLevel = @"MEDIUM";
                } else if ([lowerLevel isEqualToString:@"high"]) {
                    mappedLevel = @"HIGH";
                }
                genConfig[@"thinkingConfig"] = @{
                    @"includeThoughts": @YES,
                    @"thinkingLevel": mappedLevel
                };
            }
        } else {
            // Gemini 2.5
            if ([lowerLevel isEqualToString:@"off"]) {
                genConfig[@"thinkingConfig"] = @{@"thinkingBudget": @0};
            } else {
                NSNumber *budget = @8192;
                if ([lowerLevel isEqualToString:@"minimal"]) {
                    budget = @512;
                } else if ([lowerLevel isEqualToString:@"low"]) {
                    budget = @1024;
                } else if ([lowerLevel isEqualToString:@"medium"]) {
                    budget = @8192;
                } else if ([lowerLevel isEqualToString:@"high"]) {
                    budget = @24576;
                } else {
                    NSInteger parsedInt = [lowerLevel integerValue];
                    if (parsedInt > 0) {
                        budget = @(parsedInt);
                    }
                }
                genConfig[@"thinkingConfig"] = @{
                    @"includeThoughts": @YES,
                    @"thinkingBudget": budget
                };
            }
        }
    }

    geminiBody[@"generationConfig"] = genConfig;

    // 5. Build and Send Request
    NSString *escapedModelId = [cleanModelId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"https://generativelanguage.googleapis.com/v1beta/models/%@:streamGenerateContent?alt=sse", escapedModelId];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSString *err = DPBYOKAnthropicSSEError([NSString stringWithFormat:@"Invalid Gemini model endpoint URL for model: %@", cleanModelId]);
        if (callback) {
            callback(200, @{@"content-type": @"text/event-stream"}, err, YES, nil);
        }
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 300.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    [request setValue:apiKey forHTTPHeaderField:@"x-goog-api-key"];

    NSError *serializeError = nil;
    NSData *bodyPayload = [NSJSONSerialization dataWithJSONObject:geminiBody options:0 error:&serializeError];
    if (!bodyPayload || serializeError) {
        NSString *err = DPBYOKAnthropicSSEError(@"Failed to serialize Gemini request body.");
        if (callback) {
            callback(200, @{@"content-type": @"text/event-stream"}, err, YES, nil);
        }
        return;
    }
    request.HTTPBody = bodyPayload;

    DPBYOKGeminiStreamDelegate *streamDelegate = [[DPBYOKGeminiStreamDelegate alloc] initWithModelId:cleanModelId callback:callback];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 300.0;
    config.timeoutIntervalForResource = 300.0;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:streamDelegate delegateQueue:nil];
    streamDelegate.session = session;

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    streamDelegate.task = task;
    [task resume];
}
