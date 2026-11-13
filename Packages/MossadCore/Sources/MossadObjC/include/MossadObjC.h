#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and turns an Objective-C exception it raises into an error. Swift cannot catch an NSException:
/// AVFAudio raises one for a tap on a format that the hardware does not have at that moment, and the app would abort.
BOOL MossadTry(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
