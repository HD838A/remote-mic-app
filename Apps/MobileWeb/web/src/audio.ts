const targetSampleRate = 16_000;
const frameSampleCount = 320;

export class MicrophoneCapture {
  private stream: MediaStream | undefined;
  private context: AudioContext | undefined;
  private source: MediaStreamAudioSourceNode | undefined;
  private processor: AudioWorkletNode | undefined;
  private silentGain: GainNode | undefined;
  private resampler: StreamingResampler | undefined;

  async start(onFrame: (samples: Int16Array) => void): Promise<void> {
    if (this.stream) return;
    if (!navigator.mediaDevices?.getUserMedia) {
      throw new Error("当前浏览器不支持麦克风采集");
    }

    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
      video: false,
    });

    try {
      const context = new AudioContext({ latencyHint: "interactive" });
      await context.audioWorklet.addModule("/pcm-worklet.js");
      await context.resume();
      const source = context.createMediaStreamSource(stream);
      const processor = new AudioWorkletNode(context, "remote-mic-pcm", {
        numberOfInputs: 1,
        numberOfOutputs: 1,
        outputChannelCount: [1],
      });
      const silentGain = context.createGain();
      silentGain.gain.value = 0;
      const resampler = new StreamingResampler(context.sampleRate, targetSampleRate, frameSampleCount, onFrame);
      processor.port.onmessage = (event: MessageEvent<Float32Array>) => {
        resampler.append(event.data);
      };
      source.connect(processor);
      processor.connect(silentGain);
      silentGain.connect(context.destination);

      this.stream = stream;
      this.context = context;
      this.source = source;
      this.processor = processor;
      this.silentGain = silentGain;
      this.resampler = resampler;
    } catch (error) {
      stream.getTracks().forEach((track) => track.stop());
      throw error;
    }
  }

  async stop(): Promise<void> {
    const context = this.context;
    this.processor?.port.close();
    this.source?.disconnect();
    this.processor?.disconnect();
    this.silentGain?.disconnect();
    this.stream?.getTracks().forEach((track) => track.stop());
    this.stream = undefined;
    this.context = undefined;
    this.source = undefined;
    this.processor = undefined;
    this.silentGain = undefined;
    this.resampler = undefined;
    if (context && context.state !== "closed") {
      await context.close();
    }
  }
}

export class StreamingResampler {
  private sourceSamples: number[] = [];
  private sourcePosition = 0;
  private outputSamples: number[] = [];
  private readonly sourceStep: number;

  constructor(
    sourceSampleRate: number,
    targetSampleRate: number,
    private readonly frameSize: number,
    private readonly onFrame: (samples: Int16Array) => void,
  ) {
    this.sourceStep = sourceSampleRate / targetSampleRate;
  }

  append(chunk: Float32Array): void {
    for (const sample of chunk) this.sourceSamples.push(sample);
    while (this.sourcePosition + 1 < this.sourceSamples.length) {
      const lowerIndex = Math.floor(this.sourcePosition);
      const fraction = this.sourcePosition - lowerIndex;
      const lower = this.sourceSamples[lowerIndex] ?? 0;
      const upper = this.sourceSamples[lowerIndex + 1] ?? lower;
      this.outputSamples.push(lower + (upper - lower) * fraction);
      this.sourcePosition += this.sourceStep;
      if (this.outputSamples.length >= this.frameSize) this.publishFrame();
    }

    const consumed = Math.max(0, Math.floor(this.sourcePosition) - 1);
    if (consumed > 0) {
      this.sourceSamples.splice(0, consumed);
      this.sourcePosition -= consumed;
    }
  }

  private publishFrame(): void {
    const frame = this.outputSamples.splice(0, this.frameSize);
    const samples = new Int16Array(this.frameSize);
    for (let index = 0; index < samples.length; index += 1) {
      const value = Math.max(-1, Math.min(1, frame[index] ?? 0));
      samples[index] = value < 0 ? Math.round(value * 32_768) : Math.round(value * 32_767);
    }
    this.onFrame(samples);
  }
}
