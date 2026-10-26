#import "../Sources/PYWebSocket.h"
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3)
            return 2;
        PYWebSocket *server = [PYWebSocket new];
        server.clientsChanged = ^(NSUInteger count) {
            printf("clients %lu\n", (unsigned long)count);
            fflush(stdout);
        };
        server.serverFailed = ^(NSString *message) {
            fprintf(stderr, "%s\n", message.UTF8String);
            exit(3);
        };
        [server startPort:(uint16_t)atoi(argv[1]) token:[NSString stringWithUTF8String:argv[2]]];
        dispatch_source_t timer =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 100000000), 100000000, 1000000);
        dispatch_source_set_event_handler(timer, ^{
            [server broadcast:@{@"type" : @"detections", @"detections" : @[]}];
        });
        dispatch_resume(timer);
        // Restart on SIGUSR1 to exercise close/rebind on the same port.
        signal(SIGUSR1, SIG_IGN);
        dispatch_source_t signalSource =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(signalSource, ^{
            for (int i = 0; i < 5; i++)
                [server startPort:(uint16_t)atoi(argv[1]) token:[NSString stringWithUTF8String:argv[2]]];
        });
        dispatch_resume(signalSource);
        dispatch_main();
    }
}
