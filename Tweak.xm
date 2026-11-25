#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/log.h>
#import <stdlib.h>

static NSString *reportPath;
static NSTimer *probeTimer;
static uint64_t lastTick;
static mach_timebase_info_data_t timebase;
static NSUInteger count;
static os_log_t logger;
static void record(NSString *line) {
    NSString *entry = [NSString stringWithFormat:@"%@ %@\n", NSDate.date, line];
    os_log(logger,"%{public}@",line);
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:reportPath];
    if (file) {
        @try { [file seekToEndOfFile]; [file writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]]; }
        @catch (NSException *e) { os_log_error(logger,"write failed"); }
        [file closeFile];
    }
}
static void inspectClass(Class cls) {
    if (!cls) return;
    record([NSString stringWithFormat:@"CLASS %@ super=%@", NSStringFromClass(cls), NSStringFromClass(class_getSuperclass(cls))]);
    for (int meta=0; meta<2; meta++) {
        unsigned int n=0;
        Method *methods=class_copyMethodList(meta ? object_getClass(cls) : cls,&n);
        for (unsigned int i=0;i<n;i++) {
            const char *types=method_getTypeEncoding(methods[i]);
            record([NSString stringWithFormat:@"%c %@ %s",meta?'+':'-',NSStringFromSelector(method_getName(methods[i])),types ?: ""]);
        }
        free(methods);
    }
}
static void scan(void) {
    unsigned int n=0;
    Class *classes=objc_copyClassList(&n);
    NSUInteger found=0;
    for(unsigned int i=0;i<n;i++) {
        NSString *name=NSStringFromClass(classes[i]);
        if ([name hasPrefix:@"BLSH"] || [name containsString:@"AlwaysOnPresentation"] || [name containsString:@"Flipbook"] || [name isEqualToString:@"SBBacklightController"] || [name containsString:@"AlwaysOnDisplay"]) {
            inspectClass(classes[i]);
            found++;
        }
    }
    free(classes);
    record([NSString stringWithFormat:@"SCAN complete candidates=%lu",(unsigned long)found]);
}
static void tick(NSTimer *t) {
    uint64_t now=mach_continuous_time();
    double gap=(double)(now-lastTick)*timebase.numer/timebase.denom/1e9;
    lastTick=now;
    record([NSString stringWithFormat:@"TICK %lu gap=%.3fs brightness=%.3f",(unsigned long)++count,gap,UIScreen.mainScreen.brightness]);
    if(count==10 || count==60) scan();
    if(count>=180) { [t invalidate]; probeTimer=nil; record(@"STOP: 180 callbacks"); }
}
%ctor {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            logger=os_log_create("com.aodseconds.experimental","diagnostic");
            reportPath=@"/var/mobile/Media/AODSeconds-diagnostic.txt";
            NSString *header=@"AODSeconds 0.1.4 - read-only diagnostic; no clock hooks or AOD policy changes\n";
            NSError *error=nil;
            if (![header writeToFile:reportPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
                os_log_error(logger,"report unavailable: %{public}@",error.localizedDescription);
            }
            record(@"INJECTED into SpringBoard");
            scan();
            mach_timebase_info(&timebase);
            lastTick=mach_continuous_time();
            probeTimer=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t){ tick(t); }];
            [[NSRunLoop mainRunLoop] addTimer:probeTimer forMode:NSRunLoopCommonModes];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                if(probeTimer) { [probeTimer invalidate]; probeTimer=nil; record(@"STOP: five-minute deadline"); }
            });
        });
    }
}
