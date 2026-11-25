// Headless diagnostics using the application's STK1160 driver and frame decoder.
#import "ECVSTK1160Device.h"
#import "ECVVideoFrame.h"
#import "ECVDeinterlacingMode.h"
#import <signal.h>
#import <math.h>
#import <time.h>
#import <fcntl.h>
static double monotonicTime(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec+t.tv_nsec/1e9; }

static volatile sig_atomic_t interrupted = 0;
static BOOL sharedDevice = NO;
static void interruptCapture(int signalNumber) { interrupted = 1; }

@interface ECVHeadlessDevice : ECVSTK1160Device
@property NSUInteger frames;
@property FILE *movieFile;
@property dispatch_queue_t movieQueue;
@property dispatch_semaphore_t movieSlots;
@property BOOL movieFailed;
@property NSMutableArray *frameTimes;
@property double firstFrameTime;
@property double lastFrameTime;
@property NSData *latest;
@property ECVIntegerSize size;
@property OSType format;
@property BOOL finished;
@property NSDictionary *decoderRegisters;
@property NSNumber *decoderInput;
@end

@implementation ECVHeadlessDevice
- (BOOL)usesSharedUSBDevice { return sharedDevice; }
// Diagnostic override for dongles wired to a different decoder analog pin.
- (BOOL)writeSAA711XRegister:(uint8_t)reg value:(int16_t)value {
    if (reg == 0x02 && self.decoderInput) value = (value & 0xf0) | self.decoderInput.intValue;
    return [super writeSAA711XRegister:reg value:value];
}
// Reuse USB and pixel decoding, without constructing a UI/audio capture session.
- (void)pushVideoFrame:(ECVVideoFrame *)frame {
    if (!frame || ![frame lockIfHasBytes]) return;
    @autoreleasepool {
    @synchronized(self) {
        self.frames++;
        double frameTime = monotonicTime();
        if (self.frames == 1) self.firstFrameTime = frameTime;
        self.lastFrameTime = frameTime;
        if (self.frames == 30) {
            NSMutableDictionary *registers = [NSMutableDictionary dictionary];
            for (NSNumber *reg in @[@0x00, @0x02, @0x08, @0x0a, @0x0b, @0x1f]) {
                uint8_t value = 0;
                if ([self readSAA711XRegister:reg.unsignedCharValue value:&value])
                    registers[[NSString stringWithFormat:@"0x%02x", reg.unsignedCharValue]] = @(value);
            }
            self.decoderRegisters = registers;
        }
        self.size = frame.pixelSize;
        self.format = frame.pixelFormat;
        NSMutableData *pixels = [NSMutableData dataWithLength:self.size.width * self.size.height * 2];
        for (NSUInteger y = 0; y < self.size.height; y++) {
            memcpy((uint8_t *)pixels.mutableBytes + y * self.size.width * 2,
                   (const uint8_t *)frame.bytes + y * frame.bytesPerRow, self.size.width * 2);
        }
        self.latest = pixels;
        if (self.movieFile) {
            [self.frameTimes addObject:@(frameTime)];
            if (dispatch_semaphore_wait(self.movieSlots, DISPATCH_TIME_NOW)) self.movieFailed = YES;
            else dispatch_async(self.movieQueue, ^{
                if (fwrite(pixels.bytes, 1, pixels.length, self.movieFile) != pixels.length) self.movieFailed = YES;
                dispatch_semaphore_signal(self.movieSlots);
            });
        }
    }
    }
    [frame unlock];
}
- (void)read {
    @try { [super read]; }
    @finally { @synchronized(self) { self.finished = YES; } }
}
@end

