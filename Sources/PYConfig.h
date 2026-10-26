#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSString *PYDataDirectory(void);
FOUNDATION_EXPORT NSString *PYBundledModel(void);
FOUNDATION_EXPORT NSDictionary *PYReadConfig(void);
FOUNDATION_EXPORT BOOL PYWriteConfig(NSDictionary *config, NSError **error);
FOUNDATION_EXPORT BOOL PYWriteJSON(NSDictionary *value, NSString *path, NSError **error);
FOUNDATION_EXPORT const char *PYConfigNotification;
