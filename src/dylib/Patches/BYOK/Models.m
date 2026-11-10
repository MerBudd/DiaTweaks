#import "Patches/BYOK/BYOK.h"

static void DPBYOKCallCompletion(void (^completion)(NSArray<NSDictionary *> *, NSError *), NSArray<NSDictionary *> *models, NSError *error) {
    if (!completion) return;
    if (NSThread.isMainThread) {
        completion(models, error);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(models, error);
        });
    }
}

static NSError *DPBYOKErrorFromResponse(NSHTTPURLResponse *httpResponse, NSData *data, NSError *networkError) {
    if (networkError) return networkError;
    if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) return nil;

    NSString *message = nil;
    if (data.length > 0) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:NSDictionary.class]) {
            id errObj = json[@"error"];
            if ([errObj isKindOfClass:NSDictionary.class]) {
                if (errObj[@"message"]) {
                    message = [NSString stringWithFormat:@"%@", errObj[@"message"]];
                } else if (errObj[@"details"]) {
                    message = [NSString stringWithFormat:@"%@", errObj[@"details"]];
                }
            } else if ([errObj isKindOfClass:NSString.class]) {
                message = errObj;
            } else if (json[@"message"]) {
                message = [NSString stringWithFormat:@"%@", json[@"message"]];
            }
        }
        if (!message) {
            NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (raw.length > 0 && raw.length < 300) {
                message = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        }
    }

    if (!message || message.length == 0) {
        message = [NSString stringWithFormat:@"HTTP %ld: %@", (long)httpResponse.statusCode,
                   [NSHTTPURLResponse localizedStringForStatusCode:httpResponse.statusCode]];
    }

    return [NSError errorWithDomain:@"DPBYOKErrorDomain"
                               code:httpResponse.statusCode
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static void DPBYOKSortModels(NSMutableArray<NSDictionary *> *models) {
    [models sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
}

static void DPBYOKFetchGemini(NSString *apiKey, void (^completion)(NSArray<NSDictionary *> *, NSError *)) {
    NSURL *url = [NSURL URLWithString:@"https://generativelanguage.googleapis.com/v1beta/models?pageSize=100"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:apiKey forHTTPHeaderField:@"x-goog-api-key"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSError *apiError = DPBYOKErrorFromResponse(http, data, error);
        if (apiError) {
            DPBYOKCallCompletion(completion, nil, apiError);
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData new] options:0 error:nil];
        NSArray *rawModels = [json isKindOfClass:NSDictionary.class] ? json[@"models"] : nil;
        if (![rawModels isKindOfClass:NSArray.class]) {
            NSError *parseError = [NSError errorWithDomain:@"DPBYOKErrorDomain"
                                                      code:-1
                                                  userInfo:@{ NSLocalizedDescriptionKey: @"Invalid response format from Gemini API" }];
            DPBYOKCallCompletion(completion, nil, parseError);
            return;
        }

        NSMutableArray<NSDictionary *> *results = [NSMutableArray new];
        for (id item in rawModels) {
            if (![item isKindOfClass:NSDictionary.class]) continue;

            NSArray *methods = item[@"supportedGenerationMethods"];
            if (![methods isKindOfClass:NSArray.class] || ![methods containsObject:@"generateContent"]) {
                continue;
            }

            NSString *rawName = item[@"name"];
            if (![rawName isKindOfClass:NSString.class] || rawName.length == 0) continue;

            NSString *modelId = rawName;
            if ([modelId hasPrefix:@"models/"]) {
                modelId = [modelId substringFromIndex:7];
            }

            NSString *lowerId = [modelId lowercaseString];
            if ([lowerId containsString:@"embedding"] ||
                [lowerId containsString:@"imagen"] ||
                [lowerId containsString:@"tts"] ||
                [lowerId containsString:@"aqa"]) {
                continue;
            }

            NSString *displayName = item[@"displayName"];
            if (![displayName isKindOfClass:NSString.class] || displayName.length == 0) {
                displayName = modelId;
            }

            BOOL isThinking = [item[@"thinking"] boolValue] ||
                              [lowerId containsString:@"gemini-2.5"] ||
                              [lowerId containsString:@"gemini-3"] ||
                              [lowerId containsString:@"thinking"];

            NSArray<NSString *> *thinkingLevels = @[];
            if (isThinking) {
                if ([lowerId containsString:@"gemini-3"]) {
                    thinkingLevels = @[@"minimal", @"low", @"medium", @"high", @"off"];
                } else {
                    thinkingLevels = @[@"low", @"medium", @"high", @"off"];
                }
            }

            [results addObject:@{
                @"id": modelId,
                @"name": displayName,
                @"thinking": @(isThinking),
                @"thinkingLevels": thinkingLevels
            }];
        }

        DPBYOKSortModels(results);
        DPBYOKCallCompletion(completion, results, nil);
    }];
    [task resume];
}

