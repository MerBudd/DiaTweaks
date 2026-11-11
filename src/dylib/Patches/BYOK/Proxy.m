#import "Patches/BYOK/BYOK.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <signal.h>
#import <libproc.h>
#import <sys/sysctl.h>

#pragma mark - State & Forward Declarations

@class DPBYOKSocketProxy;

static BOOL gBYOKProxyInstalled = NO;
static NSMutableDictionary<NSString *, DPBYOKSocketProxy *> *gActiveProxies = nil;
static NSLock *gProxyLock = nil;
static NSMutableSet<NSString *> *gBYOKCheckIds = nil;
static NSLock *gCheckIdsLock = nil;

static BOOL DPSocketWriteAll(int fd, const void *buf, size_t len) {
    const char *ptr = (const char *)buf;
    while (len > 0) {
        ssize_t written = write(fd, ptr, len);
        if (written <= 0) {
            if (written < 0 && errno == EINTR) continue;
            return NO;
        }
        ptr += written;
        len -= (size_t)written;
    }
    return YES;
}

#pragma mark - Connection Context

@interface DPBYOKConnectionContext : NSObject
@property (nonatomic, assign) int diaFd;
@property (nonatomic, assign) int agentFd;
@property (nonatomic, assign) BOOL isClosed;
@property (nonatomic, strong) NSObject *diaWriteLock;
@property (nonatomic, strong) NSObject *agentWriteLock;
@property (nonatomic, copy) NSString *agentSpec;

- (instancetype)initWithDiaFd:(int)diaFd agentFd:(int)agentFd;
- (void)sendToDia:(NSString *)line;
- (void)sendToAgent:(NSString *)line;
- (void)closeSockets;
@end

@implementation DPBYOKConnectionContext

- (instancetype)initWithDiaFd:(int)diaFd agentFd:(int)agentFd {
    self = [super init];
    if (self) {
        _diaFd = diaFd;
        _agentFd = agentFd;
        _isClosed = NO;
        _diaWriteLock = [[NSObject alloc] init];
        _agentWriteLock = [[NSObject alloc] init];
        _agentSpec = @"default";
    }
    return self;
}

- (void)sendToDia:(NSString *)line {
    if (!line) return;
    NSString *toSend = [line hasSuffix:@"\n"] ? line : [line stringByAppendingString:@"\n"];
    NSData *data = [toSend dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    @synchronized(self.diaWriteLock) {
        if (self.isClosed || self.diaFd < 0) return;
        DPSocketWriteAll(self.diaFd, data.bytes, data.length);
    }
}

- (void)sendToAgent:(NSString *)line {
    if (!line) return;
    NSString *toSend = [line hasSuffix:@"\n"] ? line : [line stringByAppendingString:@"\n"];
    NSData *data = [toSend dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    @synchronized(self.agentWriteLock) {
        if (self.isClosed || self.agentFd < 0) return;
        DPSocketWriteAll(self.agentFd, data.bytes, data.length);
    }
}

- (void)closeSockets {
    @synchronized(self.agentWriteLock) {
        @synchronized(self.diaWriteLock) {
            if (self.isClosed) return;
            self.isClosed = YES;
            if (self.diaFd >= 0) {
                shutdown(self.diaFd, SHUT_RDWR);
                close(self.diaFd);
                self.diaFd = -1;
            }
            if (self.agentFd >= 0) {
                shutdown(self.agentFd, SHUT_RDWR);
                close(self.agentFd);
                self.agentFd = -1;
            }
        }
    }
}

- (void)dealloc {
    [self closeSockets];
}

@end

#pragma mark - Socket Proxy

@interface DPBYOKSocketProxy : NSObject
@property (nonatomic, copy) NSString *origPath;
@property (nonatomic, copy) NSString *realPath;
@property (nonatomic, assign) int serverFd;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong) dispatch_queue_t acceptQueue;

- (instancetype)initWithOrigPath:(NSString *)origPath realPath:(NSString *)realPath;
- (BOOL)start;
- (void)stop;
@end

@implementation DPBYOKSocketProxy

- (instancetype)initWithOrigPath:(NSString *)origPath realPath:(NSString *)realPath {
    self = [super init];
    if (self) {
        _origPath = [origPath copy];
        _realPath = [realPath copy];
        _serverFd = -1;
        _isRunning = NO;
        NSString *queueName = [NSString stringWithFormat:@"com.diatweaks.byok.proxy.%@", origPath.lastPathComponent];
        _acceptQueue = dispatch_queue_create(queueName.UTF8String, DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)start {
    if (self.isRunning) return YES;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"[BYOK Proxy] Failed to create socket: %s", strerror(errno));
        return NO;
    }

    int val = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &val, sizeof(val));

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, self.origPath.UTF8String, sizeof(addr.sun_path) - 1);
#ifdef __APPLE__
    addr.sun_len = sizeof(addr);
