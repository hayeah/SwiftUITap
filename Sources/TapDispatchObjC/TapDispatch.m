#import "TapDispatch.h"
#import <objc/runtime.h>

@implementation TapDispatch

+ (nullable id)call:(id)target method:(NSString *)name params:(NSDictionary *)params error:(NSError **)error {
    NSValue *selValue = [self findSelector:name onClass:[target class]];
    if (!selValue) {
        if (error) {
            *error = [NSError errorWithDomain:@"TapDispatch"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"unknown method: %@", name]}];
        }
        return nil;
    }

    SEL sel = [selValue pointerValue];
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) {
        if (error) {
            *error = [NSError errorWithDomain:@"TapDispatch"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"no method signature for: %@", name]}];
        }
        return nil;
    }

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    [inv retainArguments];

    NSArray<NSString *> *paramNames = [self paramNamesFromSelector:sel];

    for (NSUInteger i = 0; i < paramNames.count; i++) {
        NSString *key = paramNames[i];
        id value = params[key];
        NSUInteger argIndex = i + 2; // 0=self, 1=_cmd

        if (argIndex >= sig.numberOfArguments) break;

        const char *type = [sig getArgumentTypeAtIndex:argIndex];

        if (value == nil || [value isKindOfClass:[NSNull class]]) {
            // Skip nil/null args — leave default
            continue;
        }

        switch (type[0]) {
            case 'q': case 'l': { // Int (64-bit), long
                NSInteger v = [value integerValue];
                [inv setArgument:&v atIndex:argIndex];
                break;
            }
            case 'i': { // int (32-bit)
                int v = [value intValue];
                [inv setArgument:&v atIndex:argIndex];
                break;
            }
            case 'd': { // Double
                double v = [value doubleValue];
                [inv setArgument:&v atIndex:argIndex];
                break;
            }
            case 'f': { // Float
                float v = [value floatValue];
                [inv setArgument:&v atIndex:argIndex];
                break;
            }
            case 'B': { // Bool
                BOOL v = [value boolValue];
                [inv setArgument:&v atIndex:argIndex];
                break;
            }
            case '@': { // Object (String, NSDictionary, NSArray, etc.)
                [inv setArgument:&value atIndex:argIndex];
                break;
            }
            default: {
                if (error) {
                    *error = [NSError errorWithDomain:@"TapDispatch"
                                                 code:3
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"unsupported arg type '%s' for param '%@'", type, key]}];
                }
                return nil;
            }
        }
    }

    [inv invoke];

    const char *retType = sig.methodReturnType;
    if (retType[0] == '@') {
        id __unsafe_unretained result = nil;
        [inv getReturnValue:&result];
        return result ?: [NSNull null];
    }
    if (retType[0] == 'q' || retType[0] == 'l') {
        NSInteger result = 0;
        [inv getReturnValue:&result];
        return @(result);
    }
    if (retType[0] == 'i') {
        int result = 0;
        [inv getReturnValue:&result];
        return @(result);
    }
    if (retType[0] == 'd') {
        double result = 0;
        [inv getReturnValue:&result];
        return @(result);
    }
    if (retType[0] == 'f') {
        float result = 0;
        [inv getReturnValue:&result];
        return @(result);
    }
    if (retType[0] == 'B') {
        BOOL result = NO;
        [inv getReturnValue:&result];
        return @(result);
    }

    return [NSNull null]; // void return — must be non-nil for Swift NSError** bridging
}

