// From KIF — text input via private UIKeyboardImpl API.

#import "KIFTypist.h"

@interface UIKeyboardTaskQueue : NSObject
- (void)waitUntilAllTasksAreFinished;
@end

@interface UIKeyboardImpl : NSObject
+ (UIKeyboardImpl *)sharedInstance;
- (void)addInputString:(NSString *)string;
- (void)deleteFromInput;
@property (readonly, nonatomic) UIKeyboardTaskQueue *taskQueue;
@end

static NSTimeInterval keystrokeDelay = 0.001f;

@implementation KIFTypist

+ (BOOL)enterCharacter:(NSString *)characterString
{
    if ([characterString isEqualToString:@"\b"]) {
        [[UIKeyboardImpl sharedInstance] deleteFromInput];
    } else {
        [[UIKeyboardImpl sharedInstance] addInputString:characterString];
    }

    [[[UIKeyboardImpl sharedInstance] taskQueue] waitUntilAllTasksAreFinished];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, keystrokeDelay, false);
    return YES;
}

@end
