#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <atomic>
#include <string.h>
static NSString *path;
static NSObject *guard;
static os_log_t logger;
static std::atomic<unsigned> events{0};
static void record(NSString *s) {
    if (++events > 350) return;
    os_log(logger,"%{public}@",s);
    @synchronized(guard) {
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) return;
        @try {
            [h seekToEndOfFile];
            [h writeData:[[NSString stringWithFormat:@"%@ %@\n",NSDate.date,s] dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch(NSException *e) { os_log_error(logger,"write failed"); }
        [h closeFile];
    }
}
static BOOL matches(Class cls, SEL sel, const char *encoding) {
    Method m=cls ? class_getInstanceMethod(cls,sel) : NULL;
    return m && strcmp(method_getTypeEncoding(m),encoding)==0;
}
%group Engine
%hook BLSHAlwaysOnPresentationEngine
- (void)startFlipbookAndEnsureCurrent {
    record(@"ENGINE startFlipbookAndEnsureCurrent");
    %orig;
}
- (void)startLiveUpdates {
    record(@"ENGINE startLiveUpdates");
    %orig;
}
%end
%end
%group Dates
%hook BLSHEnvironmentDatesModel
- (void)registerSpecifiers:(id)specifiers forDateInterval:(id)interval {
    NSString *range=[interval isKindOfClass:[NSDateInterval class]] ? [NSString stringWithFormat:@"%@ to %@ duration=%.3f",[(NSDateInterval *)interval startDate],[(NSDateInterval *)interval endDate],[(NSDateInterval *)interval duration]] : NSStringFromClass([interval class]);
    NSUInteger n=[specifiers isKindOfClass:[NSArray class]] ? [(NSArray *)specifiers count] : 0;
    record([NSString stringWithFormat:@"REGISTER count=%lu interval=%@",(unsigned long)n,range]);
    if(n) {
        NSArray *a=specifiers;
        for(NSUInteger i=0;i<MIN(n,8);i++) {
            id item=a[i];
            record([NSString stringWithFormat:@"SPEC class=%@",NSStringFromClass([item class])]);
        }
    }
    %orig;
}
- (id)specifierForDate:(id)date {
    id result=%orig;
    record([NSString stringWithFormat:@"LOOKUP date=%@ resultClass=%@",[date isKindOfClass:[NSDate class]] ? date : @"unknown",NSStringFromClass([result class])]);
    return result;
}
%end
%end
%group Budget
%hook BLSHInactiveProcessMinutesBudget
- (long long)allowedFidelityAtDate:(id)date expectedFidelity:(long long)expected {
    long long actual=%orig;
    record([NSString stringWithFormat:@"FIDELITY date=%@ expected=%lld actual=%lld",[date isKindOfClass:[NSDate class]] ? date : @"unknown",expected,actual]);
    return actual;
}
%end
%end
%group Spec
%hook BLSHEnvironmentDateSpecifier
- (id)initWithPresentationDate:(id)date fidelity:(long long)fidelity environment:(id)environment userObject:(id)userObject {
    id result=%orig;
    record([NSString stringWithFormat:@"FRAME date=%@ fidelity=%lld environmentClass=%@",[date isKindOfClass:[NSDate class]] ? date : @"unknown",fidelity,NSStringFromClass([environment class])]);
    return result;
}
%end
%end
%ctor {
    @autoreleasepool {
        logger=os_log_create("com.aodseconds.experimental","timeline");
        guard=[NSObject new];
        path=@"/var/mobile/Media/AODSeconds-diagnostic.txt";
        [@"AODSeconds 0.1.6 - read-only Flipbook timeline probe\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        record(@"INJECTED");
        Class e=objc_getClass("BLSHAlwaysOnPresentationEngine");
        if(matches(e,@selector(startFlipbookAndEnsureCurrent),"v16@0:8") && matches(e,@selector(startLiveUpdates),"v16@0:8")) {
            %init(Engine,BLSHAlwaysOnPresentationEngine=e);
            record(@"ENGINE hooks installed");
        }
        Class d=objc_getClass("BLSHEnvironmentDatesModel");
        if(matches(d,@selector(registerSpecifiers:forDateInterval:),"v32@0:8@16@24") && matches(d,@selector(specifierForDate:),"@24@0:8@16")) {
            %init(Dates,BLSHEnvironmentDatesModel=d);
            record(@"DATES hooks installed");
        }
        Class b=objc_getClass("BLSHInactiveProcessMinutesBudget");
        if(matches(b,@selector(allowedFidelityAtDate:expectedFidelity:),"q32@0:8@16q24")) {
            %init(Budget,BLSHInactiveProcessMinutesBudget=b);
            record(@"BUDGET hook installed");
        }
        Class s=objc_getClass("BLSHEnvironmentDateSpecifier");
        if(matches(s,@selector(initWithPresentationDate:fidelity:environment:userObject:),"@48@0:8@16q24@32@40")) {
            %init(Spec,BLSHEnvironmentDateSpecifier=s);
            record(@"SPEC hook installed");
        }
    }
}