#endif

    unlink(self.origPath.UTF8String);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[BYOK Proxy] Failed to bind to %@: %s", self.origPath, strerror(errno));
        close(fd);
        return NO;
    }

    if (listen(fd, 16) < 0) {
        NSLog(@"[BYOK Proxy] Failed to listen on %@: %s", self.origPath, strerror(errno));
        close(fd);
        unlink(self.origPath.UTF8String);
        return NO;
    }

    self.serverFd = fd;
    self.isRunning = YES;

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.acceptQueue, ^{
        [weakSelf acceptLoop];
    });

    return YES;
}

- (void)stop {
    self.isRunning = NO;
    if (self.serverFd >= 0) {
        shutdown(self.serverFd, SHUT_RDWR);
        close(self.serverFd);
        self.serverFd = -1;
    }
    unlink(self.origPath.UTF8String);
}

- (void)dealloc {
    [self stop];
}

- (void)acceptLoop {
    while (self.isRunning && self.serverFd >= 0) {
        struct sockaddr_un clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        int diaFd = accept(self.serverFd, (struct sockaddr *)&clientAddr, &clientLen);
        if (diaFd < 0) {
            if (!self.isRunning) break;
            if (errno == EINTR) continue;
            usleep(50000);
            continue;
        }

        int val = 1;
        setsockopt(diaFd, SOL_SOCKET, SO_NOSIGPIPE, &val, sizeof(val));

        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [weakSelf handleClientConnection:diaFd];
        });
    }
}

- (void)handleClientConnection:(int)diaFd {
    struct sockaddr_un agentAddr;
    memset(&agentAddr, 0, sizeof(agentAddr));
    agentAddr.sun_family = AF_UNIX;
    strncpy(agentAddr.sun_path, self.realPath.UTF8String, sizeof(agentAddr.sun_path) - 1);
#ifdef __APPLE__
    agentAddr.sun_len = sizeof(agentAddr);
#endif

    int agentFd = -1;
    BOOL connected = NO;
    for (int attempt = 0; attempt < 100; attempt++) {
        agentFd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (agentFd >= 0) {
            int val = 1;
            setsockopt(agentFd, SOL_SOCKET, SO_NOSIGPIPE, &val, sizeof(val));
            if (connect(agentFd, (struct sockaddr *)&agentAddr, sizeof(agentAddr)) == 0) {
                connected = YES;
                break;
            }
            close(agentFd);
            agentFd = -1;
        }
        usleep(50000);
    }

    if (!connected || agentFd < 0) {
        NSLog(@"[BYOK Proxy] Failed to connect to real socket at %@ after 100 attempts: %s", self.realPath, strerror(errno));
        close(diaFd);
        return;
    }

    DPBYOKConnectionContext *context = [[DPBYOKConnectionContext alloc] initWithDiaFd:diaFd agentFd:agentFd];
    dispatch_group_t group = dispatch_group_create();

    // Dia.app -> agent-server
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableData *buffer = [NSMutableData data];
        uint8_t chunk[8192];
        while (!context.isClosed) {
            int fd = context.diaFd;
            if (fd < 0) break;
            ssize_t bytesRead = read(fd, chunk, sizeof(chunk));
            if (bytesRead <= 0) {
                if (bytesRead < 0 && errno == EINTR) continue;
                break;
            }
            [buffer appendBytes:chunk length:(NSUInteger)bytesRead];
            while (1) {
                const uint8_t *bytes = (const uint8_t *)buffer.bytes;
                NSUInteger length = buffer.length;
                const void *nl = memchr(bytes, '\n', length);
                if (!nl) break;
                NSUInteger lineLen = (const uint8_t *)nl - bytes;
                NSData *lineData = [buffer subdataWithRange:NSMakeRange(0, lineLen)];
                [buffer replaceBytesInRange:NSMakeRange(0, lineLen + 1) withBytes:NULL length:0];

                NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
                if (!line || line.length == 0) continue;
                if ([line hasSuffix:@"\r"]) line = [line substringToIndex:line.length - 1];

                [self processDiaLine:line context:context];
            }
        }
        [context closeSockets];
    });

    // agent-server -> Dia.app
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableData *buffer = [NSMutableData data];
        uint8_t chunk[8192];
        while (!context.isClosed) {
            int fd = context.agentFd;
            if (fd < 0) break;
            ssize_t bytesRead = read(fd, chunk, sizeof(chunk));
            if (bytesRead <= 0) {
                if (bytesRead < 0 && errno == EINTR) continue;
                break;
            }
            [buffer appendBytes:chunk length:(NSUInteger)bytesRead];
            while (1) {
                const uint8_t *bytes = (const uint8_t *)buffer.bytes;
                NSUInteger length = buffer.length;
                const void *nl = memchr(bytes, '\n', length);
                if (!nl) break;
                NSUInteger lineLen = (const uint8_t *)nl - bytes;
                NSData *lineData = [buffer subdataWithRange:NSMakeRange(0, lineLen)];
                [buffer replaceBytesInRange:NSMakeRange(0, lineLen + 1) withBytes:NULL length:0];

                NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
                if (!line || line.length == 0) continue;
                if ([line hasSuffix:@"\r"]) line = [line substringToIndex:line.length - 1];

                [self processAgentLine:line context:context];
            }
        }
        [context closeSockets];
    });

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    [context closeSockets];
}

