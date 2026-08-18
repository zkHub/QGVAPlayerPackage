// QGMP4FrameHWDecoder.m
// Tencent is pleased to support the open source community by making vap available.
//
// Copyright (C) 2020 Tencent.  All rights reserved.
//
// Licensed under the MIT License (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
//
// http://opensource.org/licenses/MIT
//
// Unless required by applicable law or agreed to in writing, software distributed under the License is
// distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
// either express or implied. See the License for the specific language governing permissions and
// limitations under the License.

#import "QGMP4FrameHWDecoder.h"
#import "QGVAPWeakProxy.h"
#import "QGMP4AnimatedImageFrame.h"
#import "QGBaseAnimatedImageFrame+Displaying.h"
#import <VideoToolbox/VideoToolbox.h>
#import "QGHWDMP4OpenGLView.h"
#import "QGMP4Parser.h"
#import "QGVAPSafeMutableArray.h"
#import "NSNotificationCenter+VAPThreadSafe.h"
#include <sys/sysctl.h>
#import <AVFoundation/AVFoundation.h>

static CVPixelBufferRef QGVAPMetalCompatiblePixelBuffer(CVPixelBufferRef source);

@implementation UIDevice (HWD)

- (BOOL)hwd_isSimulator {
    // 使用编译宏，避免 Apple Silicon 模拟器 hw.machine=arm64 时漏判
#if TARGET_OS_SIMULATOR
    return YES;
#else
    return NO;
#endif
}

- (NSString *)machineName {
    static dispatch_once_t token;
    static NSString *name;
    dispatch_once(&token, ^{
        size_t size;
        sysctlbyname("hw.machine", NULL, &size, NULL, 0);
        char *machineName = malloc(size);
        sysctlbyname("hw.machine", machineName, &size, NULL, 0);
        name = [NSString stringWithUTF8String:machineName];
        free(machineName);
    });
    return name;
}

@end

@interface NSArray (SafeOperation)

@end

@implementation NSArray (SafeOperation)

- (id)safeObjectAtIndex:(NSUInteger)index
{
    if (index >= self.count) {
        NSAssert(0, @"Error: access to array index which is beyond bounds! ");
        return nil;
    }
    
    return self[index];
}

@end

@interface QGMP4FrameHWDecoder() {
    
    NSMutableArray *_buffers;
    
    int _videoStream;
    int _outputWidth, _outputHeight;
    OSStatus _status;
    BOOL _isFinish;
    VTDecompressionSessionRef _mDecodeSession;
    CMFormatDescriptionRef  _mFormatDescription;
    NSInteger _finishFrameIndex;
    NSError *_constructErr;
    QGMP4ParserProxy *_mp4Parser;
    
    int _invalidRetryCount;
}

@property (atomic, strong) dispatch_queue_t decodeQueue; //dispatch decode task
@property (nonatomic, strong) NSData *ppsData; //Picture Parameter Set
@property (nonatomic, strong) NSData *spsData; //Sequence Parameter Set
/** Video Parameter Set */
@property (nonatomic, strong) NSData *vpsData;

@property (atomic, assign) NSInteger lastDecodeFrame;

@end

NSString *const QGMP4HWDErrorDomain = @"QGMP4HWDErrorDomain";

@implementation QGMP4FrameHWDecoder

+ (NSString *)errorDescriptionForCode:(QGMP4HWDErrorCode)errorCode {
    
    NSArray *errorDescs = @[@"文件不存在",@"非法文件格式",@"无法获取视频流信息",@"无法获取视频流",@"VTB创建desc失败",@"VTB创建session失败"];
    NSString *desc = @"";
    switch (errorCode) {
        case QGMP4HWDErrorCode_FileNotExist:
            desc = [errorDescs safeObjectAtIndex:0];
            break;
        case QGMP4HWDErrorCode_InvalidMP4File:
            desc = [errorDescs safeObjectAtIndex:1];
            break;
        case QGMP4HWDErrorCode_CanNotGetStreamInfo:
            desc = [errorDescs safeObjectAtIndex:2];
            break;
        case QGMP4HWDErrorCode_CanNotGetStream:
            desc = [errorDescs safeObjectAtIndex:3];
            break;
        case QGMP4HWDErrorCode_ErrorCreateVTBDesc:
            desc = [errorDescs safeObjectAtIndex:4];
            break;
        case QGMP4HWDErrorCode_ErrorCreateVTBSession:
            desc = [errorDescs safeObjectAtIndex:5];
            break;
            
        default:
            break;
    }
    return desc;
}

