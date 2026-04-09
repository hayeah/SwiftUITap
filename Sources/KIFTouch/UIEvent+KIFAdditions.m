// From KIF — UIEvent setup with IOHIDEvent for touch synthesis.

#import "UIEvent+KIFAdditions.h"
#import "LoadableCategory.h"
#import "IOHIDEvent+KIF.h"

MAKE_CATEGORIES_LOADABLE(UIEvent_KIFAdditions)

@interface UIEvent (KIFAdditionsMorePrivateHeaders)
- (void)_setHIDEvent:(IOHIDEventRef)event;
- (void)_setTimestamp:(NSTimeInterval)timestamp;
@end

@implementation UIEvent (KIFAdditions)

- (void)kif_setEventWithTouches:(NSArray *)touches
{
    IOHIDEventRef event = kif_IOHIDEventWithTouches(touches);
    [self _setHIDEvent:event];
    CFRelease(event);
}

@end
