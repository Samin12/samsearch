#import "codes_archive.h"

// An old or damaged Messages archive must not take down the helper.
NSString *codeArchiveText(NSData *data) {
    @try {
        id value = [NSUnarchiver unarchiveObjectWithData:data];
        return [value isKindOfClass:NSAttributedString.class] ? [value string] : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}
