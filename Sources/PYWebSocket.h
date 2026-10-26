#import <Foundation/Foundation.h>
@interface PYWebSocket : NSObject
@property (nonatomic, copy) void (^clientsChanged)(NSUInteger count);
@property (nonatomic, copy) void (^serverFailed)(NSString *message);
- (void)startPort:(uint16_t)port token:(NSString *)token;
- (void)stop;
- (void)broadcast:(NSDictionary *)message;
@end
