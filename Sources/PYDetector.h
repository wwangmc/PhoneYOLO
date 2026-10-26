#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
@interface PYDetector : NSObject
@property (nonatomic, readonly) CGSize inputSize;
@property (nonatomic, readonly) NSUInteger classCount;
- (instancetype)initWithPath:(NSString *)path error:(NSError **)error;
- (NSArray *)detect:(CVPixelBufferRef)buffer
        orientation:(UIInterfaceOrientation)orientation
             config:(NSDictionary *)config
         screenSize:(CGSize *)screenSize
              error:(NSError **)error;
@end
@interface PYScreenCapture : NSObject
- (CVPixelBufferRef)captureSize:(CGSize)size error:(NSError **)error CF_RETURNS_RETAINED;
@end
