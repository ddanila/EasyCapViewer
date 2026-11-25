#import <AVFoundation/AVFoundation.h>
// Runs on the writer worker, never the Core Audio realtime callback.
static NSArray *ECVChannelStats(AVAudioPCMBuffer *pcm) {
    NSMutableArray *result=[NSMutableArray array];
    const AudioBufferList *list=pcm.audioBufferList;
    for(AVAudioChannelCount c=0;c<pcm.format.channelCount;c++) {
        NSUInteger zeros=0,held=0;double sum=0,previous=0;
        NSUInteger b=pcm.format.interleaved?0:c;
        NSUInteger stride=pcm.format.interleaved?pcm.format.channelCount:1;
        NSUInteger base=pcm.format.interleaved?c:0;
        const void *data=list->mBuffers[b].mData;
        for(AVAudioFrameCount i=0;i<pcm.frameLength;i++) {
            NSUInteger index=base+i*stride; double value=0;
            switch(pcm.format.commonFormat) {
                case AVAudioPCMFormatFloat32:value=((const float *)data)[index];break;
                case AVAudioPCMFormatFloat64:value=((const double *)data)[index];break;
                case AVAudioPCMFormatInt16:value=((const int16_t *)data)[index]/32768.0;break;
                case AVAudioPCMFormatInt32:value=((const int32_t *)data)[index]/2147483648.0;break;
                default:return @[];
            }
            zeros+=value==0;held+=(i && value==previous);sum+=value*value;previous=value;
        }
        [result addObject:@{@"channel":@(c+1),@"zero_samples":@(zeros),@"held_samples":@(held),@"frames":@(pcm.frameLength),@"rms":@(pcm.frameLength?sqrt(sum/pcm.frameLength):0)}];
    }
    return result;
}