+ (NSArray<NSString *> *)paramNamesFromSelector:(SEL)sel {
    NSString *selStr = NSStringFromSelector(sel);
    NSArray<NSString *> *parts = [selStr componentsSeparatedByString:@":"];

    NSMutableArray<NSString *> *names = [NSMutableArray array];

    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = parts[i];
        if (part.length == 0) continue;

        if (i == 0) {
            // First part: extract param name after "With" if present
            // e.g. "addTodoWithTitle" → "title"
            // e.g. "addTodo" (single param, no With) → skip, it's the method name
            NSRange withRange = [part rangeOfString:@"With" options:NSBackwardsSearch];
            if (withRange.location != NSNotFound && withRange.location + withRange.length < part.length) {
                NSString *paramName = [part substringFromIndex:withRange.location + withRange.length];
                // Lowercase first char
                paramName = [[[paramName substringToIndex:1] lowercaseString]
                             stringByAppendingString:[paramName substringFromIndex:1]];
                [names addObject:paramName];
            } else {
                // Check if this is a single-param method like "removeTodo:"
                // In that case the selector is just "removeTodo:" with one colon
                // We need to count total colons to know
                NSUInteger colonCount = [[selStr componentsSeparatedByString:@":"] count] - 1;
                if (colonCount == 1 && parts.count == 2 && parts[1].length == 0) {
                    // Single param, use the selector base as hint — look for the last camelCase word
                    // Actually, for explicit selectors like "removeTodo:", the param name IS the selector
                    // For Swift-generated ones, the first external param label goes here
                    // Best we can do: use the full base name as param name
                    [names addObject:part];
                }
            }
        } else {
            // Subsequent parts are param names directly
            // e.g. "chapter" from "openBook:chapter:"
            [names addObject:part];
        }
    }

    return names;
}

+ (nullable NSValue *)findSelector:(NSString *)name onClass:(Class)cls {
    // Walk the class hierarchy up to (but not including) NSObject
    Class current = cls;
    while (current && current != [NSObject class]) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(current, &methodCount);

        SEL bestMatch = NULL;

        for (unsigned int i = 0; i < methodCount; i++) {
            SEL sel = method_getName(methods[i]);
            NSString *selStr = NSStringFromSelector(sel);

            // Exact match: "methodName" or "methodName:"
            if ([selStr isEqualToString:name] || [selStr isEqualToString:[name stringByAppendingString:@":"]]) {
                bestMatch = sel;
                break;
            }

            // Match base name before "With" — e.g. "addTodoWithTitle:" matches "addTodo"
            NSString *baseName = selStr;
            NSRange withRange = [selStr rangeOfString:@"With"];
            if (withRange.location != NSNotFound) {
                baseName = [selStr substringToIndex:withRange.location];
            } else {
                NSRange colonRange = [selStr rangeOfString:@":"];
                if (colonRange.location != NSNotFound) {
                    baseName = [selStr substringToIndex:colonRange.location];
                }
            }

            if ([baseName isEqualToString:name]) {
                bestMatch = sel;
                break;
            }
        }

        free(methods);

        if (bestMatch) {
            return [NSValue valueWithPointer:bestMatch];
        }

        current = class_getSuperclass(current);
    }

    return nil;
}

+ (NSArray<NSString *> *)callableMethodNames:(Class)cls {
    NSMutableSet<NSString *> *nsObjectMethods = [NSMutableSet set];
    unsigned int baseCount = 0;
    Method *baseMethods = class_copyMethodList([NSObject class], &baseCount);
    for (unsigned int i = 0; i < baseCount; i++) {
        [nsObjectMethods addObject:NSStringFromSelector(method_getName(baseMethods[i]))];
    }
    free(baseMethods);

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);

    for (unsigned int i = 0; i < methodCount; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selStr = NSStringFromSelector(sel);

        // Skip NSObject methods, property accessors, and private methods
        if ([nsObjectMethods containsObject:selStr]) continue;
        if ([selStr hasPrefix:@"_"]) continue;
        if ([selStr hasPrefix:@"set"] && [selStr hasSuffix:@":"]) continue;
        if ([selStr hasPrefix:@"."]) continue;

        // Extract base name
        NSString *baseName = selStr;
        NSRange withRange = [selStr rangeOfString:@"With"];
        if (withRange.location != NSNotFound) {
            baseName = [selStr substringToIndex:withRange.location];
        } else {
            NSRange colonRange = [selStr rangeOfString:@":"];
            if (colonRange.location != NSNotFound) {
                baseName = [selStr substringToIndex:colonRange.location];
            }
        }

        [names addObject:baseName];
    }

    free(methods);
    return names;
}

+ (NSArray<NSString *> *)propertyNamesForClass:(Class)cls {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(cls, &count);
    if (props) {
        for (unsigned int i = 0; i < count; i++) {
            [names addObject:@(property_getName(props[i]))];
        }
        free(props);
    }
    return names;
}

+ (BOOL)tryCatch:(void (NS_NOESCAPE ^)(void))tryBlock error:(NSError **)error {
    @try {
        tryBlock();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"TapDispatch"
                                         code:100
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"ObjC exception"}];
        }
        return NO;
    }
}

@end