- (void)processDiaLine:(NSString *)line context:(DPBYOKConnectionContext *)context {
    if (![line containsString:@"\"RUN\""] && ![line containsString:@"\"ACK\""]) {
        [context sendToAgent:line];
        return;
    }

    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                                              options:NSJSONReadingMutableContainers
                                                error:&err];
    if (err || ![json isKindOfClass:[NSMutableDictionary class]]) {
        [context sendToAgent:line];
        return;
    }

    NSMutableDictionary *msg = (NSMutableDictionary *)json;
    NSString *type = msg[@"type"];

    if ([type isEqualToString:@"RUN"]) {
        id payloadObj = msg[@"payload"];
        if ([payloadObj isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *payload = [payloadObj isKindOfClass:[NSMutableDictionary class]] ? payloadObj : [payloadObj mutableCopy];
            msg[@"payload"] = payload;
            NSString *agentSpec = [payload[@"agent"] isKindOfClass:[NSString class]] ? payload[@"agent"] : @"default";
            context.agentSpec = agentSpec;
            if (DPBYOKShouldRoute(agentSpec)) {
                payload[@"dlp_reporting"] = @{@"enabled": @NO};
                NSData *modData = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
                if (modData) {
                    line = [[NSString alloc] initWithData:modData encoding:NSUTF8StringEncoding];
                }
            }
        }
    } else if ([type isEqualToString:@"ACK"]) {
        NSString *msgId = msg[@"msg"];
        BOOL wasInCheckIds = NO;
        if (msgId && [msgId isKindOfClass:[NSString class]]) {
            [gCheckIdsLock lock];
            if ([gBYOKCheckIds containsObject:msgId]) {
                [gBYOKCheckIds removeObject:msgId];
                wasInCheckIds = YES;
            }
            [gCheckIdsLock unlock];
        }
        if (wasInCheckIds) {
            NSDictionary *ackPayload = msg[@"payload"];
            if ([ackPayload isKindOfClass:[NSDictionary class]]) {
                NSString *decision = ackPayload[@"decision"];
                NSString *reason = ackPayload[@"reason"];
                if ([decision isEqualToString:@"block"] && [reason isKindOfClass:[NSString class]] && [reason containsString:@"safety check result was unavailable"]) {
                    msg[@"payload"] = @{@"decision": @"allow"};
                    NSData *modData = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
                    if (modData) {
                        line = [[NSString alloc] initWithData:modData encoding:NSUTF8StringEncoding];
                    }
                }
            }
        }
    }

    [context sendToAgent:line];
}

