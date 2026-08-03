import { describe, expect, it } from "vitest";
import { encodeAudioFrame, isAudioFrame, parseWireMessage, protocolVersion } from "./index.js";

describe("mobile web protocol", () => {
  it("accepts only whitelisted commands", () => {
    expect(parseWireMessage(JSON.stringify({ type: "command", protocolVersion, command: "home" }))).toMatchObject({ command: "home" });
    expect(parseWireMessage(JSON.stringify({ type: "command", protocolVersion, command: "shell" }))).toBeUndefined();
  });

  it("encodes bounded little-endian PCM frames", () => {
    const frame = encodeAudioFrame(7, new Int16Array([1, -2, 32767]));
    expect(isAudioFrame(frame)).toBe(true);
    const view = new DataView(frame);
    expect(view.getUint32(1, false)).toBe(7);
    expect(view.getInt16(5, true)).toBe(1);
    expect(view.getInt16(7, true)).toBe(-2);
  });
});
