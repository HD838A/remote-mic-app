#import "AudioExceptionGuard.h"

BOOL RemoteMicTryPlayAudioPlayerNode(AVAudioPlayerNode *player) {
    @try {
        [player play];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

BOOL RemoteMicTryInstallInputTap(AVAudioInputNode *input, AVAudioFormat *format, AVAudioNodeTapBlock block) {
    @try {
        [input installTapOnBus:0 bufferSize:512 format:format block:block];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}