- (void)processAgentLine:(NSString *)line context:(DPBYOKConnectionContext *)context {
    if (![line containsString:@"\"LLM_REQUEST\""] && ![line containsString:@"\"CHECK\""]) {
        [context sendToDia:line];
        return;
    }

    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0
                                                error:&err];
    if (err || ![json isKindOfClass:[NSDictionary class]]) {
        [context sendToDia:line];
        return;
    }

    NSDictionary *msg = (NSDictionary *)json;
    NSString *type = msg[@"type"];

    if ([type isEqualToString:@"CHECK"]) {
        NSString *agentSpec = context.agentSpec ?: @"default";
        if (DPBYOKShouldRoute(agentSpec)) {
            NSString *checkMsgId = msg[@"msg"];
            if (checkMsgId && [checkMsgId isKindOfClass:[NSString class]]) {
                [gCheckIdsLock lock];
                [gBYOKCheckIds addObject:checkMsgId];
                [gCheckIdsLock unlock];
            }
        }
        [context sendToDia:line];
        return;
    }

    if ([type isEqualToString:@"LLM_REQUEST"]) {
        NSString *agentSpec = msg[@"agent_spec"];
        if (!agentSpec || ![agentSpec isKindOfClass:[NSString class]] || agentSpec.length == 0) {
            agentSpec = context.agentSpec ?: @"default";
        }
        if (DPBYOKShouldRoute(agentSpec)) {
            NSString *msgId = msg[@"msg"] ?: @"";
            NSDictionary *payload = [msg[@"payload"] isKindOfClass:[NSDictionary class]] ? msg[@"payload"] : @{};
            NSString *endpoint = payload[@"endpoint"] ?: @"messages";
            NSDictionary *headers = [payload[@"headers"] isKindOfClass:[NSDictionary class]] ? payload[@"headers"] : @{};
            id rawBody = payload[@"body"];
            NSString *bodyStr = @"{}";
            if ([rawBody isKindOfClass:[NSString class]]) {
                bodyStr = (NSString *)rawBody;
            } else if ([rawBody isKindOfClass:[NSDictionary class]] || [rawBody isKindOfClass:[NSArray class]]) {
                NSData *bData = [NSJSONSerialization dataWithJSONObject:rawBody options:0 error:nil];
                if (bData) {
                    bodyStr = [[NSString alloc] initWithData:bData encoding:NSUTF8StringEncoding] ?: @"{}";
                }
            }

            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                DPBYOKExecuteLLMRequest(endpoint, headers, bodyStr, agentSpec, ^(NSInteger statusCode, NSDictionary *respHeaders, NSString *data, BOOL done, NSString *errorMessage) {
                    if ([endpoint isEqualToString:@"count-tokens"] || [endpoint hasSuffix:@"count_tokens"] || [endpoint hasSuffix:@"count-tokens"]) {
                        NSDictionary *ackDict = @{
                            @"type": @"ACK",
                            @"msg": msgId,
                            @"success": @(errorMessage == nil),
                            @"payload": @{
                                @"status_code": @(statusCode),
                                @"headers": respHeaders ?: @{@"content-type": @"application/json"},
                                @"body": (data && data.length > 0) ? data : @"{\"input_tokens\":100}"
                            }
                        };
                        NSData *ackData = [NSJSONSerialization dataWithJSONObject:ackDict options:0 error:nil];
                        if (ackData) {
                            NSString *ackLine = [[NSString alloc] initWithData:ackData encoding:NSUTF8StringEncoding];
                            [context sendToAgent:ackLine];
                        }
                    } else {
                        // messages streaming
                        if (errorMessage != nil && data == nil) {
                            NSDictionary *errAck = @{
                                @"type": @"ACK",
                                @"msg": msgId,
                                @"success": @NO,
                                @"error": errorMessage
                            };
                            NSData *errData = [NSJSONSerialization dataWithJSONObject:errAck options:0 error:nil];
                            if (errData) {
                                NSString *errLine = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
                                [context sendToAgent:errLine];
                            }
                        } else {
                            if (data.length > 0 && done) {
                                NSDictionary *chunk1 = @{
                                    @"type": @"ACK",
                                    @"msg": msgId,
                                    @"success": @YES,
                                    @"payload": @{
                                        @"status_code": @(statusCode),
                                        @"headers": respHeaders ?: @{@"content-type": @"text/event-stream"},
                                        @"data": data,
                                        @"done": @NO
                                    }
                                };
                                NSData *c1Data = [NSJSONSerialization dataWithJSONObject:chunk1 options:0 error:nil];
                                if (c1Data) {
                                    NSString *c1Line = [[NSString alloc] initWithData:c1Data encoding:NSUTF8StringEncoding];
                                    [context sendToAgent:c1Line];
                                }
                                NSDictionary *chunk2 = @{
                                    @"type": @"ACK",
                                    @"msg": msgId,
                                    @"success": @YES,
                                    @"payload": @{
                                        @"status_code": @(statusCode),
                                        @"headers": respHeaders ?: @{@"content-type": @"text/event-stream"},
                                        @"data": @"",
                                        @"done": @YES
                                    }
                                };
                                NSData *c2Data = [NSJSONSerialization dataWithJSONObject:chunk2 options:0 error:nil];
                                if (c2Data) {
                                    NSString *c2Line = [[NSString alloc] initWithData:c2Data encoding:NSUTF8StringEncoding];
                                    [context sendToAgent:c2Line];
                                }
                            } else {
                                NSDictionary *ack = @{
                                    @"type": @"ACK",
                                    @"msg": msgId,
                                    @"success": @YES,
                                    @"payload": @{
                                        @"status_code": @(statusCode),
                                        @"headers": respHeaders ?: @{@"content-type": @"text/event-stream"},
                                        @"data": data ?: @"",
                                        @"done": @(done)
                                    }
                                };
                                NSData *ackData = [NSJSONSerialization dataWithJSONObject:ack options:0 error:nil];
                                if (ackData) {
                                    NSString *ackLine = [[NSString alloc] initWithData:ackData encoding:NSUTF8StringEncoding];
                                    [context sendToAgent:ackLine];
                                }
                            }
                        }
                    }
                });
            });
            return;
        }
    }

    [context sendToDia:line];
}

