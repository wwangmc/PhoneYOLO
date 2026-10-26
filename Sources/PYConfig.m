#import "PYConfig.h"
#include <math.h>
#import <rootless.h>
#include <sys/stat.h>
const char *PYConfigNotification = "com.example.phoneyolo.config-changed";
NSString *PYDataDirectory(void) { return @"/var/mobile/Library/PhoneYOLO"; }
NSString *PYBundledModel(void) {
    return ROOT_PATH_NS(@"/Library/Application Support/PhoneYOLO/yolov8n.mlmodel");
}
BOOL PYWriteJSON(NSDictionary *value, NSString *path, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error])
        return NO;
    chmod(path.fileSystemRepresentation, 0600);
    return YES;
}
static double PYNumber(id value, double fallback, double low, double high) {
    if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue]))
        return fallback;
    return fmin(high, fmax(low, [value doubleValue]));
}
NSDictionary *PYReadConfig(void) {
    NSString *directory = PYDataDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:@{
                                                 NSFilePosixPermissions : @0700
                                             }
                                                  error:NULL];
    chmod(directory.fileSystemRepresentation, 0700);
    NSString *path = [directory stringByAppendingPathComponent:@"config.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSDictionary *d = [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
    NSString *token = [d[@"token"] isKindOfClass:NSString.class] ? d[@"token"] : nil;
    BOOL newToken =
        token.length < 16 || token.length > 128 ||
        [token rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location !=
            NSNotFound;
    if (newToken)
        token = [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSString *model = [d[@"modelPath"] isKindOfClass:NSString.class] ? d[@"modelPath"] : PYBundledModel();
    if (!model.isAbsolutePath)
        model = PYBundledModel();
    NSDictionary *config = @{
        @"enabled" : @([d[@"enabled"] isKindOfClass:NSNumber.class] ? [d[@"enabled"] boolValue] : YES),
        @"port" : @((int)PYNumber(d[@"port"], 8765, 1024, 65535)),
        @"fps" : @(PYNumber(d[@"fps"], 10, 1, 30)),
        @"confidence" : @(PYNumber(d[@"confidence"], 0.25, 0.01, 1)),
        @"iou" : @(PYNumber(d[@"iou"], 0.45, 0.01, 1)),
        @"maxDetections" : @((int)PYNumber(d[@"maxDetections"], 100, 1, 300)),
        @"token" : token,
        @"modelPath" : model
    };
    if (newToken)
        PYWriteJSON(config, path, NULL);
    return config;
}
BOOL PYWriteConfig(NSDictionary *config, NSError **error) {
    return PYWriteJSON(config, [PYDataDirectory() stringByAppendingPathComponent:@"config.json"], error);
}
