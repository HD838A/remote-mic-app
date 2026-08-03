import { describe, expect, it } from "vitest";
import { StreamingResampler } from "./audio";

describe("StreamingResampler", () => {
  it("converts 48kHz input to 16kHz Int16 frames", () => {
    const frames: Int16Array[] = [];
    const resampler = new StreamingResampler(48_000, 16_000, 320, (frame) => frames.push(frame));
    const input = new Float32Array(48_000).fill(0.5);
    for (let offset = 0; offset < input.length; offset += 480) {
      resampler.append(input.slice(offset, offset + 480));
    }
    expect(frames.length).toBe(50);
    expect(frames[0]?.length).toBe(320);
    expect(frames[0]?.[0]).toBeCloseTo(16_384, -1);
  });
});
