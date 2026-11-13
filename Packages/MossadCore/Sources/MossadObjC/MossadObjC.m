#import "MossadObjC.h"

BOOL MossadTry(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            info[@"name"] = exception.name;
            *error = [NSError errorWithDomain:@"MossadObjC.exception" code:1 userInfo:info];
        }
        return NO;
    } @catch (id other) {
        // An Objective-C object that is not an NSException; a C++ exception is not caught here.
        if (error) {
            *error = [NSError errorWithDomain:@"MossadObjC.exception" code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"an Objective-C object was raised"}];
        }
        return NO;
    }
}
