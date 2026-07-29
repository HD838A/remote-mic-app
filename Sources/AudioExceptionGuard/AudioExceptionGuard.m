#import "AudioExceptionGuard.h"

BOOL RemoteMicTryPlayAudioPlayerNode(AVAudioPlayerNode *player) {
    @try {
        [player play];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}
