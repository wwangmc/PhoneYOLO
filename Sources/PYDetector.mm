#import "PYDetector.h"
#import "PYAlgorithms.hpp"
#import <CoreImage/CoreImage.h>
#import <CoreML/CoreML.h>
#import <CoreVideo/CVPixelBufferIOSurface.h>
#import <IOSurface/IOSurfaceRef.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>

static NSError *PYError(NSString *message) {
    return [NSError errorWithDomain:@"PhoneYOLO" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}
typedef void (*PYRenderDisplay)(int, CFStringRef, IOSurfaceRef, int, int);
@interface PYScreenCapture () {
    CVPixelBufferPoolRef _pool;
    CGSize _size;
    PYRenderDisplay _render;
}
@end
@implementation PYScreenCapture
- (instancetype)init {
    if ((self = [super init]))
        _render = (PYRenderDisplay)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    return self;
}
- (void)dealloc {
    if (_pool)
        CVPixelBufferPoolRelease(_pool);
}
- (CVPixelBufferRef)captureSize:(CGSize)size error:(NSError **)error {
    if (!_render) {
        if (error)
            *error = PYError(@"系统未提供 CARenderServerRenderDisplay，请确认越狱注入和 iOS 版本");
        return NULL;
    }
    if (size.width < 2 || size.height < 2 || size.width > 8192 || size.height > 8192) {
        if (error)
            *error = PYError(@"屏幕尺寸无效");
        return NULL;
    }
    if (!_pool || !CGSizeEqualToSize(size, _size)) {
        if (_pool) {
            CVPixelBufferPoolRelease(_pool);
            _pool = NULL;
        }
        _size = size;
        NSDictionary *attrs = @{
            (__bridge NSString *)kCVPixelBufferWidthKey : @((int)size.width),
            (__bridge NSString *)kCVPixelBufferHeightKey : @((int)size.height),
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{@"IOSurfaceIsGlobal" : @YES},
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
            (__bridge NSString *)kCVPixelBufferBytesPerRowAlignmentKey : @64
        };
        CVReturn result = CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &_pool);
        if (result) {
            if (error)
                *error = PYError([NSString stringWithFormat:@"创建截屏缓冲失败: %d", result]);
            return NULL;
        }
    }
    CVPixelBufferRef buffer = NULL;
    NSDictionary *limit = @{(__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey : @2};
    CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        NULL, _pool, (__bridge CFDictionaryRef)limit, &buffer);
    if (result) {
        if (error)
            *error = PYError([NSString stringWithFormat:@"截屏缓冲分配失败: %d", result]);
        return NULL;
    }
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
    if (!surface || IOSurfaceLock(surface, 0, NULL)) {
        CVPixelBufferRelease(buffer);
        if (error)
            *error = PYError(@"无法锁定屏幕缓冲");
        return NULL;
    }
    _render(0, CFSTR("LCD"), surface, 0, 0);
    IOSurfaceUnlock(surface, 0, NULL);
    return buffer;
}
@end

