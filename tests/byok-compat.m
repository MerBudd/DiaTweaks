#import <Foundation/Foundation.h>
#import "Patches/BYOK/BYOK.h"

// Minimal link-time stubs for symbols referenced by State.m / Keychain.m / Router.m outside the tested functions.
DPPatch DPBYOK, DPBYOKBriefs, DPBYOKBriefsModel, DPTurnOffAI;
NSString *DPAppSupport(NSString *path) { (void)path; return nil; }
void DPUpdateAllBYOKPickers(void) {}

// Prototypes for functions under test
extern id DPBYOKSanitizeGeminiSchema(id schema);
extern void DPBYOKSanitizeAnthropicBody(NSMutableDictionary *body);
extern NSDictionary *DPBYOKTranslateAnthropicToOpenAI(NSDictionary *anthropicBody, NSString *provider, NSString *modelId, NSString *thinkingLevel);

@interface DPBYOKAnthropicStreamDelegate : NSObject <NSURLSessionDataDelegate>
- (instancetype)initWithCallback:(DPBYOKStreamCallback)callback;
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data;
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error;
@end

@interface DPBYOKGeminiStreamDelegate : NSObject <NSURLSessionDataDelegate>
- (instancetype)initWithModelId:(NSString *)modelId callback:(DPBYOKStreamCallback)callback;
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data;
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error;
@end

static int testsPassed = 0;
static int testsFailed = 0;

#define ASSERT(expr, msg) do { \
    if (!(expr)) { \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); \
        testsFailed++; \
    } else { \
        testsPassed++; \
    } \
} while(0)

