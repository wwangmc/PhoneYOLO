#import "PYService.h"
#import "PYConfig.h"
#import "PYDetector.h"
#import "PYWebSocket.h"
#include <atomic>
#include <notify.h>
#include <objc/message.h>

@interface PYService () {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    PYWebSocket *_server;
    PYDetector *_detector;
    PYScreenCapture *_capture;
    NSDictionary *_config;
    std::atomic<NSUInteger> _clients;
    std::atomic<uint64_t> _clientEpoch;
    NSUInteger _generation;
    uint64_t _sequence;
    BOOL _scheduled;
    NSTimeInterval _retryAt, _lastStatus;
    NSString *_error;
    int _notifyToken;
}
@end
@implementation PYService
+ (void)start {
    static PYService *service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        service = [PYService new];
        [service begin];
    });
}
- (void)status:(BOOL)force {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (!force && now - _lastStatus < 1)
        return;
    _lastStatus = now;
    PYWriteJSON(@{
        @"enabled" : _config[@"enabled"] ?: @NO,
        @"clients" : @(_clients.load()),
        @"detecting" : @(_clients.load() > 0 && _detector != nil && [_config[@"enabled"] boolValue]),
        @"modelLoaded" : @(_detector != nil),
        @"sequence" : @(_sequence),
        @"port" : _config[@"port"] ?: @0,
        @"error" : _error ?: @"",
        @"updatedAt" : @(NSDate.date.timeIntervalSince1970)
    },
                [PYDataDirectory() stringByAppendingPathComponent:@"status.json"], NULL);
}
- (void)idle {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    _detector = nil;
    _capture = nil;
    _retryAt = 0;
    [self status:YES];
}
- (void)reload {
    _generation++;
    _clientEpoch.fetch_add(1);
    _clients.store(0);
    [self idle];
    _error = nil;
    _config = PYReadConfig();
    if ([_config[@"enabled"] boolValue])
        [_server startPort:[_config[@"port"] unsignedShortValue] token:_config[@"token"]];
    else
        [_server stop];
    [self status:YES];
}
- (void)begin {
    _queue = dispatch_queue_create("phoneyolo.inference", DISPATCH_QUEUE_SERIAL);
    _clients.store(0);
    _clientEpoch.store(0);
    _server = [PYWebSocket new];
    __weak PYService *weakSelf = self;
    _server.clientsChanged = ^(NSUInteger count) {
        PYService *s = weakSelf;
        if (!s)
            return;
        s->_clients.store(count);
        if (!count)
            s->_clientEpoch.fetch_add(1);
        dispatch_async(s->_queue, ^{
            if (!s->_clients.load()) {
                s->_generation++;
                [s idle];
                return;
            }
            if (!s->_timer && [s->_config[@"enabled"] boolValue]) {
                s->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, s->_queue);
                uint64_t period = (uint64_t)(NSEC_PER_SEC / [s->_config[@"fps"] doubleValue]);
                dispatch_source_set_timer(s->_timer, dispatch_time(DISPATCH_TIME_NOW, 0), period,
                                          period / 10);
                dispatch_source_set_event_handler(s->_timer, ^{
                    [weakSelf tick];
                });
                dispatch_resume(s->_timer);
            }
            [s status:YES];
        });
    };
    _server.serverFailed = ^(NSString *message) {
        PYService *s = weakSelf;
        if (s)
            dispatch_async(s->_queue, ^{
                s->_error = message;
                [s status:YES];
            });
    };
    notify_register_dispatch(PYConfigNotification, &_notifyToken, _queue, ^(int token) {
        (void)token;
        [weakSelf reload];
    });
    dispatch_async(_queue, ^{
        [self reload];
    });
}
- (void)report:(NSError *)error {
    _error = error.localizedDescription ?: @"检测失败";
    [_server broadcast:@{@"type" : @"error", @"message" : _error, @"retryInSeconds" : @5}];
    _retryAt = NSDate.timeIntervalSinceReferenceDate + 5;
    _detector = nil;
    _capture = nil;
    [self status:YES];
}
- (void)tick {
    if (_scheduled || !_clients.load() || ![_config[@"enabled"] boolValue] ||
        NSDate.timeIntervalSinceReferenceDate < _retryAt)
        return;
    _scheduled = YES;
    NSUInteger generation = _generation;
    uint64_t epoch = _clientEpoch.load();
    // UIKit access stays on the main queue; capture/inference never occupies SpringBoard's main thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        CGSize native = UIScreen.mainScreen.nativeBounds.size;
        native = CGSizeMake(MIN(native.width, native.height), MAX(native.width, native.height));
        UIInterfaceOrientation orientation = UIApplication.sharedApplication.statusBarOrientation;
        SEL selector = NSSelectorFromString(@"activeInterfaceOrientation");
        if ([UIApplication.sharedApplication respondsToSelector:selector])
            orientation =
                ((UIInterfaceOrientation(*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, selector);
        CGFloat scale = UIScreen.mainScreen.nativeScale;
        dispatch_async(self->_queue, ^{
            self->_scheduled = NO;
            if (generation != self->_generation || epoch != self->_clientEpoch.load() ||
                !self->_clients.load() || ![self->_config[@"enabled"] boolValue])
                return;
            @autoreleasepool {
                NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
                NSError *error = nil;
                if (!self->_detector)
                    self->_detector = [[PYDetector alloc] initWithPath:self->_config[@"modelPath"]
                                                                 error:&error];
                if (!self->_detector) {
                    [self report:error];
                    return;
                }
                if (epoch != self->_clientEpoch.load() || !self->_clients.load()) {
                    [self idle];
                    return;
                }
                if (!self->_capture)
                    self->_capture = [PYScreenCapture new];
                CVPixelBufferRef frame = [self->_capture captureSize:native error:&error];
                if (!frame) {
                    [self report:error];
                    return;
                }
                NSTimeInterval timestamp = NSDate.date.timeIntervalSince1970;
                CGSize screen = CGSizeZero;
                NSArray *results = [self->_detector detect:frame
                                               orientation:orientation
                                                    config:self->_config
                                                screenSize:&screen
                                                     error:&error];
                CVPixelBufferRelease(frame);
                if (epoch != self->_clientEpoch.load() || !self->_clients.load()) {
                    [self idle];
                    return;
                }
                if (!results) {
                    [self report:error];
                    return;
                }
                self->_error = nil;
                [self->_server broadcast:@{
                    @"type" : @"detections",
                    @"version" : @1,
                    @"sequence" : @(++self->_sequence),
                    @"timestamp" : @(timestamp),
                    @"latencyMs" : @((NSProcessInfo.processInfo.systemUptime - began) * 1000),
                    @"screen" : @{
                        @"width" : @(screen.width),
                        @"height" : @(screen.height),
                        @"scale" : @(scale),
                        @"orientation" : @(orientation),
                        @"coordinateSystem" : @"top-left-pixels"
                    },
                    @"detections" : results
                }];
                [self status:NO];
            }
        });
    });
}
@end
