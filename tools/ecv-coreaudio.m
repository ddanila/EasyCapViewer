// Direct Core Audio comparison recorder. The realtime callback only copies into
// a preallocated single-producer/single-consumer ring; the main thread writes.
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/HostTime.h>
#import <stdatomic.h>
#import <signal.h>
#import <math.h>
#import "ECVAudioDiagnostics.h"
#import <fcntl.h>
#define SLOTS 256
#define MAX_BYTES 65536
#define MAX_BUFFERS 8
typedef struct { UInt32 count, lengths[MAX_BUFFERS], channels[MAX_BUFFERS]; AudioTimeStamp time; unsigned char bytes[MAX_BYTES]; } Slot;
typedef struct { Slot slots[SLOTS]; atomic_uint written, read, overflow, invalid; } Ring;
static volatile sig_atomic_t interrupted;
static void stopCapture(int sig) { interrupted = 1; }
static OSStatus receive(AudioDeviceID dev, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *time, AudioBufferList *output, const AudioTimeStamp *outTime, void *context) {
    Ring *ring = context;
    unsigned w = atomic_load_explicit(&ring->written, memory_order_relaxed);
    unsigned r = atomic_load_explicit(&ring->read, memory_order_acquire);
    if (w-r >= SLOTS) { atomic_fetch_add(&ring->overflow, 1); return noErr; }
    if (!input || input->mNumberBuffers > MAX_BUFFERS) { atomic_fetch_add(&ring->invalid, 1); return noErr; }
    Slot *slot = &ring->slots[w % SLOTS]; slot->count = input->mNumberBuffers; slot->time = *time;
    size_t offset = 0;
    for (UInt32 b=0; b<input->mNumberBuffers; b++) {
        AudioBuffer buffer=input->mBuffers[b];
        if (!buffer.mData || offset+buffer.mDataByteSize > MAX_BYTES) { atomic_fetch_add(&ring->invalid, 1); return noErr; }
        slot->lengths[b]=buffer.mDataByteSize; slot->channels[b]=buffer.mNumberChannels;
        memcpy(slot->bytes+offset, buffer.mData, buffer.mDataByteSize); offset+=buffer.mDataByteSize;
    }
    atomic_store_explicit(&ring->written, w+1, memory_order_release);
    return noErr;
}
static OSStatus get(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, UInt32 *size, void *data) {
    AudioObjectPropertyAddress address={selector,scope,kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(object,&address,0,NULL,size,data);
}
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc < 4 || (argc-4)%2) { fprintf(stderr,"Usage: ecv-coreaudio DEVICE_NAME SECONDS OUTPUT.caf [--diagnostics PATH] [--buffer-frames N]\n"); return 2; }
    const char *diagnosticPath = NULL; UInt32 requestedFrames = 0;
    for(int i=4;i<argc;i+=2) {
        if(!strcmp(argv[i],"--diagnostics")) diagnosticPath=argv[i+1];
        else if(!strcmp(argv[i],"--buffer-frames")) { char *tail; unsigned long v=strtoul(argv[i+1],&tail,10); if(*tail||v<32||v>16384)return 2;requestedFrames=(UInt32)v; }
        else return 2;
    }
    char *end; double seconds=strtod(argv[2],&end);
    if (end==argv[2] || *end || !isfinite(seconds) || seconds<=0 || seconds>3600) return 2;
    NSString *path=@(argv[3]);
    if (![path.pathExtension.lowercaseString isEqual:@"caf"] || [[NSFileManager defaultManager] fileExistsAtPath:path]) return 2;
    AudioObjectPropertyAddress address={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&address,0,NULL,&size)) return 1;
    AudioDeviceID *devices=malloc(size); if (!devices) return 1;
    if (get(kAudioObjectSystemObject,kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,&size,devices)) { free(devices); return 1; }
    AudioDeviceID device=0;
    for (NSUInteger i=0;i<size/sizeof(*devices);i++) {
        CFStringRef name=NULL; UInt32 len=sizeof(name);
        if (!get(devices[i],kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,&len,&name)) {
            BOOL matches=[(__bridge NSString *)name isEqual:@(argv[1])]; CFRelease(name);
            if (matches) { if (device) { free(devices); return 2; } device=devices[i]; }
        }
    }
    free(devices); if (!device) { fprintf(stderr,"Audio device not found\n"); return 1; }
    AudioStreamBasicDescription asbd={0}; size=sizeof(asbd);
    if (get(device,kAudioDevicePropertyStreamFormat,kAudioDevicePropertyScopeInput,&size,&asbd) || asbd.mFormatID!=kAudioFormatLinearPCM) return 1;
    CFStringRef uid=NULL; size=sizeof(uid); get(device,kAudioDevicePropertyDeviceUID,kAudioObjectPropertyScopeGlobal,&size,&uid);
    AVAudioFormat *format=[[AVAudioFormat alloc] initWithStreamDescription:&asbd];
    NSError *error=nil;
    AVAudioFile *file=[[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:path] settings:format.settings commonFormat:format.commonFormat interleaved:format.interleaved error:&error];
    if (!file) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); if(uid)CFRelease(uid); return 1; }
    NSFileHandle *diagnostics=nil;
    if(diagnosticPath) { int fd=open(diagnosticPath,O_WRONLY|O_CREAT|O_EXCL,0600); if(fd<0){perror("diagnostics");return 2;} diagnostics=[[NSFileHandle alloc]initWithFileDescriptor:fd closeOnDealloc:YES]; }
    UInt32 originalFrames=0; size=sizeof(originalFrames);
    if(get(device,kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,&size,&originalFrames))return 1;
    AudioObjectPropertyAddress frameAddress={kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    if(requestedFrames && AudioObjectSetPropertyData(device,&frameAddress,0,NULL,sizeof(requestedFrames),&requestedFrames)) { fprintf(stderr,"Unsupported buffer size\n");return 2; }
    UInt32 actualFrames=0;size=sizeof(actualFrames);get(device,kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,&size,&actualFrames);
    Ring *ring=calloc(1,sizeof(Ring)); if(!ring){if(requestedFrames)AudioObjectSetPropertyData(device,&frameAddress,0,NULL,sizeof(originalFrames),&originalFrames);return 1;}
    AudioDeviceIOProcID proc=NULL;
    OSStatus status=AudioDeviceCreateIOProcID(device,receive,ring,&proc);
    if(!status)status=AudioDeviceStart(device,proc);
    if(status){fprintf(stderr,"Core Audio start failed: %d\n",(int)status);if(proc)AudioDeviceDestroyIOProcID(device,proc);if(requestedFrames)AudioObjectSetPropertyData(device,&frameAddress,0,NULL,sizeof(originalFrames),&originalFrames);free(ring);return 1;}
    signal(SIGINT,stopCapture); signal(SIGTERM,stopCapture);
    double start=NSProcessInfo.processInfo.systemUptime, first=0,last=0,maxGap=0,lastSample=0;
    NSUInteger frames=0,buffers=0,gaps=0,resets=0; BOOL running=YES; NSString *failure=nil;
    while(running || atomic_load(&ring->read)!=atomic_load(&ring->written)) { @autoreleasepool {
        if(running && (interrupted || failure || atomic_load(&ring->overflow) || atomic_load(&ring->invalid) || NSProcessInfo.processInfo.systemUptime-start>=seconds)) {
            AudioDeviceStop(device,proc); running=NO;
        }
        unsigned r=atomic_load_explicit(&ring->read,memory_order_relaxed);
        if(r==atomic_load_explicit(&ring->written,memory_order_acquire)) { [NSThread sleepForTimeInterval:.002]; continue; }
        Slot *slot=&ring->slots[r%SLOTS];
        struct { UInt32 count; AudioBuffer buffers[MAX_BUFFERS]; } list={0}; list.count=slot->count;
        size_t offset=0; NSMutableArray *details=[NSMutableArray array];
        for(UInt32 b=0;b<slot->count;b++) {
            list.buffers[b]=(AudioBuffer){slot->channels[b],slot->lengths[b],slot->bytes+offset};
            NSUInteger zeros=0;for(UInt32 j=0;j<slot->lengths[b];j++)zeros+=slot->bytes[offset+j]==0;
            [details addObject:@{@"bytes":@(slot->lengths[b]),@"zero_bytes":@(zeros),@"channels":@(slot->channels[b])}];offset+=slot->lengths[b];
        }
        AVAudioPCMBuffer *pcm=[[AVAudioPCMBuffer alloc]initWithPCMFormat:format bufferListNoCopy:(AudioBufferList *)&list deallocator:nil];
        double sampleTime=slot->time.mSampleTime/asbd.mSampleRate;
        double pts=AudioConvertHostTimeToNanos(slot->time.mHostTime)/1e9;
        if(buffers && sampleTime < lastSample)resets++;
        lastSample=sampleTime;
        if(!(slot->time.mFlags & kAudioTimeStampSampleTimeValid) || !(slot->time.mFlags & kAudioTimeStampHostTimeValid)) failure=@"Missing audio timestamp";
        if(!pcm || ![file writeFromBuffer:pcm error:&error])failure=error.localizedDescription?:@"Invalid PCM buffer";
        if(buffers){double gap=pts-last;if(fabs(gap)>2/asbd.mSampleRate){gaps++;maxGap=MAX(maxGap,fabs(gap));}}else first=pts;
        last=pts+pcm.frameLength/asbd.mSampleRate;frames+=pcm.frameLength;buffers++;
        if(diagnostics){NSDictionary *row=@{@"pts":@(pts),@"device_sample_time":@(sampleTime),@"sample_frames":@(pcm.frameLength),@"buffers":details,@"channels":ECVChannelStats(pcm)};[diagnostics writeData:[NSJSONSerialization dataWithJSONObject:row options:0 error:NULL]];[diagnostics writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];}
        pcm=nil;atomic_store_explicit(&ring->read,r+1,memory_order_release);
    }}
    AudioDeviceDestroyIOProcID(device,proc); file=nil;
    if(requestedFrames)AudioObjectSetPropertyData(device,&frameAddress,0,NULL,sizeof(originalFrames),&originalFrames);
    NSDictionary *report=@{@"backend":@"coreaudio",@"buffer_frames":@(actualFrames),@"sample_clock_resets":@(resets),@"device":@(argv[1]),@"device_uid":uid?(__bridge NSString *)uid:@"",@"output":path,@"sample_rate":@(asbd.mSampleRate),@"channels":@(asbd.mChannelsPerFrame),@"format_flags":@(asbd.mFormatFlags),@"bits_per_channel":@(asbd.mBitsPerChannel),@"buffers":@(buffers),@"sample_frames":@(frames),@"sample_seconds":@(frames/asbd.mSampleRate),@"timeline_seconds":@(last-first),@"timestamp_gaps":@(gaps),@"max_gap_seconds":@(maxGap),@"queue_overruns":@(atomic_load(&ring->overflow)),@"invalid_buffers":@(atomic_load(&ring->invalid)),@"error":failure?:(id)[NSNull null]};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];fwrite(json.bytes,1,json.length,stdout);puts("");
    BOOL failed=failure||!frames||gaps||resets||atomic_load(&ring->overflow)||atomic_load(&ring->invalid);
    if(uid)CFRelease(uid);free(ring);return failed?1:0;
}}
