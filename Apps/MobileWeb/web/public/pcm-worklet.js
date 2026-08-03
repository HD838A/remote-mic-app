class RemoteMicPCMProcessor extends AudioWorkletProcessor {
  process(inputs) {
    const input = inputs[0]?.[0];
    if (input && input.length > 0) {
      this.port.postMessage(input.slice());
    }
    return true;
  }
}

registerProcessor("remote-mic-pcm", RemoteMicPCMProcessor);
