// Bounded native audio capture. No single-slot polling buffer or silent gap repair.
#import <AVFoundation/AVFoundation.h>
#import <signal.h>
#import <math.h>
#import "ECVAudioDiagnostics.h"
#import <fcntl.h>
static volatile sig_atomic_t interrupted;
static void stopCapture(int sig) { interrupted = 1; }

@interface AudioRecorder : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property NSString *path;
@property NSFileHandle *diagnostics;
@property dispatch_queue_t writerQueue;
@property dispatch_semaphore_t slots;
@property NSUInteger queueOverruns;
@property NSUInteger frameMismatches;
@property NSDictionary *audioFormat;
@property AVAudioFile *file;
@property NSString *failure;
@property NSUInteger buffers, frames, gaps;
@property double rate, firstPTS, endPTS, maxGap;
@end
@implementation AudioRecorder
- (instancetype)init {
    if ((self = [super init])) {
        self.writerQueue = dispatch_queue_create("ecv.audio.writer", DISPATCH_QUEUE_SERIAL);
        self.slots = dispatch_semaphore_create(128);
    }
    return self;
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    if (dispatch_semaphore_wait(self.slots, DISPATCH_TIME_NOW)) {
        self.queueOverruns++; self.failure = @"Audio writer queue overflow"; return;
    }
    // CMSampleBuffer copy owns references to its immutable media block; it remains
    // valid after the callback. The serial worker releases it after writing.
    CMSampleBufferRef owned = NULL;
    OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sample, &owned);
    if (status) { self.failure = @"Cannot retain audio sample"; dispatch_semaphore_signal(self.slots); return; }
    dispatch_async(self.writerQueue, ^{
        [self processSample:owned];
        CFRelease(owned);
        dispatch_semaphore_signal(self.slots);
    });
}
- (void)processSample:(CMSampleBufferRef)sample {
    @autoreleasepool {
        if (self.failure) return;
        const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
        if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM) { self.failure = @"Expected PCM audio"; return; }
        AVAudioFormat *format = [[AVAudioFormat alloc] initWithStreamDescription:asbd];
        NSError *error = nil;
        if (!self.file) {
            self.rate = asbd->mSampleRate;
            self.audioFormat = @{@"sample_rate": @(asbd->mSampleRate), @"channels": @(asbd->mChannelsPerFrame), @"bits_per_channel": @(asbd->mBitsPerChannel), @"format_flags": @(asbd->mFormatFlags)};
            self.file = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:self.path] settings:format.settings commonFormat:format.commonFormat interleaved:format.interleaved error:&error];
            if (!self.file) { self.failure = error.localizedDescription; return; }
        }
        if (![format isEqual:self.file.processingFormat]) { self.failure = @"Audio format changed during capture"; return; }
        size_t size = 0;
        OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, &size, NULL, 0, NULL, NULL, 0, NULL);
        // The size query may report that the omitted buffer is too small.
        if (!size) { self.failure = [NSString stringWithFormat:@"Cannot size audio buffer: %d", (int)status]; return; }
        AudioBufferList *list = malloc(size);
        if (!list) { self.failure = @"Cannot allocate audio buffer list"; return; }
        CMBlockBufferRef block = NULL;
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, NULL, list, size, kCFAllocatorDefault, kCFAllocatorDefault, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block);
        if (status) { free(list); self.failure = [NSString stringWithFormat:@"Cannot read audio buffer: %d", (int)status]; return; }
        AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format bufferListNoCopy:list deallocator:nil];
        if (pcm && pcm.frameLength != CMSampleBufferGetNumSamples(sample)) { self.frameMismatches++; self.failure = @"PCM/sample frame count mismatch"; }
        if (self.diagnostics && pcm) {
            NSMutableArray *zeros = [NSMutableArray array];
            for (NSUInteger b = 0; b < list->mNumberBuffers; b++) {
                AudioBuffer buffer = list->mBuffers[b];
                NSUInteger zeroBytes = 0;
                const uint8_t *bytes = buffer.mData;
                for (NSUInteger j = 0; j < buffer.mDataByteSize; j++) zeroBytes += bytes[j] == 0;
                [zeros addObject:@{@"bytes": @(buffer.mDataByteSize), @"zero_bytes": @(zeroBytes), @"channels": @(buffer.mNumberChannels)}];
            }
            NSDictionary *row = @{@"pts": @(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))), @"sample_frames": @(CMSampleBufferGetNumSamples(sample)), @"pcm_frames": @(pcm.frameLength), @"buffers": zeros, @"channels": ECVChannelStats(pcm)};
            [self.diagnostics writeData:[NSJSONSerialization dataWithJSONObject:row options:0 error:NULL]];
            [self.diagnostics writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
        if (!pcm || ![self.file writeFromBuffer:pcm error:&error]) self.failure = error.localizedDescription ?: @"Cannot write PCM buffer";
        else {
            double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
            if (self.buffers) {
                double gap = pts - self.endPTS;
                if (fabs(gap) > 2.0 / self.rate) { self.gaps++; self.maxGap = MAX(self.maxGap, fabs(gap)); }
            } else self.firstPTS = pts;
            self.endPTS = pts + pcm.frameLength / self.rate;
            self.frames += pcm.frameLength;
            self.buffers++;
        }
        pcm = nil;
        if (block) CFRelease(block);
        free(list);
    }
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4 && !(argc == 6 && strcmp(argv[4], "--diagnostics") == 0)) { fprintf(stderr, "Usage: ecv-audio DEVICE_NAME SECONDS OUTPUT.caf [--diagnostics PATH]\nRecords native PCM; refuses to overwrite files. SIGINT/SIGTERM finalize capture.\n"); return 2; }
        char *end = NULL;
        double seconds = strtod(argv[2], &end);
        if (end == argv[2] || *end || !isfinite(seconds) || seconds <= 0 || seconds > 3600) return 2;
        NSString *path = @(argv[3]);
        if (![path.pathExtension.lowercaseString isEqual:@"caf"] || [[NSFileManager defaultManager] fileExistsAtPath:path]) { fprintf(stderr, "Use a new .caf output path.\n"); return 2; }
        AVCaptureDevice *device = nil;
        for (AVCaptureDevice *candidate in [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio]) {
            if ([candidate.localizedName isEqual:@(argv[1])]) {
                if (device) { fprintf(stderr, "Ambiguous audio device name.\n"); return 2; }
                device = candidate;
            }
        }
        if (!device) { fprintf(stderr, "Audio device not found.\n"); return 1; }
        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (!input) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
        AVCaptureSession *session = [AVCaptureSession new];
        AVCaptureAudioDataOutput *output = [AVCaptureAudioDataOutput new];
        AudioRecorder *recorder = [AudioRecorder new]; recorder.path = path;
        if (argc == 6) {
            int fd = open(argv[5], O_WRONLY | O_CREAT | O_EXCL, 0600);
            if (fd < 0) { perror("diagnostics"); return 2; }
            recorder.diagnostics = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
        }
        dispatch_queue_t queue = dispatch_queue_create("ecv.audio.capture", DISPATCH_QUEUE_SERIAL);
        [output setSampleBufferDelegate:recorder queue:queue];
        if (![session canAddInput:input]) return 1;
        [session addInput:input];
        if (![session canAddOutput:output]) return 1;
        [session addOutput:output];
        signal(SIGINT, stopCapture); signal(SIGTERM, stopCapture);
        [session startRunning];
        double start = NSProcessInfo.processInfo.systemUptime;
        while (!interrupted && NSProcessInfo.processInfo.systemUptime - start < seconds) {
            __block BOOL failed;
            dispatch_sync(queue, ^{ failed = recorder.failure != nil; });
            if (failed) break;
            [NSThread sleepForTimeInterval:0.02];
        }
        [session stopRunning];
        dispatch_sync(queue, ^{});
        dispatch_sync(recorder.writerQueue, ^{ recorder.file = nil; }); // Drain callbacks and finalize the CAF header.
        NSDictionary *report = @{@"backend": @"avfoundation", @"audio_format": recorder.audioFormat ?: @{}, @"device": device.localizedName, @"device_uid": device.uniqueID, @"active_microphone_mode": @([AVCaptureDevice activeMicrophoneMode]), @"preferred_microphone_mode": @([AVCaptureDevice preferredMicrophoneMode]), @"frame_mismatches": @(recorder.frameMismatches), @"queue_overruns": @(recorder.queueOverruns), @"output": path,
            @"buffers": @(recorder.buffers), @"sample_frames": @(recorder.frames),
            @"sample_rate": @(recorder.rate), @"sample_seconds": @(recorder.rate ? recorder.frames / recorder.rate : 0),
            @"timeline_seconds": @(recorder.buffers ? recorder.endPTS - recorder.firstPTS : 0),
            @"timestamp_gaps": @(recorder.gaps), @"max_gap_seconds": @(recorder.maxGap),
            @"error": recorder.failure ?: (id)[NSNull null]};
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
        fwrite(json.bytes, 1, json.length, stdout); puts("");
        return recorder.failure || !recorder.frames || recorder.gaps ? 1 : 0;
    }
}