- (instancetype)initWith:(QGMP4HWDFileInfo *)fileInfo error:(NSError *__autoreleasing *)error{
    
    if (self = [super initWith:fileInfo error:error]) {
        _decodeQueue = dispatch_queue_create("com.qgame.vap.decode", DISPATCH_QUEUE_SERIAL);
        _lastDecodeFrame = -1;
        _mp4Parser = fileInfo.mp4Parser;
        BOOL isOpenSuccess = [self onInputStart];
        if (!isOpenSuccess) {
            VAP_Event(kQGVAPModuleCommon, @"onInputStart fail!");
            *error = _constructErr;
            self = nil;
            return nil;
        }
        [self registerNotification];
    }
    return self;
}

- (void)registerNotification {

}

- (void)hwd_didReceiveEnterBackgroundNotification:(NSNotification *)notification {
    
}

- (void)decodeFrame:(NSInteger)frameIndex buffers:(NSMutableArray *)buffers {
    
    if (frameIndex == self.currentDecodeFrame) {
        VAP_Event(kQGVAPModuleCommon, @"already in decode");
        return ;
    }
    self.currentDecodeFrame = frameIndex;
    _buffers = buffers;
    dispatch_async(self.decodeQueue, ^{
        if (frameIndex != self.lastDecodeFrame + 1) {
            // 必须是依次增大，否则解出来的画面会异常
            return;
        }
        [self _decodeFrame:frameIndex drop:NO];
    });
}

- (void)_decodeFrame:(NSInteger)frameIndex drop:(BOOL)dropFlag {
    if (_isFinish) {
        return ;
    }
    
    if (!_buffers) {
        return ;
    }
    
    if (self.spsData == nil || self.ppsData == nil) {
        return ;
    }
    
    //解码开始时间
    NSDate *startDate = [NSDate date];
    NSData *packetData = [_mp4Parser readPacketOfSample:frameIndex];
    if (!packetData.length) {
        _finishFrameIndex = frameIndex;
        [self _onInputEnd];
        return;
    }
    
    // 获取当前帧pts,pts是在parse mp4 box时得到的
    uint64_t currentPts = [_mp4Parser.videoSamples[frameIndex] pts];
    
    CVPixelBufferRef outputPixelBuffer = NULL;
    // 4. get NALUnit payload into a CMBlockBuffer,
    CMBlockBufferRef blockBuffer = NULL;
    
    _status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                 (void *)packetData.bytes,
                                                 packetData.length,
                                                 kCFAllocatorNull, NULL, 0,
                                                 packetData.length, 0,
                                                 &blockBuffer);    
    // 6. create a CMSampleBuffer.
    CMSampleBufferRef sampleBuffer = NULL;
    const size_t sampleSizeArray[] = {packetData.length};
    _status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                        blockBuffer,
                                        _mFormatDescription,
                                        1, 0, NULL, 1, sampleSizeArray,
                                        &sampleBuffer);
    
    if (blockBuffer) {
        CFRelease(blockBuffer);
    }
    
    // 7. use VTDecompressionSessionDecodeFrame
    if (@available(iOS 9.0, *)) {
        __typeof(self) __weak weakSelf = self;
        VTDecodeFrameFlags flags = 0;
        VTDecodeInfoFlags flagOut = 0;
        OSStatus status = VTDecompressionSessionDecodeFrameWithOutputHandler(_mDecodeSession, sampleBuffer, flags, &flagOut, ^(OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef  _Nullable imageBuffer, CMTime presentationTimeStamp, CMTime presentationDuration) {
            __typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            
            [strongSelf handleDecodePixelBuffer:imageBuffer
                                   sampleBuffer:sampleBuffer
                                     frameIndex:frameIndex
                                     currentPts:currentPts
                                      startDate:startDate
                                         status:status
                                       needDrop:dropFlag];
        });
        
        if (status == kVTInvalidSessionErr) {
            CFRelease(sampleBuffer);
            
            // 防止陷入死循环
            if (_invalidRetryCount >= 3) {
                return;
            }
            
            [self resetDecoder];
            // 从最近I帧一直解码到当前帧，中间帧丢弃
            [self findKeyFrameAndDecodeToCurrent:frameIndex];
        } else {
            _invalidRetryCount = 0;
        }
        
    } else {
        // 7. use VTDecompressionSessionDecodeFrame
        VTDecodeFrameFlags flags = 0;
        VTDecodeInfoFlags flagOut = 0;
        _status = VTDecompressionSessionDecodeFrame(_mDecodeSession, sampleBuffer, flags, &outputPixelBuffer, &flagOut);
        
        if (_status == kVTInvalidSessionErr) {
            CFRelease(sampleBuffer);
            // 防止陷入死循环
            if (_invalidRetryCount >= 3) {
                return;
            }
            
            [self resetDecoder];
            // 从最近I帧一直解码到当前帧，中间帧丢弃
            [self findKeyFrameAndDecodeToCurrent:frameIndex];
            
            return;
        } else {
            _invalidRetryCount = 0;
        }
        
        [self handleDecodePixelBuffer:outputPixelBuffer
                         sampleBuffer:sampleBuffer
                           frameIndex:frameIndex
                           currentPts:currentPts
                            startDate:startDate
                               status:_status
                             needDrop:dropFlag];
        
    }
}