static int usage(void) {
    fprintf(stderr, "Usage: ecv-capture [--standard pal|ntsc|secam] [--input composite|svideo|1|2|3|4]\n"
                    "                   [--seconds 5] [--output frame.uyvy] [--decoder-input 0|1|2|3] [--shared-device] [--raw-video NEW.uyvy]\n"
                    "Starts immediately, emits a JSON summary, saves the last packed UYVY frame.\n"
                    "Video only. Close EasyCapViewer first. Ctrl-C stops capture.\n");
    return 2;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *standard = @"pal", *input = @"composite", *output = nil, *movie = nil;
        double seconds = 5;
        NSNumber *decoderInput = nil;
        for (int i = 1; i < argc; i++) {
            NSString *arg = @(argv[i]);
            if ([arg isEqual:@"--shared-device"]) { sharedDevice = YES; continue; }
            if ([arg isEqual:@"--help"]) { usage(); return 0; }
            if (++i >= argc) return usage();
            NSString *value = @(argv[i]);
            if ([arg isEqual:@"--standard"]) standard = value;
            else if ([arg isEqual:@"--input"]) input = value;
            else if ([arg isEqual:@"--output"]) output = value;
            else if ([arg isEqual:@"--raw-video"]) movie = value;
            else if ([arg isEqual:@"--decoder-input"]) {
                if (![@[@"0", @"1", @"2", @"3"] containsObject:value]) return usage();
                decoderInput = @(value.intValue);
            }
            else if ([arg isEqual:@"--seconds"]) {
                char *end = NULL;
                seconds = strtod(argv[i], &end);
                if (end == argv[i] || *end || !isfinite(seconds) || seconds <= 0 || seconds > 3600) return usage();
            } else return usage();
        }
        NSDictionary *formats = @{@"pal": [ECVVideoFormat_PAL_BGDHI class],
                                  @"ntsc": [ECVVideoFormat_NTSC_M class],
                                  @"secam": [ECVVideoFormat_SECAM class]};
        NSDictionary *inputs = @{@"composite": @"ECVSTK11X0VideoSource_Composite1",
                                 @"1": @"ECVSTK11X0VideoSource_Composite1",
                                 @"2": @"ECVSTK11X0VideoSource_Composite2",
                                 @"3": @"ECVSTK11X0VideoSource_Composite3",
                                 @"4": @"ECVSTK11X0VideoSource_Composite4",
                                 @"svideo": @"ECVSTK11X0VideoSource_SVideo"};
        if (!formats[standard] || !inputs[input]) return usage();
        signal(SIGINT, interruptCapture);
        signal(SIGTERM, interruptCapture);
        NSMutableDictionary *match = CFBridgingRelease(IOServiceMatching(kIOUSBDeviceClassName));
        match[@kUSBVendorID] = @0x05e1;
        match[@kUSBProductID] = @0x0408;
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, (__bridge_retained CFDictionaryRef)match);
        if (!service) { fprintf(stderr, "STK1160 (05e1:0408) is not connected.\n"); return 1; }
        ECVHeadlessDevice *device = [[ECVHeadlessDevice alloc] initWithService:service];
        IOObjectRelease(service);
        if (!device) { fprintf(stderr, "Cannot open STK1160. Close other capture apps.\n"); return 1; }
        if (movie) {
            int fd = open(movie.fileSystemRepresentation, O_WRONLY|O_CREAT|O_EXCL, 0600);
            if (fd < 0) { perror("raw video"); return 1; }
            device.movieFile = fdopen(fd, "wb");
            if (!device.movieFile) { close(fd); return 1; }
            device.frameTimes = [NSMutableArray array];
            device.movieQueue = dispatch_queue_create("ecv.movie", DISPATCH_QUEUE_SERIAL);
            device.movieSlots = dispatch_semaphore_create(8);
        }
        device.decoderInput = decoderInput;
        Class formatClass = formats[standard];
        [device setVideoFormat:[formatClass format]];
        [device setVideoSource:[NSClassFromString(inputs[input]) source]];
        [device setDeinterlacingMode:[ECVDeinterlacingMode deinterlacingModeWithType:ECVWeave]];
        NSDate *start = [NSDate date];
        [device play];
        while (!interrupted && -start.timeIntervalSinceNow < seconds) {
            @synchronized(device) { if (device.finished) break; }
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        [device stop];
        // The USB thread finishes asynchronously. Bound shutdown for a removed device.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (deadline.timeIntervalSinceNow > 0) {
            @synchronized(device) { if (device.finished) break; }
            [NSThread sleepForTimeInterval:0.02];
        }
        if (device.movieFile) {
            if (!device.finished) { fprintf(stderr, "Video thread did not stop; raw movie incomplete\n"); return 1; }
            dispatch_sync(device.movieQueue, ^{});
            if (fclose(device.movieFile)) device.movieFailed = YES;
            device.movieFile = NULL;
        }
        @synchronized(device) {
            NSData *pixels = device.latest;
            double sum = 0;
            unsigned low = 255, high = 0;
            const uint8_t *bytes = pixels.bytes;
            for (NSUInteger i = 1; i < pixels.length; i += 2) {
                low = MIN(low, bytes[i]); high = MAX(high, bytes[i]); sum += bytes[i];
            }
            NSError *error = nil;
            if (output && pixels && ![pixels writeToFile:output options:NSDataWritingAtomic error:&error]) {
                fprintf(stderr, "Cannot write frame: %s\n", error.localizedDescription.UTF8String); return 1;
            }
            NSNumber *status = device.decoderRegisters[@"0x1f"];
            // SAA711x status register bit 6 means horizontal/vertical sync is unlocked.
            // Keep the raw register too: clone chips may need different interpretation.
            id syncLocked = status ? (id)@((BOOL)!(status.unsignedCharValue & 0x40)) : [NSNull null];
            NSDictionary *result = @{@"sync_locked": syncLocked, @"decoder_registers": device.decoderRegisters ?: @{}, @"device": @"05e1:0408", @"standard": standard, @"input": input,
                @"frame_times": device.frameTimes ?: @[], @"first_frame_monotonic": @(device.firstFrameTime), @"last_frame_monotonic": @(device.lastFrameTime), @"movie_failed": @(device.movieFailed),
                @"frames": @(device.frames), @"width": @(device.size.width), @"height": @(device.size.height),
                @"pixel_format": @"uyvy422", @"pixel_format_code": @(device.format),
                @"luma_min": @(pixels.length ? low : 0), @"luma_max": @(high),
                @"luma_mean": @(pixels.length ? sum / (pixels.length / 2) : 0),
                @"output": output && pixels ? output : (id)[NSNull null]};
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
            fwrite(json.bytes, 1, json.length, stdout); puts("");
            return device.frames && !device.movieFailed ? 0 : 1;
        }
    }
}
