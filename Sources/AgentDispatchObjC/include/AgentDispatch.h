#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges JSON params to typed @objc method arguments via NSInvocation.
@interface AgentDispatch : NSObject

/// Call a method on target by name, passing params extracted from a JSON dictionary.
/// Returns the method's return value (if it returns an object), or nil.
+ (nullable id)call:(id)target method:(NSString *)name params:(NSDictionary *)params error:(NSError **)error;

/// Extract parameter names from an ObjC selector.
/// e.g. "openBookWithBookID:chapter:" → ["bookID", "chapter"]
+ (NSArray<NSString *> *)paramNamesFromSelector:(SEL)sel;

/// Find a selector on the given class whose base name matches the method name.
/// Looks for selectors starting with `name` (before first "With" or ":").
+ (nullable NSValue *)findSelector:(NSString *)name onClass:(Class)cls;

/// List all @objc method names callable on the given class (excluding NSObject methods).
+ (NSArray<NSString *> *)callableMethodNames:(Class)cls;

@end

NS_ASSUME_NONNULL_END
