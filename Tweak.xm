#import "Sources/PYService.h"
#import <UIKit/UIKit.h>

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    [PYService start];
}
%end
