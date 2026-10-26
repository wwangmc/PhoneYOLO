#import <Foundation/Foundation.h>
NSString *PYDataDirectory(void);
NSString *PYBundledModel(void);
NSDictionary *PYReadConfig(void);
BOOL PYWriteConfig(NSDictionary *config, NSError **error);
BOOL PYWriteJSON(NSDictionary *value, NSString *path, NSError **error);
extern const char *PYConfigNotification;