@end

#pragma mark - Proxy Lifecycle & Hooks

static void DPBYOKStartSocketProxy(NSString *origPath, NSString *realPath) {
    if (!origPath || !realPath) return;
    [gProxyLock lock];
    DPBYOKSocketProxy *existing = gActiveProxies[origPath];
    if (existing && existing.isRunning) {
        [gProxyLock unlock];
        return;
    }
    DPBYOKSocketProxy *proxy = [[DPBYOKSocketProxy alloc] initWithOrigPath:origPath realPath:realPath];
    if ([proxy start]) {
        gActiveProxies[origPath] = proxy;
    }
    [gProxyLock unlock];
}

static NSDictionary *DPBYOKInterceptEnvironment(NSDictionary *env) {
    if (![env isKindOfClass:[NSDictionary class]]) return env;
    NSString *origPath = env[@"AGENT_SERVER_SOCKET_PATH"];
    if (!origPath || ![origPath isKindOfClass:[NSString class]] || origPath.length == 0) {
        return env;
    }
    if ([origPath hasSuffix:@".real.sock"]) {
        return env;
    }

    NSString *realPath = [origPath stringByAppendingString:@".real.sock"];
    NSMutableDictionary *newEnv = [env mutableCopy];
    newEnv[@"AGENT_SERVER_SOCKET_PATH"] = realPath;

    DPBYOKStartSocketProxy(origPath, realPath);
    return newEnv;
}

static void DPTask_setEnvironment(NSTask *self, SEL _cmd, NSDictionary *environment) {
    NSDictionary *modified = DPBYOKInterceptEnvironment(environment);
    DPCallOriginal(DPTask_setEnvironment, self, modified);
}

static void DPTask_checkAndIntercept(NSTask *self) {
    NSDictionary *env = self.environment;
    if (![env isKindOfClass:[NSDictionary class]]) return;
    NSString *origPath = env[@"AGENT_SERVER_SOCKET_PATH"];
    if (!origPath || ![origPath isKindOfClass:[NSString class]] || origPath.length == 0) return;
    if ([origPath hasSuffix:@".real.sock"]) return;

    NSDictionary *modified = DPBYOKInterceptEnvironment(env);
    [self setEnvironment:modified];
}

static BOOL DPTask_launchAndReturnError(NSTask *self, SEL _cmd, NSError **error) {
    DPTask_checkAndIntercept(self);
    return DPCallOriginal(DPTask_launchAndReturnError, self, error);
}

