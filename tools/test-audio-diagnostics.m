#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import "ECVAudioDiagnostics.h"
int main(void) { @autoreleasepool {
    for(NSNumber *interleaved in @[@YES,@NO]) {
        AVAudioFormat *format=[[AVAudioFormat alloc]initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:48000 channels:2 interleaved:interleaved.boolValue];
        AVAudioPCMBuffer *pcm=[[AVAudioPCMBuffer alloc]initWithPCMFormat:format frameCapacity:512];pcm.frameLength=512;
        AudioBufferList *list=pcm.mutableAudioBufferList;
        for(unsigned c=0;c<2;c++)for(unsigned i=0;i<512;i++) {
            unsigned b=interleaved.boolValue?0:c,index=interleaved.boolValue?i*2+c:i;
            ((float *)list->mBuffers[b].mData)[index]=c?.25f:0;
        }
        NSArray *stats=ECVChannelStats(pcm);
        NSCAssert([stats[0][@"zero_samples"] unsignedIntValue]==512,@"Channel 1 silence");
        NSCAssert([stats[1][@"zero_samples"] unsignedIntValue]==0,@"Channel 2 activity");
        NSCAssert([stats[1][@"held_samples"] unsignedIntValue]==511,@"Held samples");
        NSCAssert(fabs([stats[1][@"rms"] doubleValue]-.25)<1e-6,@"RMS");
    }
    puts("Interleaved and planar channel diagnostics passed");return 0;
}}
