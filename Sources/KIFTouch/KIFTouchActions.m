// High-level touch synthesis — consolidated from KIF's UIView-KIFAdditions
// and UIApplication-KIFAdditions.

#import "KIFTouchActions.h"
#import "UITouch-KIFAdditions.h"
#import "UIEvent+KIFAdditions.h"

#define DRAG_TOUCH_DELAY 0.01

@interface UIApplication (KIFTouchPrivate)
- (UIEvent *)_touchesEvent;
@end

@implementation KIFTouchActions

#pragma mark - Event Construction

+ (UIEvent *)eventWithTouches:(NSArray<UITouch *> *)touches
{
    UIEvent *event = [[UIApplication sharedApplication] _touchesEvent];
    [event _clearTouches];
    [event kif_setEventWithTouches:touches];
    for (UITouch *aTouch in touches) {
        [event _addTouch:aTouch forDelayedDelivery:NO];
    }
    return event;
}

+ (UIEvent *)eventWithTouch:(UITouch *)touch
{
    return [self eventWithTouches:touch ? @[touch] : @[]];
}

+ (void)sendEvent:(UIEvent *)event
{
    [[UIApplication sharedApplication] sendEvent:event];
}

#pragma mark - Tap

+ (void)tapAtPoint:(CGPoint)point inWindow:(UIWindow *)window
{
    UIView *rootView = window.rootViewController.view ?: window;
    CGPoint viewPoint = [rootView convertPoint:point fromView:window];

    UITouch *touch = [[UITouch alloc] initAtPoint:viewPoint inView:rootView];
    [touch setPhaseAndUpdateTimestamp:UITouchPhaseBegan];
    UIEvent *beganEvent = [self eventWithTouch:touch];
    [self sendEvent:beganEvent];

    [touch setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
    UIEvent *endedEvent = [self eventWithTouch:touch];
    [self sendEvent:endedEvent];
}

#pragma mark - Long Press

+ (void)longPressAtPoint:(CGPoint)point duration:(NSTimeInterval)duration inWindow:(UIWindow *)window
{
    UIView *rootView = window.rootViewController.view ?: window;
    CGPoint viewPoint = [rootView convertPoint:point fromView:window];

    UITouch *touch = [[UITouch alloc] initAtPoint:viewPoint inView:rootView];
    [touch setPhaseAndUpdateTimestamp:UITouchPhaseBegan];

    UIEvent *eventDown = [self eventWithTouch:touch];
    [self sendEvent:eventDown];

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, DRAG_TOUCH_DELAY, false);

    for (NSTimeInterval timeSpent = DRAG_TOUCH_DELAY; timeSpent < duration; timeSpent += DRAG_TOUCH_DELAY) {
        [touch setPhaseAndUpdateTimestamp:UITouchPhaseStationary];
        UIEvent *eventStillDown = [self eventWithTouch:touch];
        [self sendEvent:eventStillDown];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, DRAG_TOUCH_DELAY, false);
    }

    [touch setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
    UIEvent *eventUp = [self eventWithTouch:touch];
    [self sendEvent:eventUp];
}

#pragma mark - Swipe / Drag

+ (void)swipeFromPoint:(CGPoint)start toPoint:(CGPoint)end duration:(NSTimeInterval)duration inWindow:(UIWindow *)window
{
    NSUInteger stepCount = MAX((NSUInteger)(duration / DRAG_TOUCH_DELAY), 3);

    UIView *rootView = window.rootViewController.view ?: window;

    // Build path in window coordinates
    NSMutableArray<NSValue *> *path = [NSMutableArray arrayWithCapacity:stepCount];
    for (NSUInteger i = 0; i < stepCount; i++) {
        CGFloat progress = (CGFloat)i / (stepCount - 1);
        CGPoint p = CGPointMake(start.x + progress * (end.x - start.x),
                                start.y + progress * (end.y - start.y));
        [path addObject:[NSValue valueWithCGPoint:p]];
    }

    // First point — touch began
    CGPoint firstWindowPoint = [path[0] CGPointValue];
    CGPoint firstViewPoint = [rootView convertPoint:firstWindowPoint fromView:window];
    UITouch *touch = [[UITouch alloc] initAtPoint:firstViewPoint inView:rootView];
    [touch setPhaseAndUpdateTimestamp:UITouchPhaseBegan];

    UIEvent *eventDown = [self eventWithTouch:touch];
    [self sendEvent:eventDown];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, DRAG_TOUCH_DELAY, false);

    // Intermediate points — touch moved
    for (NSUInteger i = 1; i < stepCount; i++) {
        CGPoint windowPoint = [path[i] CGPointValue];
        [touch setLocationInWindow:windowPoint];
        [touch setPhaseAndUpdateTimestamp:UITouchPhaseMoved];

        UIEvent *event = [self eventWithTouch:touch];
        [self sendEvent:event];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, DRAG_TOUCH_DELAY, false);
    }

    // Touch ended
    [touch setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
    UIEvent *eventUp = [self eventWithTouch:touch];
    [self sendEvent:eventUp];
}

@end
