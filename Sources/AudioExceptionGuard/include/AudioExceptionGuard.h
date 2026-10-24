#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL RemoteMicTryPlayAudioPlayerNode(AVAudioPlayerNode *player);

FOUNDATION_EXPORT BOOL RemoteMicTryInstallInputTap(AVAudioInputNode *input, AVAudioFormat *format, AVAudioNodeTapBlock block);

NS_ASSUME_NONNULL_END
