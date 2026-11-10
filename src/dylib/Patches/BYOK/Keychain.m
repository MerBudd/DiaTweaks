#import "Patches/BYOK/BYOK.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static NSMutableDictionary<NSString *, NSString *> *gMemoryKeys = nil;
static id gMemoryLock = nil;

static void InitMemoryKeysIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gMemoryKeys = [[NSMutableDictionary alloc] init];
        gMemoryLock = [[NSObject alloc] init];
    });
}

#pragma mark - Security dlopen

typedef OSStatus (*SecItemCopyMatchingFunc)(CFDictionaryRef query, CFTypeRef *result);
typedef OSStatus (*SecItemAddFunc)(CFDictionaryRef attributes, CFTypeRef *result);
typedef OSStatus (*SecItemUpdateFunc)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
typedef OSStatus (*SecItemDeleteFunc)(CFDictionaryRef query);

static void *SecurityHandle(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    });
    return handle;
}

static SecItemCopyMatchingFunc GetSecItemCopyMatching(void) {
    void *h = SecurityHandle();
    return h ? (SecItemCopyMatchingFunc)dlsym(h, "SecItemCopyMatching") : NULL;
}

static SecItemAddFunc GetSecItemAdd(void) {
    void *h = SecurityHandle();
    return h ? (SecItemAddFunc)dlsym(h, "SecItemAdd") : NULL;
}

static SecItemUpdateFunc GetSecItemUpdate(void) {
    void *h = SecurityHandle();
    return h ? (SecItemUpdateFunc)dlsym(h, "SecItemUpdate") : NULL;
}

static SecItemDeleteFunc GetSecItemDelete(void) {
    void *h = SecurityHandle();
    return h ? (SecItemDeleteFunc)dlsym(h, "SecItemDelete") : NULL;
}

#pragma mark - Fallback Plist Obfuscation

static NSData *ObfuscationKey(void) {
    NSString *user = NSUserName() ?: @"";
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.diapatches.byok";
    NSString *seed = [NSString stringWithFormat:@"%@:%@", user, bundle];
    NSData *seedData = [seed dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(seedData.bytes, (CC_LONG)seedData.length, hash);
    return [NSData dataWithBytes:hash length:sizeof(hash)];
}

static NSData *XORData(NSData *data, NSData *key) {
    if (data.length == 0 || key.length == 0) return data;
    NSMutableData *result = [data mutableCopy];
    uint8_t *bytes = (uint8_t *)result.mutableBytes;
    const uint8_t *keyBytes = (const uint8_t *)key.bytes;
    NSUInteger keyLen = key.length;
    for (NSUInteger i = 0; i < result.length; i++) {
        bytes[i] ^= keyBytes[i % keyLen];
    }
    return result;
}

static NSString *FallbackPlistPath(void) {
    return DPAppSupport(@"DiaPatches/.byok-keys.plist");
}

static NSString *LoadKeyFromFallbackPlist(NSString *provider) {
    if (provider.length == 0) return nil;
    NSString *path = FallbackPlistPath();
    if (path.length == 0) return nil;
    NSData *encrypted = [NSData dataWithContentsOfFile:path];
    if (encrypted.length == 0) return nil;

    NSData *decrypted = XORData(encrypted, ObfuscationKey());
    id plist = [NSPropertyListSerialization propertyListWithData:decrypted options:0 format:NULL error:nil];
    if ([plist isKindOfClass:[NSDictionary class]]) {
        NSString *val = plist[provider];
        if ([val isKindOfClass:[NSString class]] && val.length > 0) {
            return val;
        }
    }
    return nil;
}

static void SaveKeyToFallbackPlist(NSString *provider, NSString *apiKey) {
    if (provider.length == 0) return;
    NSString *path = FallbackPlistPath();
    if (path.length == 0) return;
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (dir.length > 0) {
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                                withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions: @0700}
                                                      error:nil];
    }

    NSMutableDictionary *dict = nil;
    NSData *encrypted = [NSData dataWithContentsOfFile:path];
    if (encrypted.length > 0) {
        NSData *decrypted = XORData(encrypted, ObfuscationKey());
        id plist = [NSPropertyListSerialization propertyListWithData:decrypted options:NSPropertyListMutableContainers format:NULL error:nil];
        if ([plist isKindOfClass:[NSMutableDictionary class]]) {
            dict = (NSMutableDictionary *)plist;
        } else if ([plist isKindOfClass:[NSDictionary class]]) {
            dict = [plist mutableCopy];
        }
    }
    if (!dict) dict = [NSMutableDictionary dictionary];

    if (apiKey.length > 0) {
        dict[provider] = apiKey;
    } else {
        [dict removeObjectForKey:provider];
    }

    NSError *err = nil;
    NSData *serialized = [NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err];
    if (serialized && !err) {
        NSData *outData = XORData(serialized, ObfuscationKey());
        const char *fsPath = path.fileSystemRepresentation;
        int fd = open(fsPath, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) {
            write(fd, outData.bytes, outData.length);
            close(fd);
        }
        chmod(fsPath, 0600);
    }
}

