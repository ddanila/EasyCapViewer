// Bounded native audio capture. No single-slot polling buffer or silent gap repair.
#import <AVFoundation/AVFoundation.h>
#import <signal.h>
#import <math.h>
static volatile sig_atomic_t interrupted;
static void stopCapture(int sig) { interrupted = 1; }

@interface AudioRecorder : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property NSString *path;
@property AVAudioFile *file;
@property NSString *failure;
@property NSUInteger buffers, frames, gaps;
@property double rate, firstPTS, endPTS, maxGap;
@end
@implementation AudioRecorder
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        if (self.failure) return;
        const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
        if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM) { self.failure = @"Expected PCM audio"; return; }
        AVAudioFormat *format = [[AVAudioFormat alloc] initWithStreamDescription:asbd];
        NSError *error = nil;
        if (!self.file) {
            self.rate = asbd->mSampleRate;
            self.file = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:self.path] settings:format.settings commonFormat:format.commonFormat interleaved:format.interleaved error:&error];
            if (!self.file) { self.failure = error.localizedDescription; return; }
        }
        if (![format isEqual:self.file.processingFormat]) { self.failure = @"Audio format changed during capture"; return; }
        size_t size = 0;
        OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, &size, NULL, 0, NULL, NULL, 0, NULL);
        // The size query may report that the omitted buffer is too small.
        if (!size) { self.failure = [NSString stringWithFormat:@"Cannot size audio buffer: %d", (int)status]; return; }
        AudioBufferList *list = malloc(size);
        CMBlockBufferRef block = NULL;
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, NULL, list, size, kCFAllocatorDefault, kCFAllocatorDefault, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block);
        if (status) { free(list); self.failure = [NSString stringWithFormat:@"Cannot read audio buffer: %d", (int)status]; return; }
        AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format bufferListNoCopy:list deallocator:nil];
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
        if (argc != 4) { fprintf(stderr, "Usage: ecv-audio DEVICE_NAME SECONDS OUTPUT.caf\nRecords native PCM; refuses to overwrite files. SIGINT/SIGTERM finalize capture.\n"); return 2; }
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
        dispatch_sync(queue, ^{ recorder.file = nil; }); // Drain callbacks and finalize the CAF header.
        NSDictionary *report = @{@"device": device.localizedName, @"output": path,
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
