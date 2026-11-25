#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
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
    if (++events > 800) return;
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
static std::atomic<unsigned> batches{0};
static std::atomic<uint64_t> began{0};
static mach_timebase_info_data_t tb;
static std::atomic<unsigned> budgetLogs{0};
static std::atomic<bool> scanned{false};
static NSDate *frameDate;
static std::atomic<unsigned> clockCalls{0};
static id objectGetter(id obj, const char *name) {
    if (!obj) return nil;
    SEL sel=sel_registerName(name);
    if (!matches(object_getClass(obj),sel,"@16@0:8")) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(obj,sel);
}
static std::atomic<bool> frameScanned{false};
static void inspectFrame(id frame) {
    if (!frame || frameScanned.exchange(true)) return;
    for(Class cls=object_getClass(frame);cls && cls!=[NSObject class];cls=class_getSuperclass(cls)) {
        record([NSString stringWithFormat:@"FRAME CLASS %@",NSStringFromClass(cls)]);
        unsigned n=0; Method *ms=class_copyMethodList(cls,&n);
        for(unsigned i=0;i<n;i++) record([NSString stringWithFormat:@"FRAME API %@ %s",NSStringFromSelector(method_getName(ms[i])),method_getTypeEncoding(ms[i])]);
        free(ms);
        Ivar *iv=class_copyIvarList(cls,&n);
        for(unsigned i=0;i<n;i++) record([NSString stringWithFormat:@"FRAME IVAR %s %s",ivar_getName(iv[i]),ivar_getTypeEncoding(iv[i])]);
        free(iv);
    }
}
static NSDate *dateFromFrame(id frame) {
    inspectFrame(frame);
    if ([frame isKindOfClass:[NSDate class]]) return frame;
    id value=objectGetter(frame,"date");
    if (![value isKindOfClass:[NSDate class]]) value=objectGetter(frame,"presentationDate");
    if (![value isKindOfClass:[NSDate class]]) value=objectGetter(objectGetter(frame,"dateSpecifier"),"date");
    if (![value isKindOfClass:[NSDate class]]) value=objectGetter(frame,"frameDate");
    if (![value isKindOfClass:[NSDate class]]) value=objectGetter(frame,"targetDate");
    if (![value isKindOfClass:[NSDate class]]) value=objectGetter(frame,"renderDate");
    if (![value isKindOfClass:[NSDate class]]) value=objectGetter(frame,"displayDate");
    return [value isKindOfClass:[NSDate class]] ? value : nil;
}
static NSString *secondsString(id original, NSDate *date) {
    if (![original isKindOfClass:[NSString class]] || !date) return original;
    NSString *s=original;
    NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"^[0-9]{1,2}:[0-9]{2}(:[0-9]{1,2})?$" options:0 error:NULL];
    if (![re numberOfMatchesInString:s options:0 range:NSMakeRange(0,s.length)]) return s;
    NSArray *parts=[s componentsSeparatedByString:@":"];
    NSInteger second=[[NSCalendar currentCalendar] component:NSCalendarUnitSecond fromDate:date];
    return [NSString stringWithFormat:@"%@:%@:%ld",parts[0],parts[1],(long)second];
}
%group ClockController
%hook SBFLockScreenDateViewController
- (void)_updateWithFrameSpecifier:(id)specifier {
    NSDate *date=dateFromFrame(specifier);
    BOOL scoped=[NSThread isMainThread] && date && [date timeIntervalSinceNow]>-60 && [date timeIntervalSinceNow]<610;
    if (++clockCalls<=80) record([NSString stringWithFormat:@"CLOCK FRAME class=%@ date=%@ scoped=%d",NSStringFromClass([specifier class]),date,scoped]);
    if (!scoped) { %orig; return; }
    NSDate *previous=frameDate;
    frameDate=date;
    @try {
        %orig;
        id view=objectGetter(self,"dateViewIfExists");
        id label=objectGetter(view,"_timeLabel");
        if ([label isKindOfClass:[UILabel class]]) {
            UILabel *l=(UILabel *)label;
            NSString *before=l.text;
            NSString *after=secondsString(before,date);
            if (after && ![after isEqualToString:before]) {
                NSAttributedString *attr=l.attributedText;
                if(attr.length && [attr.string isEqualToString:before]) {
                    NSMutableAttributedString *copy=[attr mutableCopy];
                    NSArray *parts=[before componentsSeparatedByString:@":"];
                    if(parts.count==3) {
                        NSRange last=[before rangeOfString:@":" options:NSBackwardsSearch];
                        [copy replaceCharactersInRange:NSMakeRange(last.location,before.length-last.location) withString:[after substringFromIndex:last.location]];
                    } else {
                        NSDictionary *style=[attr attributesAtIndex:attr.length-1 effectiveRange:NULL];
                        [copy appendAttributedString:[[NSAttributedString alloc] initWithString:[after substringFromIndex:before.length] attributes:style]];
                    }
                    l.attributedText=copy;
                } else l.text=after;
                record([NSString stringWithFormat:@"CLOCK LABEL %@ -> %@",before,after]);
            } else record([NSString stringWithFormat:@"CLOCK LABEL unchanged %@",before]);
        } else record([NSString stringWithFormat:@"CLOCK LABEL unavailable class=%@",NSStringFromClass([label class])]);
    } @finally { frameDate=previous; }
}
%end
%end
%group ProminentClock
%hook CSProminentTimeView
- (id)_timeString {
    id original=%orig;
    if (![NSThread isMainThread] || !frameDate) return original;
    NSString *out=secondsString(original,frameDate);
    if (out && ![out isEqual:original]) record([NSString stringWithFormat:@"CLOCK STRING %@ -> %@",original,out]);
    return out;
}
%end
%end
static void installClock(void) {
    Class c=objc_getClass("SBFLockScreenDateViewController");
    if(matches(c,@selector(_updateWithFrameSpecifier:),"v24@0:8@16")) {
        %init(ClockController,SBFLockScreenDateViewController=c);
        record(@"CLOCK controller hook installed");
    } else record(@"CLOCK controller signature unavailable");
    Class p=objc_getClass("CSProminentTimeView");
    if(matches(p,@selector(_timeString),"@16@0:8")) {
        %init(ProminentClock,CSProminentTimeView=p);
        record(@"CLOCK prominent hook installed");
    } else record(@"CLOCK prominent signature unavailable");
}
static NSArray *experiment(NSArray *items, id interval) {
    if (items.count != 11 || ![interval isKindOfClass:[NSDateInterval class]]) return items;
    uint64_t now=mach_continuous_time(), zero=0;
    began.compare_exchange_strong(zero,now);
    if((double)(now-began.load())*tb.numer/tb.denom/1e9>120 || batches.load()>=6) return items;
    Class cls=objc_getClass("BLSAlwaysOnDateSpecifier");
    if (!cls) { record(@"SKIP no specifier class"); return items; }
    if(!scanned.exchange(true)) for(int meta=0;meta<2;meta++){
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
        if(batches.fetch_add(1)>=6) return items;
        record([NSString stringWithFormat:@"EXPERIMENT batch=%u five extra specifiers %@ to %@",batches.load(),getDate(out[1],dateSel),getDate(out[5],dateSel)]);
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
    if(++budgetLogs<=12) record([NSString stringWithFormat:@"FIDELITY date=%@ expected=%lld actual=%lld",[date isKindOfClass:[NSDate class]] ? date : @"unknown",expected,actual]);
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
        [@"AODSeconds 0.2.1 - frame metadata and scoped clock experiment\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        mach_timebase_info(&tb);
        record(@"INJECTED");
        dispatch_async(dispatch_get_main_queue(), ^{ installClock(); });
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