- (void)handleDecodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                   sampleBuffer:(CMSampleBufferRef)sampleBuffer
                     frameIndex:(NSInteger)frameIndex
                     currentPts:(uint64_t)currentPts
                      startDate:(NSDate *)startDate
                         status:(OSStatus)status
                       needDrop:(BOOL)dropFlag {
    
    self.lastDecodeFrame = frameIndex;
    
    CFRelease(sampleBuffer);
    
    if(status == kVTInvalidSessionErr) {
        VAP_Error(kQGVAPModuleCommon, @"decompress fail! frame:%@ kVTInvalidSessionErr error:%@", @(frameIndex), @(status));
    } else if(status == kVTVideoDecoderBadDataErr) {
        VAP_Error(kQGVAPModuleCommon, @"decompress fail! frame:%@ kVTVideoDecoderBadDataErr error:%@", @(frameIndex), @(status));
    } else if(status != noErr) {
        VAP_Error(kQGVAPModuleCommon, @"decompress fail! frame:%@ error:%@", @(frameIndex), @(status));
    }
    
    if (dropFlag) {
        return;
    }
    
    QGMP4AnimatedImageFrame *newFrame = [[QGMP4AnimatedImageFrame alloc] init];
    // imagebuffer会在frame回收时释放；拷贝出的 Metal 兼容 buffer 已由 Create 持有，勿再 Retain
    CVPixelBufferRef renderBuffer = QGVAPMetalCompatiblePixelBuffer(pixelBuffer);
    if (renderBuffer == pixelBuffer) {
        CVPixelBufferRetain(renderBuffer);
    }
    newFrame.pixelBuffer = renderBuffer;
    newFrame.frameIndex = frameIndex; //dts顺序
    NSTimeInterval decodeTime = [[NSDate date] timeIntervalSinceDate:startDate]*1000;
    newFrame.decodeTime = decodeTime;
    newFrame.defaultFps = (int)_mp4Parser.fps;
    newFrame.pts = currentPts;
    
    // 8. insert into buffer
    [_buffers addObject:newFrame];
    
    // 9. sort
    [_buffers sortUsingComparator:^NSComparisonResult(QGMP4AnimatedImageFrame * _Nonnull obj1, QGMP4AnimatedImageFrame * _Nonnull obj2) {
        return [@(obj1.pts) compare:@(obj2.pts)];
    }];
}