#pragma mark - Public API

NSString *DPBYOKLoadKey(NSString *provider) {
    if (provider.length == 0) return nil;
    InitMemoryKeysIfNeeded();

    @synchronized(gMemoryLock) {
        NSString *cached = gMemoryKeys[provider];
        if (cached) return cached;
    }

    // Try Keychain
    SecItemCopyMatchingFunc copyMatching = GetSecItemCopyMatching();
    if (copyMatching) {
        NSDictionary *query = @{
            @"class": @"genp",
            @"svce": @"com.diapatches.byok",
            @"acct": provider,
            @"r_Data": (id)kCFBooleanTrue,
            @"m_Limit": @"m_LimitOne"
        };
        CFTypeRef result = NULL;
        OSStatus status = copyMatching((__bridge CFDictionaryRef)query, &result);
        if (status == 0 && result) {
            NSData *data = (__bridge_transfer NSData *)result;
            if ([data isKindOfClass:[NSData class]] && data.length > 0) {
                NSString *key = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (key.length > 0) {
                    @synchronized(gMemoryLock) {
                        gMemoryKeys[provider] = key;
                    }
                    SaveKeyToFallbackPlist(provider, key);
                    return key;
                }
            }
        }
    }

    // Fallback obfuscated plist
    NSString *fallbackKey = LoadKeyFromFallbackPlist(provider);
    if (fallbackKey.length > 0) {
        @synchronized(gMemoryLock) {
            gMemoryKeys[provider] = fallbackKey;
        }
        return fallbackKey;
    }

    return nil;
}

BOOL DPBYOKSaveKey(NSString *provider, NSString *apiKey) {
    if (provider.length == 0) return NO;
    InitMemoryKeysIfNeeded();

    NSString *trimmed = [apiKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) trimmed = nil;

    @synchronized(gMemoryLock) {
        if (trimmed) {
            gMemoryKeys[provider] = trimmed;
        } else {
            [gMemoryKeys removeObjectForKey:provider];
        }
    }

    // Maintain fallback plist
    SaveKeyToFallbackPlist(provider, trimmed);

    // Save to Keychain
    SecItemDeleteFunc deleteFunc = GetSecItemDelete();
    SecItemUpdateFunc updateFunc = GetSecItemUpdate();
    SecItemAddFunc addFunc = GetSecItemAdd();

    NSDictionary *query = @{
        @"class": @"genp",
        @"svce": @"com.diapatches.byok",
        @"acct": provider
    };

    if (trimmed.length > 0) {
        NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *attrsToUpdate = @{
            @"v_Data": data
        };
        OSStatus status = -1;
        if (updateFunc) {
            status = updateFunc((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attrsToUpdate);
        }
        if (status != 0 && addFunc) {
            NSMutableDictionary *attrs = [query mutableCopy];
            attrs[@"v_Data"] = data;
            status = addFunc((__bridge CFDictionaryRef)attrs, NULL);
            if (status != 0 && deleteFunc) {
                deleteFunc((__bridge CFDictionaryRef)query);
                addFunc((__bridge CFDictionaryRef)attrs, NULL);
            }
        }
    } else {
        if (deleteFunc) {
            deleteFunc((__bridge CFDictionaryRef)query);
        }
    }

    return YES;
}
