#import "StdPatch/StdPatch.h"

void DPInstallUpdates(void);
void DPRunCLI(NSArray<NSString *> *args, void (^completion)(NSString *output));
void DPRunCLIReporting(NSArray<NSString *> *args, void (^completion)(NSString *output, NSString *reason));  // reason: why it failed, if it said
void DPHandOffAndQuit(NSArray<NSString *> *args);  // Quits Dia while the CLI runs `args`, then relaunches it.

extern NSString *const DPDia, *const DPTweaks;
NSString *DPPartName(NSString *part);

// Each level also does everything the ones before it do.
typedef NS_ENUM(NSInteger, DPAutoLevel) { DPAutoOff, DPAutoNotify, DPAutoDownload, DPAutoInstall };
DPAutoLevel DPAutoLevelOf(NSString *part);
void DPSetAutoLevel(NSString *part, DPAutoLevel level);
BOOL DPIsLocalBuild(NSString *part);  // DiaTweaks built from source: it is never downloaded or installed automatically, only when asked

extern NSNotificationName const DPUpdatesDidChangeNotification;

@interface DPUpdates : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSDictionary *found;
@property (nonatomic, readonly) BOOL checking;
@property (nonatomic, readonly) NSString *checkProblem;  // why the last check missed Dia, DiaTweaks or both, worded for the UI; nil if it covered both
- (void)check:(void (^)(void))done;
- (BOOL)available:(NSString *)part;
- (BOOL)staged:(NSString *)part;
- (BOOL)downloading:(NSString *)part;
- (BOOL)failed:(NSString *)part;
- (NSString *)failure:(NSString *)part;  // why the last download or patch failed, if diapatch said
- (double)progress:(NSString *)part;  // 0–1 while downloading, then -1 while it's verified and patched.
- (void)download:(NSString *)part then:(void (^)(void))done;
- (void)installAndRelaunch:(NSArray<NSString *> *)parts;

// Debug menu: a fake update that downloads in seconds and installs without relaunching.
- (void)pretend:(NSString *)part;
- (void)stopPretending;
@end
