#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
static std::atomic<bool> attempted{false};
static NSArray *experiment(NSArray *items, id interval) {
    if (items.count != 11 || ![interval isKindOfClass:[NSDateInterval class]]) return items;
    if (attempted.exchange(true)) return items;
    Class cls=objc_getClass("BLSAlwaysOnDateSpecifier");
    if (!cls) { record(@"SKIP no specifier class"); return items; }
    for(int meta=0;meta<2;meta++){
        unsigned n=0; Method *ms=class_copyMethodList(meta?object_getClass(cls):cls,&n);
        for(unsigned i=0;i<n;i++) record([NSString stringWithFormat:@"API %c %@ %s",meta?'+':'-',NSStringFromSelector(method_getName(ms[i])),method_getTypeEncoding(ms[i])]);
        free(ms);
    }
    SEL dateSel=sel_registerName("date");
    SEL fidelitySel=sel_registerName("fidelity");
    SEL factory=sel_registerName("initWithDate:fidelity:userObject:");
    SEL userSel=sel_registerName("userObject");
    if(!matches(cls,dateSel,"@16@0:8") || !matches(cls,fidelitySel,"q16@0:8") || !matches(cls,factory,"@40@0:8@16q24@32") || !matches(cls,userSel,"@16@0:8")) {
        record(@"SKIP unverified date/fidelity initializer; original timeline retained"); return items;
    }
    @try {
        id (*getDate)(id,SEL)=(id(*)(id,SEL))objc_msgSend;
        long long (*getFidelity)(id,SEL)=(long long(*)(id,SEL))objc_msgSend;
        id (*make)(id,SEL,id,long long,id)=(id(*)(id,SEL,id,long long,id))objc_msgSend;
        NSDate *previous=nil;
        for(id item in items){
            if([item class]!=cls) return items;
            id date=getDate(item,dateSel);
            if(![date isKindOfClass:[NSDate class]] || (previous && [previous compare:date]!=NSOrderedAscending)) return items;
            previous=date;
        }
        NSDate *first=getDate(items[0],dateSel);
        NSDate *next=getDate(items[1],dateSel);
        if([next timeIntervalSinceDate:first]<10 || getFidelity(items[1],fidelitySel)!=1) { record(@"SKIP unexpected timeline"); return items; }
        NSMutableArray *out=[items mutableCopy];
        for(int i=1;i<=5;i++){
            NSDate *date=[next dateByAddingTimeInterval:-6+i];
            if ([date compare:first]!=NSOrderedDescending) return items;
            if([date compare:[(NSDateInterval*)interval endDate]]!=NSOrderedAscending || [date timeIntervalSinceNow]<=0) { record(@"SKIP date outside future interval"); return items; }
            id frame=make([cls alloc],factory,date,1,getDate(items[1],userSel));
            if(!frame || [frame class]!=cls || ![getDate(frame,dateSel) isEqual:date] || getFidelity(frame,fidelitySel)!=1) { record(@"SKIP factory result mismatch"); return items; }
            [out insertObject:frame atIndex:i];
        }
        record(@"EXPERIMENT registered five extra one-second specifiers; original entries preserved");
        return out;
    } @catch(NSException *e) { record(@"SKIP exception; original timeline retained"); return items; }
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
    id output=[specifiers isKindOfClass:[NSArray class]] ? experiment(specifiers,interval) : specifiers;
    %orig(output,interval);
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
        [@"AODSeconds 0.1.8 - verified initializer five-frame experiment\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