static void DPBYOKFetchOpenAI(NSString *apiKey, void (^completion)(NSArray<NSDictionary *> *, NSError *)) {
    NSURL *url = [NSURL URLWithString:@"https://api.openai.com/v1/models"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSError *apiError = DPBYOKErrorFromResponse(http, data, error);
        if (apiError) {
            DPBYOKCallCompletion(completion, nil, apiError);
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData new] options:0 error:nil];
        NSArray *rawModels = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
        if (![rawModels isKindOfClass:NSArray.class]) {
            NSError *parseError = [NSError errorWithDomain:@"DPBYOKErrorDomain"
                                                      code:-1
                                                  userInfo:@{ NSLocalizedDescriptionKey: @"Invalid response format from OpenAI API" }];
            DPBYOKCallCompletion(completion, nil, parseError);
            return;
        }

        NSArray<NSString *> *allowedPrefixes = @[@"gpt-4", @"gpt-5", @"gpt-3.5", @"o1", @"o3", @"o4", @"chatgpt-"];
        NSArray<NSString *> *excludedSubstrings = @[@"audio", @"realtime", @"tts", @"whisper", @"embedding", @"dall-e", @"moderation", @"transcribe", @"search"];

        NSMutableArray<NSDictionary *> *results = [NSMutableArray new];
        for (id item in rawModels) {
            if (![item isKindOfClass:NSDictionary.class]) continue;

            NSString *modelId = item[@"id"];
            if (![modelId isKindOfClass:NSString.class] || modelId.length == 0) continue;

            NSString *lowerId = [modelId lowercaseString];

            BOOL matchedPrefix = NO;
            for (NSString *prefix in allowedPrefixes) {
                if ([lowerId hasPrefix:prefix]) {
                    matchedPrefix = YES;
                    break;
                }
            }
            if (!matchedPrefix) continue;

            BOOL isExcluded = NO;
            for (NSString *sub in excludedSubstrings) {
                if ([lowerId containsString:sub]) {
                    isExcluded = YES;
                    break;
                }
            }
            if (isExcluded) continue;

            BOOL isThinking = [lowerId hasPrefix:@"o1"] ||
                              [lowerId hasPrefix:@"o3"] ||
                              [lowerId hasPrefix:@"o4"] ||
                              [lowerId hasPrefix:@"gpt-5"] ||
                              [lowerId containsString:@"o1-"] ||
                              [lowerId containsString:@"o3-"] ||
                              [lowerId containsString:@"o4-"] ||
                              [lowerId containsString:@"gpt-5"];

            NSArray<NSString *> *thinkingLevels = @[];
            if (isThinking) {
                if ([lowerId containsString:@"gpt-5"]) {
                    thinkingLevels = @[@"low", @"medium", @"high", @"off"];
                } else {
                    thinkingLevels = @[@"low", @"medium", @"high"];
                }
            }

            [results addObject:@{
                @"id": modelId,
                @"name": modelId,
                @"thinking": @(isThinking),
                @"thinkingLevels": thinkingLevels
            }];
        }

        DPBYOKSortModels(results);
        DPBYOKCallCompletion(completion, results, nil);
    }];
    [task resume];
}

