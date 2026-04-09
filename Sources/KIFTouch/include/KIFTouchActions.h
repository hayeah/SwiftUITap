#import <UIKit/UIKit.h>

/// High-level touch synthesis actions using KIF's private API approach.
/// All methods must be called on the main thread.
@interface KIFTouchActions : NSObject

/// Tap at a point in screen coordinates.
+ (void)tapAtPoint:(CGPoint)point inWindow:(UIWindow *)window;

/// Long press at a point for the given duration (seconds).
+ (void)longPressAtPoint:(CGPoint)point duration:(NSTimeInterval)duration inWindow:(UIWindow *)window;

/// Swipe from one point to another over the given duration.
/// Duration controls the number of intermediate steps (duration / 0.01).
+ (void)swipeFromPoint:(CGPoint)start toPoint:(CGPoint)end duration:(NSTimeInterval)duration inWindow:(UIWindow *)window;

@end
