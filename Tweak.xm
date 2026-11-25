#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/log.h>

static char kLabel, kTimer, kStarted;
static os_log_t ASLog;
static void ASStop(UIView *v) {
    NSTimer *t = objc_getAssociatedObject(v, &kTimer);
    [t invalidate];
    objc_setAssociatedObject(v, &kTimer, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL ASVisible(UIView *v) {
    if (!v.window) return NO;
    for (; v; v = v.superview) if (v.hidden || v.alpha < 0.01) return NO;
    return YES;
}
static void ASUpdate(UILabel *l) {
    NSInteger s = [[NSCalendar currentCalendar] component:NSCalendarUnitSecond fromDate:[NSDate date]];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    l.text = [NSString stringWithFormat:@":%ld", (long)s];
    [l setNeedsDisplay];
    [l.layer setNeedsDisplay];
    [CATransaction commit];
    [CATransaction flush];
}
static void ASLayout(UIView *v) {
    if (!v.window || CGRectGetWidth(v.bounds)<70 || CGRectGetHeight(v.bounds)<35) return;
    UILabel *l = objc_getAssociatedObject(v, &kLabel);
    if (!l) {
        l = [[UILabel alloc] initWithFrame:CGRectZero];
        l.font = [UIFont monospacedDigitSystemFontOfSize:32 weight:UIFontWeightMedium];
        l.textColor = UIColor.whiteColor;
        l.userInteractionEnabled = NO;
        l.isAccessibilityElement = NO;
        objc_setAssociatedObject(v, &kLabel, l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [v addSubview:l];
    }
    UILabel *clock = nil;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithArray:v.subviews];
    while (pending.count) {
        UIView *c = pending.lastObject;
        [pending removeLastObject];
        if (c == l || c.hidden || c.alpha < 0.01) continue;
        if ([c isKindOfClass:UILabel.class]) {
            UILabel *item = (UILabel *)c;
            if ([item.text containsString:@":"] && (!clock || item.font.pointSize > clock.font.pointSize)) clock = item;
        }
        [pending addObjectsFromArray:c.subviews];
    }
    CGRect r = v.bounds;
    if (clock) {
        r = [clock convertRect:[clock textRectForBounds:clock.bounds limitedToNumberOfLines:1] toView:v];
        l.font = [clock.font fontWithSize:clock.font.pointSize * 0.55];
        l.textColor = clock.textColor;
    }
    CGFloat h = ceil(l.font.lineHeight);
    CGFloat w = ceil([@":59" sizeWithAttributes:@{NSFontAttributeName:l.font}].width)+4;
    l.frame = CGRectMake(MAX(CGRectGetMinX(v.bounds), MIN(CGRectGetMaxX(r)+2, CGRectGetMaxX(v.bounds)-w)), MAX(CGRectGetMinY(v.bounds), MIN(CGRectGetMaxY(r)-h+(clock ? clock.font.descender-l.font.descender : 0), CGRectGetMaxY(v.bounds)-h)), w, h);
    [v bringSubviewToFront:l];
    if (objc_getAssociatedObject(v,&kStarted) || !ASVisible(v)) return;
    objc_setAssociatedObject(v,&kStarted,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ASUpdate(l);
    __weak UIView *weakView = v;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120];
    __block NSUInteger ticks = 0;
    __block NSTimeInterval previous = [NSDate date].timeIntervalSince1970;
    NSTimer *timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        UIView *view = weakView;
        if (!view || !ASVisible(view) || deadline.timeIntervalSinceNow <= 0) {
            [t invalidate];
            if (view) {
                ASStop(view);
                UILabel *suffix = objc_getAssociatedObject(view,&kLabel);
                suffix.text = @":--";
            }
            os_log(ASLog,"session stop ticks=%{public}lu",(unsigned long)ticks);
            return;
        }
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        NSTimeInterval gap = now-previous;
        previous = now;
        UILabel *suffix = objc_getAssociatedObject(view,&kLabel);
        ASUpdate(suffix);
        if (++ticks % 5 == 0 || gap > 2.5) os_log(ASLog,"tick=%{public}lu seconds=%{public}@ gap=%{public}.2f",(unsigned long)ticks,suffix.text,gap);
    }];
    timer.tolerance = 0.05;
    objc_setAssociatedObject(v,&kTimer,timer,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}
%group ClockProbe
%hook CSProminentTimeView
- (void)layoutSubviews {
    %orig;
    ASLayout((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (!v.window) {
        ASStop(v);
        objc_setAssociatedObject(v,&kStarted,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UILabel *l = objc_getAssociatedObject(v,&kLabel);
        [l removeFromSuperview];
        objc_setAssociatedObject(v,&kLabel,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else ASLayout(v);
}
%end
%end
%ctor {
    @autoreleasepool {
        ASLog = os_log_create("com.aodseconds.experimental","probe");
        NSBundle *cover = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/CoverSheet.framework"];
        [cover load];
        NSBundle *kit = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/CoverSheetKit.framework"];
        [kit load];
        Class clock = objc_getClass("CSProminentTimeView");
        if (clock && [clock isSubclassOfClass:UIView.class]) {
            %init(ClockProbe, CSProminentTimeView = clock);
            os_log(ASLog,"hook installed; AOD engine class present=%{public}d",objc_getClass("BLSHAlwaysOnPresentationEngine") != Nil);
        } else {
            os_log_error(ASLog,"CSProminentTimeView unavailable");
        }
    }
}
