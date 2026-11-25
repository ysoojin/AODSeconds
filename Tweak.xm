#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>

static os_log_t logHandle;
static NSHashTable<UIView *> *views;
static NSTimer *timer;
static NSDate *deadline;
static char suffixKey;
static BOOL updating;
static BOOL isClock(UIView *v) {
    for (Class c = v.class; c; c = class_getSuperclass(c)) {
        NSString *n = NSStringFromClass(c);
        if ([n isEqualToString:@"CSProminentTimeView"] || [n isEqualToString:@"SBFLockScreenDateView"]) return YES;
    }
    return NO;
}
static BOOL visible(UIView *v) {
    if (!v.window) return NO;
    for (;v;v=v.superview) if (v.hidden || v.alpha < 0.01) return NO;
    return YES;
}
static void updateClock(UIView *v) {
    if (!visible(v) || updating) return;
    updating = YES;
    NSInteger sec = [[NSCalendar currentCalendar] component:NSCalendarUnitSecond fromDate:NSDate.date];
    UILabel *best = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:v.subviews];
    while (queue.count) {
        UIView *child = queue.lastObject;
        [queue removeLastObject];
        if (objc_getAssociatedObject(child,&suffixKey)) continue;
        if ([child isKindOfClass:UILabel.class]) {
            UILabel *l = (UILabel *)child;
            if (visible(l) && [l.text containsString:@":"] && (!best || l.font.pointSize > best.font.pointSize)) best = l;
        }
        [queue addObjectsFromArray:child.subviews];
    }
    if (best) {
        NSString *base = best.text;
        NSArray *parts = [base componentsSeparatedByString:@":"];
        if (parts.count >= 2) {
            if (parts.count == 3) base = [[parts subarrayWithRange:NSMakeRange(0,2)] componentsJoinedByString:@":"];
            NSString *text = [base stringByAppendingFormat:@":%ld",(long)sec];
            if (![best.text isEqualToString:text]) {
                best.adjustsFontSizeToFitWidth = YES;
                best.minimumScaleFactor = 0.5;
                best.text = text;
                [best setNeedsDisplay];
            }
        }
    } else {
        UILabel *l = objc_getAssociatedObject(v,&suffixKey);
        if (!l) {
            l = [[UILabel alloc] init];
            l.font = [UIFont monospacedDigitSystemFontOfSize:26 weight:UIFontWeightMedium];
            l.textColor = UIColor.whiteColor;
            l.textAlignment = NSTextAlignmentRight;
            l.userInteractionEnabled = NO;
            objc_setAssociatedObject(l,&suffixKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(v,&suffixKey,l,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [v addSubview:l];
            os_log(logHandle,"fallback label on %{public}@",NSStringFromClass(v.class));
        }
        l.frame = CGRectMake(MAX(0,CGRectGetWidth(v.bounds)-52),MAX(0,CGRectGetHeight(v.bounds)-34),50,32);
        l.text = [NSString stringWithFormat:@":%ld",(long)sec];
        [v bringSubviewToFront:l];
    }
    [CATransaction flush];
    updating = NO;
}
static void registerClock(UIView *v) {
    if (!v.window || !isClock(v)) return;
    if (![views containsObject:v]) {
        [views addObject:v];
        os_log(logHandle,"clock found: %{public}@",NSStringFromClass(v.class));
    }
    if (!timer) {
        deadline = [NSDate dateWithTimeIntervalSinceNow:120];
        timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t){
            if (deadline.timeIntervalSinceNow <= 0) {
                [t invalidate]; timer = nil;
                [views removeAllObjects];
                return;
            }
            for (UIView *clock in views.allObjects) updateClock(clock);
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    }
    updateClock(v);
}
%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!updating && self.window && isClock(self)) registerClock(self);
}
%end
%ctor {
    @autoreleasepool {
        logHandle = os_log_create("com.aodseconds.experimental","probe");
        views = [NSHashTable weakObjectsHashTable];
        os_log(logHandle,"AODSeconds 0.1.3 injected");
        %init;
    }
}