#pragma mark - override

- (BOOL)shouldStopDecode:(NSInteger)nextFrameIndex {
    return _isFinish;
}

- (BOOL)isFrameIndexBeyondEnd:(NSInteger)frameIndex {
    
    if (_finishFrameIndex > 0) {
        return (frameIndex >= _finishFrameIndex);
    }
    return NO;
}

-(void)dealloc {
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self _onInputEnd];
    self.fileInfo.occupiedCount --;
    if (self.fileInfo.occupiedCount <= 0) {
        
    }
}

#pragma mark - private methods

- (BOOL)onInputStart {
    
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    if (![fileMgr fileExistsAtPath:self.fileInfo.filePath]) {
        _constructErr = [NSError errorWithDomain:QGMP4HWDErrorDomain code:QGMP4HWDErrorCode_FileNotExist userInfo:[self errorUserInfo]];
        return NO;
    }
    
    _isFinish = NO;
    self.vpsData = nil;
    self.spsData = nil;
    self.ppsData = nil;
    _outputWidth = (int)_mp4Parser.picWidth;
    _outputHeight = (int)_mp4Parser.picHeight;
    
    BOOL paramsSetInitSuccess = [self initPPSnSPS];
    return paramsSetInitSuccess;
}

- (BOOL)initPPSnSPS {
    
    VAP_Info(kQGVAPModuleCommon, @"initPPSnSPS");
    if (self.spsData && self.ppsData) {
        VAP_Error(kQGVAPModuleCommon, @"sps&pps is already has value.");
        return YES;
    }
    
    self.spsData = _mp4Parser.spsData;
    self.ppsData = _mp4Parser.ppsData;
    self.vpsData = _mp4Parser.vpsData;
    
    // 2. create  CMFormatDescription
    if (self.spsData != nil && self.ppsData != nil && _mp4Parser.videoCodecID != QGMP4VideoStreamCodecIDUnknown) {
        if (_mp4Parser.videoCodecID == QGMP4VideoStreamCodecIDH264) {
            const uint8_t* const parameterSetPointers[2] = { (const uint8_t*)[self.spsData bytes], (const uint8_t*)[self.ppsData bytes] };
            const size_t parameterSetSizes[2] = { [self.spsData length], [self.ppsData length] };
            
            _status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                          2,
                                                                          parameterSetPointers,
                                                                          parameterSetSizes,
                                                                          4,
                                                                          &_mFormatDescription);
            if (_status != noErr) {
                VAP_Event(kQGVAPModuleCommon, @"CMVideoFormatDescription. Creation: %@.", (_status == noErr) ? @"successfully." : @"failed.");
                _constructErr = [NSError errorWithDomain:QGMP4HWDErrorDomain code:QGMP4HWDErrorCode_ErrorCreateVTBDesc userInfo:[self errorUserInfo]];
                return NO;
            }
        } else if (_mp4Parser.videoCodecID == QGMP4VideoStreamCodecIDH265) {
            if (@available(iOS 11.0, *)) {
                // 模拟器上 VTIsHardwareDecodeSupported 常返回 NO，但仍可能走 VideoToolbox 软解
                BOOL hevcDecodable = YES;
#if !TARGET_OS_SIMULATOR
                hevcDecodable = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
#endif
                if (hevcDecodable) {
                    const uint8_t* const parameterSetPointers[3] = {(const uint8_t*)[self.vpsData bytes], (const uint8_t*)[self.spsData bytes], (const uint8_t*)[self.ppsData bytes]};
                    const size_t parameterSetSizes[3] = {[self.vpsData length], [self.spsData length], [self.ppsData length]};
                    
                    _status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                                  3,                    // parameter_set_count
                                                                                  parameterSetPointers, // &parameter_set_pointers
                                                                                  parameterSetSizes,    // &parameter_set_sizes
                                                                                  4,                    // nal_unit_header_length
                                                                                  NULL,
                                                                                  &_mFormatDescription);
                    if (_status != noErr) {
                        VAP_Event(kQGVAPModuleCommon, @"CMVideoFormatDescription. Creation: %@.", (_status == noErr) ? @"successfully." : @"failed.");
                        _constructErr = [NSError errorWithDomain:QGMP4HWDErrorDomain code:QGMP4HWDErrorCode_ErrorCreateVTBDesc userInfo:[self errorUserInfo]];
                        return NO;
                    }
                } else {
                    VAP_Event(kQGVAPModuleCommon, @"H.265 decoding is un-supported because of the hardware");
                    return NO;
                }
            } else {
                VAP_Event(kQGVAPModuleCommon, @"System version is too low to support H.265 decoding");
                return NO;
            }
        }
    }
    
    // 3. create VTDecompressionSession
    return [self createDecompressionSession];;
}

