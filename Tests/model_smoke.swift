import Foundation
import CoreML
import CoreVideo
// Executed on macOS CI. The device still needs its own capture/orientation/performance checks.
let source=URL(fileURLWithPath:CommandLine.arguments[1])
let compiled=try MLModel.compileModel(at:source)
defer {try? FileManager.default.removeItem(at:compiled)}
let model=try MLModel(contentsOf:compiled)
var buffer:CVPixelBuffer?
precondition(CVPixelBufferCreate(nil,640,640,kCVPixelFormatType_32BGRA,nil,&buffer)==kCVReturnSuccess)
CVPixelBufferLockBaseAddress(buffer!,[])
memset(CVPixelBufferGetBaseAddress(buffer!),114,CVPixelBufferGetBytesPerRow(buffer!)*640)
CVPixelBufferUnlockBaseAddress(buffer!,[])
let input=try MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(pixelBuffer:buffer!)])
let prediction=try model.prediction(from:input)
let output=prediction.featureValue(for:"predictions")!.multiArrayValue!
precondition(output.shape.map{$0.intValue} == [1,84,8400],"Unexpected YOLO output shape: \(output.shape)")
for i in 0..<output.count {precondition(output[i].doubleValue.isFinite)}
print("PASS: Core ML compilation and inference, shape \(output.shape)")