static void DPBYOKFetchAnthropic(NSString *apiKey, void (^completion)(NSArray<NSDictionary *> *, NSError *)) {
    NSURL *url = [NSURL URLWithString:@"https://api.anthropic.com/v1/models?limit=100"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:apiKey forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSError *apiError = DPBYOKErrorFromResponse(http, data, error);
        if (apiError) {
            DPBYOKCallCompletion(completion, nil, apiError);
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData new] options:0 error:nil];
        NSArray *rawModels = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
        if (![rawModels isKindOfClass:NSArray.class]) {
            NSError *parseError = [NSError errorWithDomain:@"DPBYOKErrorDomain"
                                                      code:-1
                                                  userInfo:@{ NSLocalizedDescriptionKey: @"Invalid response format from Anthropic API" }];
            DPBYOKCallCompletion(completion, nil, parseError);
            return;
        }

        NSMutableArray<NSDictionary *> *results = [NSMutableArray new];
        for (id item in rawModels) {
            if (![item isKindOfClass:NSDictionary.class]) continue;

            NSString *modelId = item[@"id"];
            if (![modelId isKindOfClass:NSString.class] || modelId.length == 0) continue;

            NSString *displayName = item[@"display_name"];
            if (![displayName isKindOfClass:NSString.class] || displayName.length == 0) {
                displayName = modelId;
            }

            NSString *lowerId = [modelId lowercaseString];

            BOOL thinkingEnabled = NO;
            BOOL adaptiveThinking = NO;
            id caps = item[@"capabilities"];
            if ([caps isKindOfClass:NSDictionary.class]) {
                id thinking = caps[@"thinking"];
                if ([thinking isKindOfClass:NSDictionary.class]) {
                    id types = thinking[@"types"];
                    if ([types isKindOfClass:NSDictionary.class]) {
                        id enabled = types[@"enabled"];
                        if ([enabled respondsToSelector:@selector(boolValue)] && [enabled boolValue]) {
                            thinkingEnabled = YES;
                        }
                        id adaptive = types[@"adaptive"];
                        if ([adaptive respondsToSelector:@selector(boolValue)] && [adaptive boolValue]) {
                            adaptiveThinking = YES;
                        }
                    }
                }
            }

            BOOL isThinking = thinkingEnabled ||
                              [lowerId containsString:@"claude-3-7"] ||
                              [lowerId containsString:@"claude-4"] ||
                              [lowerId containsString:@"claude-sonnet-4"] ||
                              [lowerId containsString:@"claude-opus-4"];

            NSArray<NSString *> *thinkingLevels = @[];
            if (isThinking) {
                if (adaptiveThinking || [lowerId containsString:@"4-6"]) {
                    thinkingLevels = @[@"adaptive", @"low", @"medium", @"high", @"off"];
                } else {
                    thinkingLevels = @[@"low", @"medium", @"high", @"off"];
                }
            }

            [results addObject:@{
                @"id": modelId,
                @"name": displayName,
                @"thinking": @(isThinking),
                @"thinkingLevels": thinkingLevels
            }];
        }

        DPBYOKSortModels(results);
        DPBYOKCallCompletion(completion, results, nil);
    }];
    [task resume];
}