// 模拟器 VideoToolbox 软解出的 buffer 常无 IOSurface，CVMetalTextureCache 会返回 -6660。
// 真机若已有 IOSurface 则直接复用；模拟器拷贝到 Metal 兼容的 NV12 buffer。
static CVPixelBufferRef QGVAPMetalCompatiblePixelBuffer(CVPixelBufferRef source) {
    if (!source) {
        return source;
    }
#if !TARGET_OS_SIMULATOR
    return source;
#endif
    size_t width = CVPixelBufferGetWidth(source);
    size_t height = CVPixelBufferGetHeight(source);
    OSType format = CVPixelBufferGetPixelFormatType(source);
    NSDictionary *attrs = @{
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef dest = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, (__bridge CFDictionaryRef)attrs, &dest);
    if (status != kCVReturnSuccess || !dest) {
        VAP_Error(kQGVAPModuleCommon, @"create metal-compatible pixelbuffer fail:%@", @(status));
        return source;
    }
    CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dest, 0);
    size_t planeCount = CVPixelBufferGetPlaneCount(source);
    if (planeCount == 0) {
        size_t bytesPerRow = MIN(CVPixelBufferGetBytesPerRow(source), CVPixelBufferGetBytesPerRow(dest));
        size_t rows = CVPixelBufferGetHeight(source);
        uint8_t *src = (uint8_t *)CVPixelBufferGetBaseAddress(source);
        uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(dest);
        size_t srcBPR = CVPixelBufferGetBytesPerRow(source);
        size_t dstBPR = CVPixelBufferGetBytesPerRow(dest);
        for (size_t row = 0; row < rows; row++) {
            memcpy(dst + row * dstBPR, src + row * srcBPR, bytesPerRow);
        }
    } else {
        for (size_t plane = 0; plane < planeCount; plane++) {
            uint8_t *src = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source, plane);
            uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dest, plane);
            size_t srcBPR = CVPixelBufferGetBytesPerRowOfPlane(source, plane);
            size_t dstBPR = CVPixelBufferGetBytesPerRowOfPlane(dest, plane);
            size_t rows = CVPixelBufferGetHeightOfPlane(source, plane);
            size_t bytesPerRow = MIN(srcBPR, dstBPR);
            for (size_t row = 0; row < rows; row++) {
                memcpy(dst + row * dstBPR, src + row * srcBPR, bytesPerRow);
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(dest, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    NSDictionary *attachments = (__bridge_transfer NSDictionary *)CVBufferCopyAttachments(source, kCVAttachmentMode_ShouldPropagate);
    [attachments enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        CVBufferSetAttachment(dest, (__bridge CFStringRef)key, (__bridge CFTypeRef)obj, kCVAttachmentMode_ShouldPropagate);
    }];
    return dest;
}

