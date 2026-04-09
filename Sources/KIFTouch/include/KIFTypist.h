#import <Foundation/Foundation.h>

/// Text input via private UIKeyboardImpl API.
/// Keyboard must already be visible (a text field must be first responder).
@interface KIFTypist : NSObject

+ (BOOL)enterCharacter:(NSString *)characterString;

@end
