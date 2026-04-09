// From KIF — UIEvent setup with IOHIDEvent for touch synthesis.
#import <UIKit/UIKit.h>

@interface UIEvent (KIFAdditionsPrivateHeaders)
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)arg2;
- (void)_clearTouches;
@end

@interface UIEvent (KIFAdditions)
- (void)kif_setEventWithTouches:(NSArray *)touches;
@end