static void DPBYOKFetchOpenRouter(NSString *apiKey, void (^completion)(NSArray<NSDictionary *> *, NSError *)) {
    // Step 1: Validate key
    NSURL *authURL = [NSURL URLWithString:@"https://openrouter.ai/api/v1/auth/key"];
    NSMutableURLRequest *authRequest = [NSMutableURLRequest requestWithURL:authURL];
    authRequest.HTTPMethod = @"GET";
    [authRequest setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *authTask = [[NSURLSession sharedSession] dataTaskWithRequest:authRequest completionHandler:^(NSData *authData, NSURLResponse *authResponse, NSError *authError) {
        NSHTTPURLResponse *authHttp = (NSHTTPURLResponse *)authResponse;
        NSError *authApiError = DPBYOKErrorFromResponse(authHttp, authData, authError);
        if (authApiError) {
            DPBYOKCallCompletion(completion, nil, authApiError);
            return;
        }

        // Step 2: Fetch models
        NSURL *modelsURL = [NSURL URLWithString:@"https://openrouter.ai/api/v1/models"];
        NSMutableURLRequest *modelsRequest = [NSMutableURLRequest requestWithURL:modelsURL];
        modelsRequest.HTTPMethod = @"GET";
        [modelsRequest setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

        NSURLSessionDataTask *modelsTask = [[NSURLSession sharedSession] dataTaskWithRequest:modelsRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSError *apiError = DPBYOKErrorFromResponse(http, data, error);
            if (apiError) {
                DPBYOKCallCompletion(completion, nil, apiError);
                return;
            }

            id json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData new] options:0 error:nil];
            NSArray *rawModels = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
            if (![rawModels isKindOfClass:NSArray.class]) {
                NSError *parseError = [NSError errorWithDomain:@"DPBYOKErrorDomain"
                                                          code:-1
                                                      userInfo:@{ NSLocalizedDescriptionKey: @"Invalid response format from OpenRouter API" }];
                DPBYOKCallCompletion(completion, nil, parseError);
                return;
            }

            NSMutableArray<NSDictionary *> *results = [NSMutableArray new];
            for (id item in rawModels) {
                if (![item isKindOfClass:NSDictionary.class]) continue;

                BOOL textOutput = NO;
                id arch = item[@"architecture"];
                if ([arch isKindOfClass:NSDictionary.class]) {
                    NSArray *outputs = arch[@"output_modalities"];
                    if ([outputs isKindOfClass:NSArray.class] && [outputs containsObject:@"text"]) {
                        textOutput = YES;
                    }
                    NSString *archModality = arch[@"modality"];
                    if ([archModality isKindOfClass:NSString.class] && [archModality hasSuffix:@"->text"]) {
                        textOutput = YES;
                    }
                }
                id directModality = item[@"modality"];
                if ([directModality isKindOfClass:NSString.class] && [directModality hasSuffix:@"->text"]) {
                    textOutput = YES;
                }
                if (!textOutput) continue;

                NSString *modelId = item[@"id"];
                if (![modelId isKindOfClass:NSString.class] || modelId.length == 0) continue;

                NSString *displayName = item[@"name"];
                if (![displayName isKindOfClass:NSString.class] || displayName.length == 0) {
                    displayName = modelId;
                }

                BOOL isThinking = NO;
                NSArray *params = item[@"supported_parameters"];
                if ([params isKindOfClass:NSArray.class]) {
                    if ([params containsObject:@"reasoning"] ||
                        [params containsObject:@"reasoning_effort"] ||
                        [params containsObject:@"include_reasoning"]) {
                        isThinking = YES;
                    }
                }

                NSArray<NSString *> *thinkingLevels = isThinking ? @[@"low", @"medium", @"high", @"off"] : @[];

                [results addObject:@{
                    @"id": modelId,
                    @"name": displayName,
                    @"thinking": @(isThinking),
                    @"thinkingLevels": thinkingLevels
                }];
            }

            DPBYOKSortModels(results);
            DPBYOKCallCompletion(completion, results, nil);
        }];
        [modelsTask resume];
    }];
    [authTask resume];
}

void DPBYOKFetchModels(NSString *provider, NSString *apiKey, void (^completion)(NSArray<NSDictionary *> *models, NSError *error)) {
    if (!completion) return;

    NSString *trimmedKey = [apiKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedKey.length == 0) {
        NSError *err = [NSError errorWithDomain:@"DPBYOKErrorDomain"
                                           code:-1
                                       userInfo:@{ NSLocalizedDescriptionKey: @"API key cannot be empty" }];
        DPBYOKCallCompletion(completion, nil, err);
        return;
    }

    NSString *p = [provider lowercaseString];
    if ([p isEqualToString:@"gemini"]) {
        DPBYOKFetchGemini(trimmedKey, completion);
    } else if ([p isEqualToString:@"openai"]) {
        DPBYOKFetchOpenAI(trimmedKey, completion);
    } else if ([p isEqualToString:@"anthropic"]) {
        DPBYOKFetchAnthropic(trimmedKey, completion);
    } else if ([p isEqualToString:@"openrouter"]) {
        DPBYOKFetchOpenRouter(trimmedKey, completion);
    } else {
        NSError *err = [NSError errorWithDomain:@"DPBYOKErrorDomain"
                                           code:-2
                                       userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unknown provider: %@", provider] }];
        DPBYOKCallCompletion(completion, nil, err);
    }
}
