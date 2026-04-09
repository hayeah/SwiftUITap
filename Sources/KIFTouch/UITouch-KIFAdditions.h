// From KIF — synthetic UITouch creation with private setters.
#import <UIKit/UIKit.h>

@interface UITouch (KIFAdditions)

- (id)initInView:(UIView *)view;
- (id)initAtPoint:(CGPoint)point inView:(UIView *)view;
- (id)initAtPoint:(CGPoint)point inWindow:(UIWindow *)window;

- (void)setLocationInWindow:(CGPoint)location;
- (void)setPhaseAndUpdateTimestamp:(UITouchPhase)phase;
- (void)setIsFromEdge:(BOOL)isFromEdge;

@end