int main(void) {
    @autoreleasepool {
        printf("--- Running Milestone 4 Compatibility Unit Tests ---\n");

        // ============================================================
        // Test 1: Gemini Schema $defs / $ref inlining
        // ============================================================
        {
            NSDictionary *schemaWithDefs = @{
                @"type": @"object",
                @"properties": @{
                    @"target": @{
                        @"$ref": @"#/$defs/TargetNode"
                    }
                },
                @"$defs": @{
                    @"TargetNode": @{
                        @"type": @"string",
                        @"description": @"The target identifier"
                    }
                }
            };

            id sanitized = DPBYOKSanitizeGeminiSchema(schemaWithDefs);
            ASSERT([sanitized isKindOfClass:[NSDictionary class]], "Sanitized schema should be a dictionary");
            NSDictionary *dict = (NSDictionary *)sanitized;
            ASSERT(dict[@"$defs"] == nil, "Top-level $defs must be stripped from sanitized schema");
            ASSERT([dict[@"type"] isEqualToString:@"object"], "Schema type should be object");
            NSDictionary *props = dict[@"properties"];
            ASSERT(props != nil, "Properties should exist");
            NSDictionary *targetProp = props[@"target"];
            ASSERT([targetProp isKindOfClass:[NSDictionary class]], "Target property should be inlined");
            ASSERT([targetProp[@"type"] isEqualToString:@"string"], "Inlined TargetNode type should be string");
            ASSERT([targetProp[@"description"] isEqualToString:@"The target identifier"], "Inlined description preserved");
            ASSERT(targetProp[@"$ref"] == nil, "$ref should be replaced with inlined content");
        }

        // Test 1b: definitions prefix (#/definitions/)
        {
            NSDictionary *schemaWithDefinitions = @{
                @"type": @"object",
                @"properties": @{
                    @"user": @{
                        @"$ref": @"#/definitions/UserProfile"
                    }
                },
                @"definitions": @{
                    @"UserProfile": @{
                        @"type": @"object",
                        @"properties": @{
                            @"username": @{ @"type": @"string" }
                        }
                    }
                }
            };

            id sanitized = DPBYOKSanitizeGeminiSchema(schemaWithDefinitions);
            NSDictionary *dict = (NSDictionary *)sanitized;
            ASSERT(dict[@"definitions"] == nil, "Top-level definitions must be stripped");
            NSDictionary *props = dict[@"properties"];
            NSDictionary *userProp = props[@"user"];
            ASSERT([userProp isKindOfClass:[NSDictionary class]], "UserProfile should be inlined");
            ASSERT([userProp[@"type"] isEqualToString:@"object"], "Inlined UserProfile type should be object");
            ASSERT(userProp[@"properties"][@"username"] != nil, "Nested username property inlined");
        }

        // Test 1c: Recursive cycle guard
        {
            NSDictionary *cyclicSchema = @{
                @"type": @"object",
                @"properties": @{
                    @"node": @{ @"$ref": @"#/$defs/Node" }
                },
                @"$defs": @{
                    @"Node": @{
                        @"type": @"object",
                        @"properties": @{
                            @"value": @{ @"type": @"string" },
                            @"next": @{ @"$ref": @"#/$defs/Node" }
                        }
                    }
                }
            };

            id sanitized = DPBYOKSanitizeGeminiSchema(cyclicSchema);
            ASSERT(sanitized != nil, "Cyclic schema must resolve safely without crash or infinite recursion");
            NSDictionary *dict = (NSDictionary *)sanitized;
            NSDictionary *nodeProp = dict[@"properties"][@"node"];
            ASSERT(nodeProp != nil, "Node property resolved");
            NSDictionary *nextProp = nodeProp[@"properties"][@"next"];
            ASSERT(nextProp != nil, "Self-referential next property guarded");
            ASSERT([nextProp[@"type"] isEqualToString:@"object"], "Cycle broke into safe object");
        }

        // ============================================================
        // Test 2: OpenAI Compatibility
        // ============================================================
        // Test 2a: Reasoning model (o1, gpt-5) max_completion_tokens floor >= 16384 & role developer
        {
            NSDictionary *anthropicBody = @{
                @"model": @"o1-preview",
                @"max_tokens": @1000,
                @"system": @"You are a reasoning assistant.",
                @"messages": @[
                    @{ @"role": @"user", @"content": @"Hello" }
                ]
            };

            NSDictionary *openAIBody = DPBYOKTranslateAnthropicToOpenAI(anthropicBody, @"openai", @"o1-preview", @"medium");
            ASSERT(openAIBody != nil, "OpenAI translation returned non-nil");
            ASSERT([openAIBody[@"stream_options"][@"include_usage"] boolValue] == YES, "Usage streaming enabled");
            ASSERT([openAIBody[@"max_completion_tokens"] integerValue] >= 16384, "max_completion_tokens floored to >= 16384 on reasoning model");

            NSArray *msgs = openAIBody[@"messages"];
            ASSERT(msgs.count == 2, "2 messages translated");
            ASSERT([msgs[0][@"role"] isEqualToString:@"developer"], "Role should be 'developer' instead of 'system' for reasoning models");
            ASSERT([msgs[0][@"content"] isEqualToString:@"You are a reasoning assistant."], "Developer message content preserved");
        }

        // Test 2b: Standard model (gpt-4o) retains role system and normal max_completion_tokens
        {
            NSDictionary *anthropicBody = @{
                @"model": @"gpt-4o",
                @"max_tokens": @4096,
                @"system": @"You are a helpful assistant.",
                @"messages": @[
                    @{ @"role": @"user", @"content": @"Hi" }
                ]
            };

            NSDictionary *openAIBody = DPBYOKTranslateAnthropicToOpenAI(anthropicBody, @"openai", @"gpt-4o", @"off");
            ASSERT([openAIBody[@"max_completion_tokens"] integerValue] == 4096, "Non-reasoning model keeps requested max_completion_tokens");
            NSArray *msgs = openAIBody[@"messages"];
            ASSERT([msgs[0][@"role"] isEqualToString:@"system"], "Role should be 'system' for standard models");
        }

        // Test 2c: gpt-5 reasoning_effort omitted when thinkingLevel is "off"
        {
            NSDictionary *anthropicBody = @{
                @"model": @"gpt-5",
                @"max_tokens": @4096,
                @"messages": @[
                    @{ @"role": @"user", @"content": @"Test" }
                ]
            };

            NSDictionary *openAIBody = DPBYOKTranslateAnthropicToOpenAI(anthropicBody, @"openai", @"gpt-5", @"off");
            ASSERT(openAIBody[@"reasoning_effort"] == nil, "reasoning_effort must be omitted when off on gpt-5 (not set to 'none')");
        }

        // Test 2d: Tool call & response validation (strip orphaned tool calls and responses)
        {
            NSDictionary *anthropicBody = @{
                @"model": @"gpt-4o",
                @"max_tokens": @4096,
                @"messages": @[
                    @{
                        @"role": @"assistant",
                        @"content": @[
                            @{
                                @"type": @"tool_use",
                                @"id": @"call_1",
                                @"name": @"search",
                                @"input": @{ @"query": @"apple" }
                            },
                            @{
                                @"type": @"tool_use",
                                @"id": @"call_2",
                                @"name": @"weather",
                                @"input": @{ @"city": @"Cupertino" }
                            }
                        ]
                    },
                    @{
                        @"role": @"user",
                        @"content": @[
                            @{
                                @"type": @"tool_result",
                                @"tool_use_id": @"call_1",
                                @"content": @"AAPL results"
                            },
                            @{
                                @"type": @"tool_result",
                                @"tool_use_id": @"call_999", // Orphaned
                                @"content": @"Ghost result"
                            }
                        ]
                    }
                ]
            };

            NSDictionary *openAIBody = DPBYOKTranslateAnthropicToOpenAI(anthropicBody, @"openai", @"gpt-4o", @"off");
            NSArray *msgs = openAIBody[@"messages"];
            
            // Check assistant message
            NSDictionary *asstMsg = msgs[0];
            ASSERT([asstMsg[@"role"] isEqualToString:@"assistant"], "First message is assistant");
            NSArray *tcs = asstMsg[@"tool_calls"];
            ASSERT(tcs.count == 1, "Only paired tool_call (call_1) should remain, unresponded call_2 stripped");
            ASSERT([tcs[0][@"id"] isEqualToString:@"call_1"], "Remaining tool call is call_1");

            // Check tool messages
            BOOL sawCall1 = NO;
            BOOL sawCall999 = NO;
            for (NSDictionary *m in msgs) {
                if ([m[@"role"] isEqualToString:@"tool"]) {
                    if ([m[@"tool_call_id"] isEqualToString:@"call_1"]) sawCall1 = YES;
                    if ([m[@"tool_call_id"] isEqualToString:@"call_999"]) sawCall999 = YES;
                }
            }
            ASSERT(sawCall1 == YES, "Paired tool response for call_1 preserved");
            ASSERT(sawCall999 == NO, "Orphaned tool response for call_999 stripped");
        }

        // ============================================================
        // Test 3: Anthropic Compatibility
        // ============================================================
        // Test 3a: output_config preserved in DPBYOKSanitizeAnthropicBody
        {
            NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{
                @"model": @"claude-sonnet-4-6",
                @"thinking": @{ @"type": @"adaptive" },
                @"output_config": @{ @"effort": @"medium" },
                @"max_tokens": @16384,
                @"unsupported_internal_flag": @YES
            }];

            DPBYOKSanitizeAnthropicBody(body);
            ASSERT(body[@"output_config"] != nil, "output_config must be preserved in sanitized Anthropic body");
            ASSERT([body[@"output_config"][@"effort"] isEqualToString:@"medium"], "output_config.effort preserved");
            ASSERT(body[@"unsupported_internal_flag"] == nil, "Unknown keys stripped");
        }

        // Test 3b: Strip unsupported tool fields (DeferredToolPlaceholder and defer_loading)
        {
            NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{
                @"model": @"claude-3-7-sonnet",
                @"max_tokens": @4096,
                @"tools": @[
                    @{
                        @"name": @"DeferredToolPlaceholder",
                        @"description": @"placeholder",
                        @"input_schema": @{ @"type": @"object" }
                    },
                    @{
                        @"name": @"real_tool",
                        @"description": @"valid tool",
                        @"defer_loading": @YES,
                        @"input_schema": @{ @"type": @"object" }
                    }
                ]
            }];

            DPBYOKSanitizeAnthropicBody(body);
            NSArray *tools = body[@"tools"];
            ASSERT(tools.count == 1, "DeferredToolPlaceholder tool must be removed");
            ASSERT([tools[0][@"name"] isEqualToString:@"real_tool"], "real_tool preserved");
            ASSERT(tools[0][@"defer_loading"] == nil, "defer_loading must be stripped from tool definition");
        }

        // Test 3c: Strip unsigned thinking blocks across provider transitions
        {
            NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{
                @"model": @"claude-3-7-sonnet",
                @"max_tokens": @4096,
                @"messages": @[
                    @{
                        @"role": @"assistant",
                        @"content": @[
                            @{
                                @"type": @"thinking",
                                @"thinking": @"Unsigned thinking from previous model"
                                // signature missing!
                            },
                            @{
                                @"type": @"text",
                                @"text": @"Assistant answer"
                            }
                        ]
                    },
                    @{
                        @"role": @"assistant",
                        @"content": @[
                            @{
                                @"type": @"thinking",
                                @"thinking": @"Signed thinking",
                                @"signature": @"valid_cryptographic_signature_abc123"
                            },
                            @{
                                @"type": @"text",
                                @"text": @"Valid answer"
                            }
                        ]
                    }
                ]
            }];

            DPBYOKSanitizeAnthropicBody(body);
            NSArray *msgs = body[@"messages"];
            NSArray *c1 = msgs[0][@"content"];
            ASSERT(c1.count == 1, "Unsigned thinking block was stripped");
            ASSERT([c1[0][@"type"] isEqualToString:@"text"], "Only text block remains in first assistant message");

            NSArray *c2 = msgs[1][@"content"];
            ASSERT(c2.count == 2, "Signed thinking block is preserved");
            ASSERT([c2[0][@"type"] isEqualToString:@"thinking"], "Thinking block kept");
            ASSERT([c2[0][@"signature"] isEqualToString:@"valid_cryptographic_signature_abc123"], "Signature intact");
        }

        // ============================================================
        // Test 4: Anthropic Stream Line Buffering & message_stop Check
        // ============================================================
        {
            __block BOOL completed = NO;
            __block NSMutableString *receivedText = [NSMutableString string];

            DPBYOKAnthropicStreamDelegate *stream = [[DPBYOKAnthropicStreamDelegate alloc] initWithCallback:^(NSInteger status, NSDictionary *headers, NSString *data, BOOL done, NSString *errMsg) {
                (void)status; (void)headers; (void)errMsg;
                if (data) [receivedText appendString:data];
                if (done) completed = YES;
            }];

            // Simulate assistant output containing the text "message_stop" (e.g. talking about the event)
            NSString *contentDelta = @"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Here is a discussion about message_stop event.\"}}\n\n";
            NSData *chunk1 = [contentDelta dataUsingEncoding:NSUTF8StringEncoding];
            [stream URLSession:(NSURLSession *)nil dataTask:(NSURLSessionDataTask *)nil didReceiveData:chunk1];

            ASSERT(completed == NO, "Stream must NOT terminate on assistant text containing 'message_stop'");
            ASSERT([receivedText containsString:@"message_stop event."], "Assistant text correctly delivered");

            // Now send actual event: message_stop
            NSString *stopEvent = @"event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";
            NSData *chunk2 = [stopEvent dataUsingEncoding:NSUTF8StringEncoding];
            [stream URLSession:(NSURLSession *)nil dataTask:(NSURLSessionDataTask *)nil didReceiveData:chunk2];

            ASSERT(completed == YES, "Stream must terminate on exact event: message_stop");
        }

        // Test 4b: Anthropic Stream multi-byte UTF-8 split buffering
        {
            __block NSMutableString *accumulated = [NSMutableString string];
            DPBYOKAnthropicStreamDelegate *stream = [[DPBYOKAnthropicStreamDelegate alloc] initWithCallback:^(NSInteger status, NSDictionary *headers, NSString *data, BOOL done, NSString *errMsg) {
                (void)status; (void)headers; (void)done; (void)errMsg;
                if (data) [accumulated appendString:data];
            }];

            // Euro symbol € is 3 bytes: 0xE2 0x82 0xAC
            // Split packet right in the middle of €
            const uint8_t part1Bytes[] = "event: content_block_delta\ndata: {\"type\":\"text_delta\",\"text\":\"Price: \xE2";
            const uint8_t part2Bytes[] = "\x82\xAC 100\"}\n\n";

            NSData *part1 = [NSData dataWithBytes:part1Bytes length:sizeof(part1Bytes)-1];
            NSData *part2 = [NSData dataWithBytes:part2Bytes length:sizeof(part2Bytes)-1];

            [stream URLSession:(NSURLSession *)nil dataTask:(NSURLSessionDataTask *)nil didReceiveData:part1];
            ASSERT(![accumulated containsString:@"Price:"], "Incomplete line with split character not emitted yet");

            [stream URLSession:(NSURLSession *)nil dataTask:(NSURLSessionDataTask *)nil didReceiveData:part2];
            ASSERT([accumulated containsString:@"Price: € 100"], "Multi-byte UTF-8 character correctly decoded across packets");
        }

        // ============================================================
        // Test 5: Gemini Stream multi-byte UTF-8 split buffering
        // ============================================================
        {
            __block NSMutableString *accumulated = [NSMutableString string];
            DPBYOKGeminiStreamDelegate *stream = [[DPBYOKGeminiStreamDelegate alloc] initWithModelId:@"gemini-2.5-flash" callback:^(NSInteger status, NSDictionary *headers, NSString *data, BOOL done, NSString *errMsg) {
                (void)status; (void)headers; (void)done; (void)errMsg;
                if (data) [accumulated appendString:data];
            }];

            // JSON SSE chunk with split €: "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"€\"}]}}]}\n\n"
            const uint8_t part1Bytes[] = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Total: \xE2";
            const uint8_t part2Bytes[] = "\x82\xAC\"}]}}]}\n\n";

            NSData *part1 = [NSData dataWithBytes:part1Bytes length:sizeof(part1Bytes)-1];
            NSData *part2 = [NSData dataWithBytes:part2Bytes length:sizeof(part2Bytes)-1];

            [stream URLSession:(NSURLSession *)nil dataTask:(NSURLSessionDataTask *)nil didReceiveData:part1];
            [stream URLSession:(NSURLSession *)nil dataTask:(NSURLSessionDataTask *)nil didReceiveData:part2];

            ASSERT([accumulated containsString:@"Total: €"], "Gemini multi-byte character correctly reconstructed by byteBuffer");
        }

        printf("--- Test Results: %d Passed, %d Failed ---\n", testsPassed, testsFailed);
        return (testsFailed == 0) ? 0 : 1;
    }
}
