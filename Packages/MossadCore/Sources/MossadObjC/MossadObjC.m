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
    }
}
