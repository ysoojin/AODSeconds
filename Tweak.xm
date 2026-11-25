#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/log.h>
#include <atomic>
#include <string.h>
static NSString *reportPath;
static NSObject *fileLock;
static os_log_t logger;
static mach_timebase_info_data_t tb;
static std::atomic<uint64_t> began{0};
static std::atomic<unsigned> queries{0};
static void record(NSString *s) {
    os_log(logger,"%{public}@",s);
    @synchronized(fileLock) {
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:reportPath];
        if (!h) return;
        @try {
            [h seekToEndOfFile];
            [h writeData:[[NSString stringWithFormat:@"%@ %@\n",NSDate.date,s] dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch(NSException *e) { os_log_error(logger,"write failed"); }
        [h closeFile];
    }
}
static BOOL active(void) {
    uint64_t start=began.load();
    return start && ((double)(mach_continuous_time()-start)*tb.numer/tb.denom/1e9 < 120.0);
}
static BOOL matches(Class cls, SEL sel, const char *encoding) {
    Method m=cls ? class_getInstanceMethod(cls,sel) : NULL;
    return m && strcmp(method_getTypeEncoding(m),encoding)==0;
}
%group EngineProbe
%hook BLSHAlwaysOnPresentationEngine
- (void)startFlipbookAndEnsureCurrent {
    uint64_t expected=0;
    if(began.compare_exchange_strong(expected,mach_continuous_time())) record(@"TEST START 120 seconds");
    record(@"CALL startFlipbookAndEnsureCurrent");
    %orig;
}
- (BOOL)isFlipbookPowerSavingEnabled {
    BOOL original=%orig;
    BOOL testing=active();
    BOOL result=testing ? NO : original;
    unsigned n=++queries;
    if(n<=30 || n%60==0) record([NSString stringWithFormat:@"POWER query=%u original=%d returned=%d test=%d",n,original,result,testing]);
    return result;
}
- (void)startLiveUpdates {
    record(@"CALL startLiveUpdates (system initiated)");
    %orig;
}
%end
%end
%ctor {
    @autoreleasepool {
        logger=os_log_create("com.aodseconds.experimental","liveprobe");
        fileLock=[NSObject new];
        reportPath=@"/var/mobile/Media/AODSeconds-diagnostic.txt";
        [@"AODSeconds 0.1.5 - bounded policy experiment; LockSeconds required\n" writeToFile:reportPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        mach_timebase_info(&tb);
        record(@"INJECTED");
        Class engine=objc_getClass("BLSHAlwaysOnPresentationEngine");
        if(matches(engine,@selector(startFlipbookAndEnsureCurrent),"v16@0:8") && matches(engine,@selector(isFlipbookPowerSavingEnabled),"B16@0:8") && matches(engine,@selector(startLiveUpdates),"v16@0:8")) {
            %init(EngineProbe,BLSHAlwaysOnPresentationEngine=engine);
            record(@"ENGINE hooks installed");
        } else record(@"ENGINE unavailable or signature mismatch; no override");
    }
}