static void DPTask_launch(NSTask *self, SEL _cmd) {
    DPTask_checkAndIntercept(self);
    DPCallOriginal(DPTask_launch, self);
}

#pragma mark - Public Interface

void DPBYOKRestartAgentServersIfNeeded(void) {
    pid_t myPid = getpid();
    int byteCount = proc_listchildpids(myPid, NULL, 0);
    int count = 0;
    pid_t *pids = NULL;

    if (byteCount > 0) {
        count = byteCount / (int)sizeof(pid_t);
        pids = malloc((size_t)byteCount);
        if (pids) {
            int actual = proc_listchildpids(myPid, pids, byteCount);
            if (actual > 0) {
                count = actual / (int)sizeof(pid_t);
            } else {
                free(pids);
                pids = NULL;
                count = 0;
            }
        }
    }

    if (!pids || count == 0) {
        int allBytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
        if (allBytes > 0) {
            pids = malloc((size_t)allBytes);
            if (pids) {
                int actualAll = proc_listpids(PROC_ALL_PIDS, 0, pids, allBytes);
                if (actualAll > 0) {
                    count = actualAll / (int)sizeof(pid_t);
                } else {
                    free(pids);
                    pids = NULL;
                    count = 0;
                }
            }
        }
    }

    if (!pids || count == 0) {
        if (pids) free(pids);
        return;
    }

    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0 || pid == myPid) continue;

        struct proc_bsdinfo bsdinfo;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdinfo, sizeof(bsdinfo)) <= 0) {
            continue;
        }
        if ((pid_t)bsdinfo.pbi_ppid != myPid) {
            continue;
        }

        char pathBuf[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, pathBuf, sizeof(pathBuf)) <= 0) {
            continue;
        }
        NSString *execPath = [NSString stringWithUTF8String:pathBuf];
        if (![execPath containsString:@"agent-server"]) {
            continue;
        }

        BOOL isProxied = NO;
        int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
        size_t argSize = 0;
        if (sysctl(mib, 3, NULL, &argSize, NULL, 0) == 0 && argSize > 0) {
            char *procArgs = malloc(argSize);
            if (procArgs) {
                if (sysctl(mib, 3, procArgs, &argSize, NULL, 0) == 0) {
                    NSData *data = [NSData dataWithBytesNoCopy:procArgs length:argSize freeWhenDone:YES];
                    NSString *raw = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
                    if ([raw containsString:@"AGENT_SERVER_SOCKET_PATH="] && [raw containsString:@".real.sock"]) {
                        isProxied = YES;
                    }
                } else {
                    free(procArgs);
                }
            }
        }

        if (!isProxied) {
            NSLog(@"[BYOK] Terminating unproxied agent-server child pid %d", pid);
            kill(pid, SIGTERM);
        }
    }
    free(pids);
}

void DPInstallBYOKProxy(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        signal(SIGPIPE, SIG_IGN);
        gActiveProxies = [NSMutableDictionary dictionary];
        gProxyLock = [[NSLock alloc] init];
        gBYOKCheckIds = [NSMutableSet set];
        gCheckIdsLock = [[NSLock alloc] init];

        Class concreteTask = NSClassFromString(@"NSConcreteTask");
        Class baseTask = [NSTask class];

        if (concreteTask) {
            DPHookClass(concreteTask, @selector(setEnvironment:), (IMP)DPTask_setEnvironment);
            DPHookClass(concreteTask, @selector(launchAndReturnError:), (IMP)DPTask_launchAndReturnError);
            DPHookClass(concreteTask, @selector(launch), (IMP)DPTask_launch);
        } else if (baseTask) {
            DPHookClass(baseTask, @selector(setEnvironment:), (IMP)DPTask_setEnvironment);
            DPHookClass(baseTask, @selector(launchAndReturnError:), (IMP)DPTask_launchAndReturnError);
            DPHookClass(baseTask, @selector(launch), (IMP)DPTask_launch);
        }

        gBYOKProxyInstalled = YES;

        DPBYOKRestartAgentServersIfNeeded();
    });
}

NSString *DPVerifyBYOKProxy(DPPatch *patch) {
    (void)patch;
    return gBYOKProxyInstalled ? nil : @"BYOK proxy hook was not installed";
}
