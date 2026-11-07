#import "codes_archive.h"
#import <Carbon/Carbon.h>

// An old or damaged Messages archive must not take down the helper.
NSString *codeArchiveText(NSData *data) {
    @try {
        id value = [NSUnarchiver unarchiveObjectWithData:data];
        return [value isKindOfClass:NSAttributedString.class] ? [value string] : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

// askUserIfNeeded=false is essential: status must never display an Automation prompt.
NSString *codeAutomationState(NSString *bundleIdentifier) {
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithDescriptorType:typeApplicationBundleID
        data:[bundleIdentifier dataUsingEncoding:NSUTF8StringEncoding]];
    OSStatus status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false);
    if (status == noErr) return @"granted";
    if (status == errAEEventNotPermitted) return @"denied";
    return @"unknown";
}
