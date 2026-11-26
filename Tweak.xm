#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#include <atomic>
#include <string.h>
#include <math.h>
static NSString *path;
static NSObject *guard;
static os_log_t logger;
static std::atomic<unsigned> events{0};
static std::atomic<unsigned> frameLogs{0};
static std::atomic<unsigned> stringLogs{0};
static std::atomic<unsigned> intervalLogs{0};
static std::atomic<unsigned> labelLogs{0};
static void record(NSString *s) {
    if (++events > 1600) return;
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
    if ([NSStringFromClass([frame class]) isEqualToString:@"BLSAlwaysOnFrameSpecifier"]) {
        id interval=objectGetter(frame,"presentationInterval");
        if ([interval isKindOfClass:[NSDateInterval class]]) {
            NSDate *start=[(NSDateInterval *)interval startDate];
            if(++intervalLogs<=8 || intervalLogs.load()%60==0) record([NSString stringWithFormat:@"CLOCK INTERVAL start=%@ end=%@",start,[(NSDateInterval *)interval endDate]]);
            return start;
        }
    }
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
    return [NSString stringWithFormat:@"%@:%@:%02ld",parts[0],parts[1],(long)second];
}
static std::atomic<unsigned> timelineProbes{0};
static NSMutableSet *timelineClasses;
static void inspectTimeline(id value, unsigned depth) {
    if(!value || depth>3) return;
    if([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
        record([NSString stringWithFormat:@"CLOCK TIMELINE container=%@ count=%lu",NSStringFromClass([value class]),(unsigned long)[value count]]);
        unsigned i=0; for(id item in value) { if(i++>=3) break; inspectTimeline(item,depth+1); } return;
    }
    if([value isKindOfClass:[NSDictionary class]]) {
        record([NSString stringWithFormat:@"CLOCK TIMELINE dictionary count=%lu",(unsigned long)[value count]]);
        unsigned i=0; for(id key in value) { if(i++>=3) break; inspectTimeline([value objectForKey:key],depth+1); } return;
    }
    if([value isKindOfClass:[NSDate class]] || [value isKindOfClass:[NSDateInterval class]]) {
        record([NSString stringWithFormat:@"CLOCK TIMELINE date=%@",value]); return;
    }
    Class cls=object_getClass(value);
    NSString *name=NSStringFromClass(cls);
    record([NSString stringWithFormat:@"CLOCK TIMELINE object=%@",name]);
    BOOL fresh=NO;
    @synchronized(guard) {
        if(!timelineClasses) timelineClasses=[NSMutableSet new];
        if(![timelineClasses containsObject:name] && timelineClasses.count<12) { [timelineClasses addObject:name]; fresh=YES; }
    }
    if(fresh) {
        unsigned n=0; Method *ms=class_copyMethodList(cls,&n);
        for(unsigned i=0;i<MIN(n,60);i++) record([NSString stringWithFormat:@"TIMELINE API %@ %@ %s",name,NSStringFromSelector(method_getName(ms[i])),method_getTypeEncoding(ms[i])]);
        free(ms);
        Ivar *iv=class_copyIvarList(cls,&n);
        for(unsigned i=0;i<MIN(n,30);i++) record([NSString stringWithFormat:@"TIMELINE IVAR %@ %s %s",name,ivar_getName(iv[i]),ivar_getTypeEncoding(iv[i])]);
        free(iv);
    }
    const char *getters[]={"entries","entrySpecifiers","dateSpecifiers","dates","dateInterval","presentationInterval","date","startDate","endDate"};
    for(const char *getter:getters) {
        id child=objectGetter(value,getter);
        if(child && child!=value && ([child isKindOfClass:[NSArray class]] || [child isKindOfClass:[NSDictionary class]] || [child isKindOfClass:[NSSet class]] || [child isKindOfClass:[NSDate class]] || [child isKindOfClass:[NSDateInterval class]])) {
            record([NSString stringWithFormat:@"TIMELINE GET %@ %s",name,getter]);
            inspectTimeline(child,depth+1);
        }
    }
}
static thread_local unsigned clockTimelineDepth=0;
static std::atomic<unsigned> frequencyLogs{0};
static BOOL secondsAllowed(void) {
    NSProcessInfo *info=[NSProcessInfo processInfo];
    return !info.lowPowerModeEnabled && info.thermalState<NSProcessInfoThermalStateSerious;
}
%group Frequency
%hook BLSAlwaysOnFrequencyPerMinuteTimeline
- (id)initWithPerMinuteUpdateFrequency:(long long)frequency identifier:(id)identifier configure:(id)configure {
    long long effective=(clockTimelineDepth && (frequency==1 || frequency==4) && secondsAllowed())?60:frequency;
    id result=%orig(effective,identifier,configure);
    if(clockTimelineDepth && ++frequencyLogs<=40) record([NSString stringWithFormat:@"CLOCK FREQUENCY init %lld -> %lld",frequency,effective]);
    return result;
}
%end
%end
static void adjustClockTimeline(id result) {
    if(!secondsAllowed() || ![result isKindOfClass:[NSArray class]] || [result count]!=1) return;
    id timeline=[result firstObject];
    Class cls=objc_getClass("BLSAlwaysOnFrequencyPerMinuteTimeline");
    if(!cls || object_getClass(timeline)!=cls) return;
    Ivar iv=class_getInstanceVariable(cls,"_frequencyPerMinute");
    if(!iv || strcmp(ivar_getTypeEncoding(iv),"q")!=0) return;
    ptrdiff_t offset=ivar_getOffset(iv);
    if(offset<0 || (size_t)offset+sizeof(long long)>class_getInstanceSize(cls)) return;
    unsigned char *bytes=(unsigned char *)(__bridge void *)timeline;
    long long value=0;
    memcpy(&value,bytes+offset,sizeof(value));
    if(value==1 || value==4) {
        long long target=60;
        memcpy(bytes+offset,&target,sizeof(target));
        if(++frequencyLogs<=40) record([NSString stringWithFormat:@"CLOCK FREQUENCY returned timeline %lld -> 60",value]);
    } else if(++frequencyLogs<=40) record([NSString stringWithFormat:@"CLOCK FREQUENCY returned timeline %lld",value]);
}
static char clockTimelineTag;
static BOOL markedSecondsTimeline(id timeline) {
    return timeline && [objc_getAssociatedObject(timeline,&clockTimelineTag) boolValue];
}
%group ClockFidelity
%hook BLSAlwaysOnFrequencyPerMinuteTimeline
- (long long)requestedFidelityForStartEntryInDateInterval:(id)interval withPreviousEntry:(id)previous {
    long long original=%orig;
    if(markedSecondsTimeline(self) && secondsAllowed() && original==1) return 2;
    return original;
}
%end
%end
%group FrameFidelity
%hook BLSAlwaysOnFrameSpecifier
- (void)setGrantedFidelity:(long long)fidelity {
    id interval=objectGetter(self,"presentationInterval");
    long long requested=0;
    if(matches(object_getClass(self),@selector(requestedFidelity),"q16@0:8")) requested=((long long(*)(id,SEL))objc_msgSend)(self,@selector(requestedFidelity));
    if(fidelity==1 && requested==2 && secondsAllowed() && [interval isKindOfClass:[NSDateInterval class]] && [(NSDateInterval *)interval duration]>0 && [(NSDateInterval *)interval duration]<=1.01) {
        %orig(2);
        return;
    }
    %orig;
}
%end
%end
%group ClockTimeline
%hook SBFLockScreenDateViewController
- (id)_timelinesForDateInterval:(id)interval {
    id result=nil;
    ++clockTimelineDepth;
    @try { result=%orig; }
    @finally { --clockTimelineDepth; }
    if([interval isKindOfClass:[NSDateInterval class]]) {
        adjustClockTimeline(result);
        if(secondsAllowed() && [result isKindOfClass:[NSArray class]] && [result count]==1 && object_getClass([result firstObject])==objc_getClass("BLSAlwaysOnFrequencyPerMinuteTimeline")) objc_setAssociatedObject([result firstObject],&clockTimelineTag,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if(++timelineProbes<=3) {
        @try {
            record([NSString stringWithFormat:@"CLOCK TIMELINE request=%@ resultClass=%@",[interval isKindOfClass:[NSDateInterval class]]?interval:@"unknown",NSStringFromClass([result class])]);
            inspectTimeline(result,0);
        } @catch(NSException *e) { record(@"CLOCK TIMELINE inspection exception"); }
    }
    return result;
}
%end
%end
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
        } else if(++labelLogs<=4) record([NSString stringWithFormat:@"CLOCK LABEL unavailable class=%@",NSStringFromClass([label class])]);
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
    if (out && ![out isEqual:original] && (++stringLogs<=8 || stringLogs.load()%120==0)) record([NSString stringWithFormat:@"CLOCK STRING %@ -> %@",original,out]);
    return out;
}
%end
%end
static void installClock(void) {
    Class timelineClass=objc_getClass("BLSAlwaysOnFrequencyPerMinuteTimeline");
    if(matches(timelineClass,@selector(requestedFidelityForStartEntryInDateInterval:withPreviousEntry:),"q32@0:8@16@24")) { %init(ClockFidelity,BLSAlwaysOnFrequencyPerMinuteTimeline=timelineClass); }
    Class frameClass=objc_getClass("BLSAlwaysOnFrameSpecifier");
    if(matches(frameClass,@selector(setGrantedFidelity:),"v24@0:8q16")) { %init(FrameFidelity,BLSAlwaysOnFrameSpecifier=frameClass); }
    record(@"CLOCK frame fidelity policy checked");
    Class frequencyClass=objc_getClass("BLSAlwaysOnFrequencyPerMinuteTimeline");
    if(matches(frequencyClass,@selector(initWithPerMinuteUpdateFrequency:identifier:configure:),"@40@0:8q16@24@?32")) {
        %init(Frequency,BLSAlwaysOnFrequencyPerMinuteTimeline=frequencyClass);
        record(@"CLOCK frequency hook installed");
    } else record(@"CLOCK frequency initializer unavailable; scoped returned timeline fallback only");
    Class c=objc_getClass("SBFLockScreenDateViewController");
    if(matches(c,@selector(_timelinesForDateInterval:),"@24@0:8@16")) {
        %init(ClockTimeline,SBFLockScreenDateViewController=c);
        record(@"CLOCK timeline hook installed");
    } else record(@"CLOCK timeline signature unavailable");
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
static __attribute__((unused)) NSArray *experiment(NSArray *items, id interval) {
    if (items.count != 11 || ![interval isKindOfClass:[NSDateInterval class]]) return items;
    uint64_t now=mach_continuous_time(), zero=0;
    began.compare_exchange_strong(zero,now);
    if((double)(now-began.load())*tb.numer/tb.denom/1e9>120 || batches.load()>=3) return items;
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
        if(getFidelity(items[1],fidelitySel)!=1) { record(@"SKIP unexpected fidelity"); return items; }
        NSMutableArray *out=[NSMutableArray arrayWithObject:items[0]];
        NSUInteger index=1, added=0;
        NSDate *firstAdded=nil, *lastAdded=nil;
        NSTimeInterval base=floor(MAX(first.timeIntervalSince1970,NSDate.date.timeIntervalSince1970));
        for(int i=1;i<=30;i++){
            NSDate *date=[NSDate dateWithTimeIntervalSince1970:base+i];
            if([date compare:[(NSDateInterval*)interval endDate]]!=NSOrderedAscending) break;
            while(index<items.count && [getDate(items[index],dateSel) compare:date]!=NSOrderedDescending) {
                [out addObject:items[index++]];
            }
            NSDate *last=getDate(out.lastObject,dateSel);
            if([last compare:date]!=NSOrderedAscending || index>=items.count) continue;
            if(getFidelity(items[index],fidelitySel)!=1) return items;
            id frame=make([cls alloc],factory,date,1,getDate(items[index],userSel));
            if(!frame || [frame class]!=cls || ![getDate(frame,dateSel) isEqual:date] || getFidelity(frame,fidelitySel)!=1) { record(@"SKIP factory result mismatch"); return items; }
            [out addObject:frame];
            if(!firstAdded) firstAdded=date;
            lastAdded=date;
            added++;
        }
        while(index<items.count) [out addObject:items[index++]];
        if(!added || batches.fetch_add(1)>=3) return items;
        record([NSString stringWithFormat:@"EXPERIMENT batch=%u added=%lu continuous specifiers %@ to %@",batches.load(),(unsigned long)added,firstAdded,lastAdded]);
        return out;
    } @catch(NSException *e) { record(@"SKIP exception; original timeline retained"); return items; }
}
static thread_local bool switchingToLive=false;
%group Engine
%hook BLSHAlwaysOnPresentationEngine
- (void)startFlipbookAndEnsureCurrent {
    record(@"ENGINE startFlipbookAndEnsureCurrent");
    if(switchingToLive) { %orig; return; }
    %orig;
    if(![NSThread isMainThread] || !secondsAllowed()) return;
    SEL live=sel_registerName("startLiveUpdates");
    if(!matches(object_getClass(self),live,"v16@0:8")) return;
    switchingToLive=true;
    @try {
        record(@"ENGINE requesting native live updates after flipbook start");
        ((void(*)(id,SEL))objc_msgSend)(self,live);
    } @catch(NSException *e) {
        record(@"ENGINE live request failed; original flipbook retained");
    } @finally { switchingToLive=false; }
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
    id output=specifiers;
    %orig(output,interval);
}
- (id)specifierForDate:(id)date {
    id result=%orig;
    record([NSString stringWithFormat:@"LOOKUP date=%@ resultClass=%@",[date isKindOfClass:[NSDate class]] ? date : @"unknown",NSStringFromClass([result class])]);
    return result;
}
%end
%end
%group ContinuousPower
%hook BLSHAlwaysOnPresentationEngine
- (BOOL)isFlipbookPowerSavingEnabled {
    BOOL original=%orig;
    if(original && secondsAllowed()) return NO;
    return original;
}
%end
%end
%group Budget
%hook BLSHInactiveProcessMinutesBudget
- (long long)allowedFidelityAtDate:(id)date expectedFidelity:(long long)expected {
    long long actual=%orig;
    if(expected==2 && actual<2 && secondsAllowed()) {
        if(++budgetLogs<=40 || budgetLogs.load()%60==0) record(@"FIDELITY preserve requested seconds fidelity");
        return 2;
    }
    if(++budgetLogs<=12 || budgetLogs.load()%60==0 || actual<expected) record([NSString stringWithFormat:@"FIDELITY date=%@ expected=%lld actual=%lld",[date isKindOfClass:[NSDate class]] ? date : @"unknown",expected,actual]);
    return actual;
}
%end
%end
%group Spec
%hook BLSHEnvironmentDateSpecifier
- (id)initWithPresentationDate:(id)date fidelity:(long long)fidelity environment:(id)environment userObject:(id)userObject {
    id result=%orig;
    if(++frameLogs<=12 || frameLogs.load()%60==0) record([NSString stringWithFormat:@"FRAME date=%@ fidelity=%lld environmentClass=%@",[date isKindOfClass:[NSDate class]] ? date : @"unknown",fidelity,NSStringFromClass([environment class])]);
    return result;
}
%end
%end
%ctor {
    @autoreleasepool {
        logger=os_log_create("com.aodseconds.experimental","timeline");
        guard=[NSObject new];
        path=@"/var/mobile/Media/AODSeconds-diagnostic.txt";
        [@"AODSeconds 0.3.5 - native live presentation request\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        mach_timebase_info(&tb);
        record(@"INJECTED");
        dispatch_async(dispatch_get_main_queue(), ^{ installClock(); });
        Class e=objc_getClass("BLSHAlwaysOnPresentationEngine");
        if(matches(e,@selector(startFlipbookAndEnsureCurrent),"v16@0:8") && matches(e,@selector(startLiveUpdates),"v16@0:8")) {
            %init(Engine,BLSHAlwaysOnPresentationEngine=e);
            record(@"ENGINE hooks installed");
        }
        if(matches(e,@selector(isFlipbookPowerSavingEnabled),"B16@0:8") || matches(e,@selector(isFlipbookPowerSavingEnabled),"c16@0:8")) {
            %init(ContinuousPower,BLSHAlwaysOnPresentationEngine=e);
            record(@"ENGINE continuous flipbook policy installed");
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
