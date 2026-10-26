#import "PYWebSocket.h"
#import "PYAlgorithms.hpp"
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

@interface PYPeer : NSObject
@property int fd;
@property BOOL upgraded, closing, writing;
@property NSTimeInterval accepted, received, writeBegan, pinged;
@property (nonatomic, strong) NSMutableData *input, *output;
@property (nonatomic, strong) NSData *latest;
@property NSUInteger offset;
@property (nonatomic, strong) dispatch_source_t reader, writer;
@end
@implementation PYPeer
@end

@interface PYWebSocket () {
    dispatch_queue_t _queue;
    dispatch_source_t _listener, _heartbeat;
    NSMutableSet<PYPeer *> *_peers;
    NSString *_token;
    BOOL _listenerClosing, _wantListening;
    uint16_t _desiredPort;
    NSString *_desiredToken;
}
@end
@implementation PYWebSocket
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("phoneyolo.websocket", DISPATCH_QUEUE_SERIAL);
        _peers = [NSMutableSet set];
    }
    return self;
}
- (void)changed {
    NSUInteger n = 0;
    for (PYPeer *p in _peers)
        if (p.upgraded && !p.closing)
            n++;
    if (self.clientsChanged)
        self.clientsChanged(n);
}
- (void)drop:(PYPeer *)p {
    if (![_peers containsObject:p])
        return;
    [_peers removeObject:p];
    if (p.reader)
        dispatch_source_cancel(p.reader);
    if (p.writer) {
        if (!p.writing)
            dispatch_resume(p.writer);
        dispatch_source_cancel(p.writer);
    }
    p.reader = nil;
    p.writer = nil;
    p.latest = nil;
    [self changed];
}
- (void)flush:(PYPeer *)p {
    while (p.offset < p.output.length) {
        ssize_t sent = send(p.fd, (const uint8_t *)p.output.bytes + p.offset, p.output.length - p.offset, 0);
        if (sent < 0 && errno == EINTR)
            continue;
        if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (!p.writing) {
                p.writing = YES;
                dispatch_resume(p.writer);
            }
            return;
        }
        if (sent <= 0) {
            [self drop:p];
            return;
        }
        p.offset += (NSUInteger)sent;
    }
    p.output = [NSMutableData data];
    p.offset = 0;
    p.writeBegan = 0;
    if (p.writing) {
        p.writing = NO;
        dispatch_suspend(p.writer);
    }
    if (p.closing) {
        [self drop:p];
        return;
    }
    if (p.latest) {
        NSData *next = p.latest;
        p.latest = nil;
        [self queue:next peer:p latest:NO];
    }
}
- (void)queue:(NSData *)data peer:(PYPeer *)p latest:(BOOL)latest {
    if (![_peers containsObject:p] || p.closing)
        return;
    if (latest && p.output.length > p.offset) {
        p.latest = data;
        return;
    }
    if (p.output.length + data.length > 512 * 1024) {
        [self drop:p];
        return;
    }
    if (!p.writeBegan)
        p.writeBegan = NSDate.timeIntervalSinceReferenceDate;
    [p.output appendData:data];
    [self flush:p];
}
- (NSData *)frame:(uint8_t)opcode data:(NSData *)data {
    auto bytes = py::frame(opcode, data.bytes, data.length);
    return [NSData dataWithBytes:bytes.data() length:bytes.size()];
}
- (void)finish:(PYPeer *)p code:(uint16_t)code {
    uint8_t bytes[] = {(uint8_t)(code >> 8), (uint8_t)code};
    // Discard a pending latest result, then flush a bounded close frame.
    p.latest = nil;
    [self queue:[self frame:8 data:[NSData dataWithBytes:bytes length:2]] peer:p latest:NO];
    p.closing = YES;
    [self changed];
    [self flush:p];
}
- (BOOL)upgrade:(PYPeer *)p header:(NSData *)data {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *lines = [text componentsSeparatedByString:@"\r\n"];
    NSArray *request = [lines.firstObject componentsSeparatedByString:@" "];
    if (request.count != 3 || ![request[0] isEqual:@"GET"] || ![request[2] isEqual:@"HTTP/1.1"])
        return NO;
    NSURLComponents *url =
        [NSURLComponents componentsWithString:[@"http://localhost" stringByAppendingString:request[1]]];
    if (![url.path isEqual:@"/detections"])
        return NO;
    NSString *token = nil;
    for (NSURLQueryItem *q in url.queryItems)
        if ([q.name isEqual:@"token"]) {
            if (token)
                return NO;
            token = q.value;
        }
    if (!token || token.length != _token.length)
        return NO;
    NSUInteger diff = 0;
    for (NSUInteger i = 0; i < token.length; i++)
        diff |= [token characterAtIndex:i] ^ [_token characterAtIndex:i];
    if (diff)
        return NO;
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        if (!line.length)
            continue;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound)
            return NO;
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        if (fields[name])
            return NO;
        fields[name] = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    NSArray *connection = [[(fields[@"connection"] ?: @"") lowercaseString] componentsSeparatedByString:@","];
    BOOL hasUpgrade = NO;
    for (NSString *v in connection)
        if ([[v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] isEqual:@"upgrade"])
            hasUpgrade = YES;
    NSString *key = fields[@"sec-websocket-key"];
    if (!hasUpgrade || ![[fields[@"upgrade"] lowercaseString] isEqual:@"websocket"] ||
        ![fields[@"sec-websocket-version"] isEqual:@"13"] ||
        [[[NSData alloc] initWithBase64EncodedString:key ?: @"" options:0] length] != 16)
        return NO;
    NSData *seed = [[key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"]
        dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t hash[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(seed.bytes, (CC_LONG)seed.length, hash);
    NSString *accept = [[NSData dataWithBytes:hash length:sizeof(hash)] base64EncodedStringWithOptions:0];
    NSString *reply =
        [NSString stringWithFormat:@"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: "
                                   @"Upgrade\r\nSec-WebSocket-Accept: %@\r\n\r\n",
                                   accept];
    [self queue:[reply dataUsingEncoding:NSUTF8StringEncoding] peer:p latest:NO];
    if (![_peers containsObject:p])
        return NO;
    p.upgraded = YES;
    [self changed];
    return YES;
}
- (void)read:(PYPeer *)p {
    uint8_t buf[8192];
    for (;;) {
        ssize_t n = recv(p.fd, buf, sizeof(buf), 0);
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            break;
        if (n <= 0) {
            [self drop:p];
            return;
        }
        [p.input appendBytes:buf length:(NSUInteger)n];
        p.received = NSDate.timeIntervalSinceReferenceDate;
        if (p.input.length > (p.upgraded ? 73728 : 8192)) {
            [self drop:p];
            return;
        }
    }
    if (!p.upgraded) {
        NSData *end = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange range = [p.input rangeOfData:end options:0 range:NSMakeRange(0, p.input.length)];
        if (range.location == NSNotFound)
            return;
        NSUInteger length = range.location + 4;
        NSData *header = [p.input subdataWithRange:NSMakeRange(0, length)];
        if (![self upgrade:p header:header]) {
            [self drop:p];
            return;
        }
        [p.input replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
    }
    while (p.input.length && [_peers containsObject:p] && !p.closing) {
        py::Frame f;
        auto result = py::parseFrame((const uint8_t *)p.input.bytes, p.input.length, f);
        if (result == py::Parse::More)
            return;
        if (result != py::Parse::Ready) {
            [self finish:p code:result == py::Parse::TooLarge ? 1009 : 1002];
            return;
        }
        [p.input replaceBytesInRange:NSMakeRange(0, f.consumed) withBytes:NULL length:0];
        NSData *payload = [NSData dataWithBytes:f.payload.data() length:f.payload.size()];
        if (f.opcode == 8) {
            [self finish:p code:1000];
            return;
        }
        if (f.opcode == 9)
            [self queue:[self frame:10 data:payload] peer:p latest:NO];
        else if (f.opcode != 10) {
            [self finish:p code:1003];
            return;
        } // Push-only endpoint.
    }
}
- (void)accept:(int)listener {
    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR)
                continue;
            return;
        }
        if (_peers.count >= 16) {
            close(fd);
            continue;
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        PYPeer *p = [PYPeer new];
        p.fd = fd;
        p.input = [NSMutableData data];
        p.output = [NSMutableData data];
        p.accepted = p.received = NSDate.timeIntervalSinceReferenceDate;
        p.reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
        p.writer = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0, _queue);
        __weak PYWebSocket *weakSelf = self;
        __weak PYPeer *weakPeer = p;
        dispatch_source_set_event_handler(p.reader, ^{
            PYPeer *peer = weakPeer;
            if (peer)
                [weakSelf read:peer];
        });
        dispatch_source_set_cancel_handler(p.reader, ^{
            close(fd);
        });
        dispatch_source_set_event_handler(p.writer, ^{
            PYPeer *peer = weakPeer;
            if (peer)
                [weakSelf flush:peer];
        });
        [_peers addObject:p];
        dispatch_resume(p.reader);
    }
}
- (void)stopOnQueue {
    if (_listener) {
        int fd = (int)dispatch_source_get_handle(_listener);
        _listenerClosing = YES;
        // Rebind only after the fd has closed, using the most recent requested configuration.
        dispatch_source_set_cancel_handler(_listener, ^{
            close(fd);
            self->_listenerClosing = NO;
            if (self->_wantListening)
                [self listenPort:self->_desiredPort token:self->_desiredToken];
        });
        dispatch_source_cancel(_listener);
    }
    _listener = nil;
    if (_heartbeat)
        dispatch_source_cancel(_heartbeat);
    _heartbeat = nil;
    for (PYPeer *p in _peers.allObjects)
        [self drop:p];
}
- (void)listenPort:(uint16_t)port token:(NSString *)token {
    self->_token = [token copy];
    int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    if (fd >= 0) {
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    }
    struct sockaddr_in addr = {};
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 16) < 0) {
        int saved = errno;
        if (fd >= 0)
            close(fd);
        if (self.serverFailed)
            self.serverFailed([NSString stringWithFormat:@"监听 %u 失败: %s", port, strerror(saved)]);
        return;
    }
    self->_listener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self->_queue);
    __weak PYWebSocket *weakSelf = self;
    dispatch_source_set_event_handler(self->_listener, ^{
        [weakSelf accept:fd];
    });
    dispatch_source_set_cancel_handler(self->_listener, ^{
        close(fd);
    });
    dispatch_resume(self->_listener);
    self->_heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
    dispatch_source_set_timer(self->_heartbeat, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC,
                              NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(self->_heartbeat, ^{
        PYWebSocket *s = weakSelf;
        if (!s)
            return;
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        for (PYPeer *p in s->_peers.allObjects) {
            if ((!p.upgraded && now - p.accepted > 5) || (p.upgraded && now - p.received > 45) ||
                (p.writeBegan && now - p.writeBegan > 10)) {
                [s drop:p];
                continue;
            }
            if (p.upgraded && !p.closing && now - p.pinged > 15) {
                p.pinged = now;
                [s queue:[s frame:9 data:NSData.data] peer:p latest:NO];
            }
        }
    });
    dispatch_resume(self->_heartbeat);
}
- (void)startPort:(uint16_t)port token:(NSString *)token {
    dispatch_async(_queue, ^{
        self->_wantListening = YES;
        self->_desiredPort = port;
        self->_desiredToken = [token copy];
        [self stopOnQueue];
        if (!self->_listenerClosing)
            [self listenPort:port token:token];
    });
}
- (void)stop {
    dispatch_async(_queue, ^{
        self->_wantListening = NO;
        [self stopOnQueue];
    });
}
- (void)broadcast:(NSDictionary *)message {
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL];
    if (!json)
        return;
    NSData *data = [self frame:1 data:json];
    dispatch_async(_queue, ^{
        for (PYPeer *p in self->_peers.allObjects)
            if (p.upgraded && !p.closing)
                [self queue:data peer:p latest:YES];
    });
}
@end