- (BOOL)createDecompressionSession {
    // NV12，并声明 Metal/IOSurface 兼容，便于 CVMetalTextureCache 直接绑纹理（模拟器软解尤其需要）
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CFDictionaryRef attrsRef = (__bridge CFDictionaryRef)attrs;
    
    if ([UIDevice currentDevice].systemVersion.floatValue >= 9.0) {
        _status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                               _mFormatDescription,
                                               NULL,
                                               attrsRef,
                                               NULL,
                                               &_mDecodeSession);
        if (_status != noErr) {
            _constructErr = [NSError errorWithDomain:QGMP4HWDErrorDomain code:QGMP4HWDErrorCode_ErrorCreateVTBSession userInfo:[self errorUserInfo]];
            return NO;
        }
    } else {
        VTDecompressionOutputCallbackRecord callBackRecord;
        callBackRecord.decompressionOutputCallback = didDecompress;
        callBackRecord.decompressionOutputRefCon = NULL;
        
        _status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                               _mFormatDescription,
                                               NULL, attrsRef,
                                               &callBackRecord,
                                               &_mDecodeSession);
        if (_status != noErr) {
            _constructErr = [NSError errorWithDomain:QGMP4HWDErrorDomain code:QGMP4HWDErrorCode_ErrorCreateVTBSession userInfo:[self errorUserInfo]];
            return NO;
        }
    }
    return YES;
}

- (void)resetDecoder {
    // delete
    if (_mDecodeSession) {
        VTDecompressionSessionWaitForAsynchronousFrames(_mDecodeSession);
        VTDecompressionSessionInvalidate(_mDecodeSession);
        CFRelease(_mDecodeSession);
        _mDecodeSession = NULL;
    }
    
    // recreate
    [self createDecompressionSession];
}

- (void)findKeyFrameAndDecodeToCurrent:(NSInteger)frameIndex {
    
    [[NSNotificationCenter defaultCenter] postNotificationName:kQGVAPDecoderSeekStart object:self];
    
    NSArray<NSNumber *> *keyframeIndexes = [_mp4Parser videoSyncSampleIndexes];
    NSInteger index = [[keyframeIndexes firstObject] integerValue];
    for(NSNumber *number in keyframeIndexes) {
        if(number.integerValue < frameIndex) {
            index = number.integerValue;
            continue;
        } else {
            break;
        }
    }
    
    // seek to last key frame
    while (index < frameIndex) {
        [self _decodeFrame:index drop:YES];
        index++;
    }
    [self _decodeFrame:frameIndex drop:NO];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:kQGVAPDecoderSeekFinish object:self];
}

- (void)_onInputEnd  {
    if (_isFinish) {
        return ;
    }
    _isFinish = YES;
    if (_mDecodeSession) {
        VTDecompressionSessionWaitForAsynchronousFrames(_mDecodeSession);
        VTDecompressionSessionInvalidate(_mDecodeSession);
        CFRelease(_mDecodeSession);
        _mDecodeSession = NULL;
    }
    if (self.spsData || self.ppsData || self.vpsData) {
        self.spsData = nil;
        self.ppsData = nil;
        self.vpsData = nil;
    }
    if (_mFormatDescription) {
        CFRelease(_mFormatDescription);
        _mFormatDescription = NULL;
    }
}

- (void)onInputEnd {
    
    //为确保任务停止，必须同步执行
    __weak __typeof(self) weakSelf = self;
    if ([NSThread isMainThread]) {
        dispatch_sync(self.decodeQueue, ^{
            [weakSelf _onInputEnd];
        });
    } else {
        dispatch_async(self.decodeQueue, ^{
            [weakSelf _onInputEnd];
        });
    }
}

//decode callback
static void didDecompress(void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef pixelBuffer, CMTime presentationTimeStamp, CMTime presentationDuration ){
    
    CVPixelBufferRef *outputPixelBuffer = (CVPixelBufferRef *)sourceFrameRefCon;
    *outputPixelBuffer = CVPixelBufferRetain(pixelBuffer);
}

- (NSDictionary *)errorUserInfo {
    NSDictionary *userInfo = @{@"location" : self.fileInfo.filePath ? : @""};
    return userInfo;
}

@end
