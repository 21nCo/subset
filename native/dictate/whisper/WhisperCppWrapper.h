//
//  WhisperCppWrapper.h
//  Dictate
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WhisperCppWrapper : NSObject

- (nullable instancetype)initWithModelPath:(NSString *)modelPath;
- (nullable instancetype)initWithModelPath:(NSString *)modelPath coreMLModelPath:(nullable NSString *)coreMLModelPath;

- (NSString * _Nullable)transcribeAudioAtPath:(NSString *)audioPath error:(NSError **)error;
- (NSString * _Nullable)transcribeAudioAtPath:(NSString *)audioPath
                                     language:(nullable NSString *)language
                           enableDiarization:(BOOL)enableDiarization
                             enableTimestamps:(BOOL)enableTimestamps
                        enableImprovedFormat:(BOOL)enableImprovedFormat
                                       error:(NSError **)error;

- (NSString * _Nullable)transcribeAudioFromPCMData:(const float *)pcmData
                                        sampleCount:(int)sampleCount
                                         sampleRate:(int)sampleRate
                                              error:(NSError **)error;

- (NSString * _Nullable)transcribeAudioFromPCMData:(const float *)pcmData
                                        sampleCount:(int)sampleCount
                                         sampleRate:(int)sampleRate
                                           language:(nullable NSString *)language
                                 enableDiarization:(BOOL)enableDiarization
                                   enableTimestamps:(BOOL)enableTimestamps
                              enableImprovedFormat:(BOOL)enableImprovedFormat
                                             error:(NSError **)error;

+ (NSString *)version;
/// Decodes whisper.cpp segment text, which is UTF-8. Invalid byte sequences become U+FFFD instead
/// of dropping the segment.
+ (NSString *)stringFromSegmentText:(nullable const char *)text;
- (BOOL)isUsingCoreML;

@end

NS_ASSUME_NONNULL_END
