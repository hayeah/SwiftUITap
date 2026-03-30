#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges JSON params to typed @objc method arguments via NSInvocation.
@interface TapDispatch : NSObject

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

/// List property names from the ObjC runtime for the given class (own properties only).
+ (NSArray<NSString *> *)propertyNamesForClass:(Class)cls;

/// Execute a block, catching any ObjC exception and converting it to an NSError.
/// Returns YES on success, NO if an exception was caught.
+ (BOOL)tryCatch:(void (NS_NOESCAPE ^)(void))tryBlock error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