@interface PYDetector () {
    MLModel *_model;
    NSString *_input, *_output;
    NSArray<NSString *> *_labels;
    CIContext *_context;
    CVPixelBufferRef _inputBuffer;
    CGColorSpaceRef _color;
}
@end
@implementation PYDetector
- (void)dealloc {
    if (_inputBuffer)
        CVPixelBufferRelease(_inputBuffer);
    if (_color)
        CGColorSpaceRelease(_color);
}
- (instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    if (!(self = [super init]))
        return nil;
    NSURL *url = [NSURL fileURLWithPath:path];
    if (![path.pathExtension isEqual:@"mlmodelc"]) {
        // Compile once on first subscription. Persist the result next to the user configuration.
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:error];
        if (!attrs)
            return nil;
        NSString *fingerprint =
            [NSString stringWithFormat:@"%@-%@-%@", path, attrs[NSFileSize], attrs[NSFileModificationDate]];
        // A deterministic file name avoids loading stale compiled weights after replacement.
        NSData *key = [fingerprint dataUsingEncoding:NSUTF8StringEncoding];
        uint64_t hash = 1469598103934665603ULL;
        for (NSUInteger i = 0; i < key.length; i++) {
            hash ^= ((const uint8_t *)key.bytes)[i];
            hash *= 1099511628211ULL;
        }
        NSString *cache = [@"/var/mobile/Library/PhoneYOLO"
            stringByAppendingPathComponent:[NSString stringWithFormat:@"compiled-%llx.mlmodelc",
                                                                      (unsigned long long)hash]];
        NSURL *cached = [NSURL fileURLWithPath:cache];
        if (![NSFileManager.defaultManager fileExistsAtPath:cache]) {
            NSURL *temporary = [MLModel compileModelAtURL:url error:error];
            if (!temporary)
                return nil;
            if (![NSFileManager.defaultManager copyItemAtURL:temporary toURL:cached error:error])
                return nil;
            [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL];
        }
        url = cached;
    }
    MLModelConfiguration *configuration = [MLModelConfiguration new];
    configuration.computeUnits = MLComputeUnitsAll;
    _model = [MLModel modelWithContentsOfURL:url configuration:configuration error:error];
    if (!_model)
        return nil;
    // This deliberately accepts one common, explicit contract rather than guessing arbitrary tensors.
    NSDictionary *inputs = _model.modelDescription.inputDescriptionsByName;
    for (NSString *name in inputs) {
        MLFeatureDescription *d = inputs[name];
        if (d.type == MLFeatureTypeImage) {
            _input = name;
            _inputSize = CGSizeMake(d.imageConstraint.pixelsWide, d.imageConstraint.pixelsHigh);
        }
    }
    NSDictionary *outputs = _model.modelDescription.outputDescriptionsByName;
    for (NSString *name in outputs) {
        MLFeatureDescription *d = outputs[name];
        if (d.type == MLFeatureTypeMultiArray) {
            if (_output) {
                if (error)
                    *error = PYError(@"仅支持 YOLOv8 detect 的单个 raw 输出，请用项目导出脚本转换");
                return nil;
            }
            _output = name;
        }
    }
    if (inputs.count != 1 || !_input || !_output || _inputSize.width < 32 || _inputSize.height < 32 ||
        _inputSize.width > 2048 || _inputSize.height > 2048) {
        if (error)
            *error = PYError(@"模型需要一个 RGB 图像输入和一个 [1,4+类别数,N] raw 输出");
        return nil;
    }
    NSDictionary *metadata = _model.modelDescription.metadata[MLModelCreatorDefinedKey];
    NSString *names = metadata[@"phoneyolo.names"];
    id parsed = [names isKindOfClass:NSString.class]
                    ? [NSJSONSerialization JSONObjectWithData:[names dataUsingEncoding:NSUTF8StringEncoding]
                                                      options:0
                                                        error:NULL]
                    : nil;
    if (![parsed isKindOfClass:NSArray.class] || ![parsed count]) {
        if (error)
            *error = PYError(@"模型缺少 phoneyolo.names 标签，请用 scripts/export_model.py 导出");
        return nil;
    }
    for (id label in parsed)
        if (![label isKindOfClass:NSString.class]) {
            if (error)
                *error = PYError(@"模型标签格式无效");
            return nil;
        }
    _labels = parsed;
    _classCount = _labels.count;
    NSDictionary *bufferAttrs = @{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey : @YES
    };
    if (CVPixelBufferCreate(NULL, (size_t)_inputSize.width, (size_t)_inputSize.height,
                            kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)bufferAttrs,
                            &_inputBuffer)) {
        if (error)
            *error = PYError(@"创建模型输入缓冲失败");
        return nil;
    }
    _context = [CIContext
        contextWithOptions:@{kCIContextUseSoftwareRenderer : @NO, kCIContextCacheIntermediates : @NO}];
    _color = CGColorSpaceCreateDeviceRGB();
    return self;
}
- (NSArray *)detect:(CVPixelBufferRef)buffer
        orientation:(UIInterfaceOrientation)orientation
             config:(NSDictionary *)config
         screenSize:(CGSize *)screenSize
              error:(NSError **)error {
    int exif = 1;
    if (orientation == UIInterfaceOrientationLandscapeLeft)
        exif = 8;
    else if (orientation == UIInterfaceOrientationLandscapeRight)
        exif = 6;
    else if (orientation == UIInterfaceOrientationPortraitUpsideDown)
        exif = 3;
    CIImage *image = [[CIImage imageWithCVPixelBuffer:buffer] imageByApplyingOrientation:exif];
    CGRect extent = image.extent;
    CGSize screen = extent.size;
    if (screenSize)
        *screenSize = screen;
    image =
        [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
    double scale = std::min(_inputSize.width / screen.width, _inputSize.height / screen.height);
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
                                                (_inputSize.width - screen.width * scale) / 2,
                                                (_inputSize.height - screen.height * scale) / 2)];
    CGRect bounds = CGRectMake(0, 0, _inputSize.width, _inputSize.height);
    CIImage *background =
        [[CIImage imageWithColor:[CIColor colorWithRed:114 / 255.0 green:114 / 255.0
                                                  blue:114 / 255.0]] imageByCroppingToRect:bounds];
    [_context render:[image imageByCompositingOverImage:background]
        toCVPixelBuffer:_inputBuffer
                 bounds:bounds
             colorSpace:_color];
    MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc]
        initWithDictionary:@{_input : [MLFeatureValue featureValueWithPixelBuffer:_inputBuffer]}
                     error:error];
    if (!provider)
        return nil;
    id<MLFeatureProvider> prediction = [_model predictionFromFeatures:provider error:error];
    if (!prediction)
        return nil;
    MLMultiArray *array = [prediction featureValueForName:_output].multiArrayValue;
    NSArray<NSNumber *> *shape = array.shape, *strides = array.strides;
    if (shape.count != 3 || shape[0].integerValue != 1 ||
        shape[1].unsignedIntegerValue != _labels.count + 4 || shape[2].unsignedIntegerValue > 100000 ||
        shape[2].integerValue <= 0 ||
        (array.dataType != MLMultiArrayDataTypeFloat32 && array.dataType != MLMultiArrayDataTypeDouble)) {
        if (error)
            *error = PYError([NSString stringWithFormat:@"不支持的输出 %@；需要 [1,%lu,N] float32/float64",
                                                        shape, (unsigned long)_labels.count + 4]);
        return nil;
    }
    const float *f = (const float *)array.dataPointer;
    const double *d = (const double *)array.dataPointer;
    size_t a = strides[1].unsignedIntegerValue, b = strides[2].unsignedIntegerValue;
    auto read = [&](size_t channel, size_t n) -> double {
        size_t index = channel * a + n * b;
        return array.dataType == MLMultiArrayDataTypeFloat32 ? f[index] : d[index];
    };
    auto boxes =
        py::decode(shape[2].unsignedIntegerValue, _labels.count, read, [config[@"confidence"] doubleValue],
                   [config[@"iou"] doubleValue], [config[@"maxDetections"] unsignedIntegerValue],
                   screen.width, screen.height, _inputSize.width, _inputSize.height);
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:boxes.size()];
    for (const auto &box : boxes)
        [results addObject:@{
            @"classId" : @(box.cls),
            @"label" : _labels[(NSUInteger)box.cls],
            @"confidence" : @(box.score),
            @"box" : @{@"x" : @(box.x), @"y" : @(box.y), @"width" : @(box.w), @"height" : @(box.h)},
            @"normalizedBox" : @{
                @"x" : @(box.x / screen.width),
                @"y" : @(box.y / screen.height),
                @"width" : @(box.w / screen.width),
                @"height" : @(box.h / screen.height)
            }
        }];
    return results;
}
@end
