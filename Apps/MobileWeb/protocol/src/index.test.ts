import { describe, expect, it } from "vitest";
import {
  buttonEventsCapability,
  encodeAudioFrame,
  isAudioFrame,
  parseWireMessage,
  protocolVersion,
  remoteCommands,
} from "./index.js";

describe("mobile web protocol", () => {
  it("accepts only whitelisted commands", () => {
    expect(parseWireMessage(JSON.stringify({ type: "command", protocolVersion, command: "home" }))).toMatchObject({ command: "home" });
    expect(parseWireMessage(JSON.stringify({ type: "command", protocolVersion, command: "shell" }))).toBeUndefined();
  });

  it("accepts button press and release events for every remote button", () => {
    for (const command of remoteCommands) {
      expect(parseWireMessage(JSON.stringify({
        type: "buttonEvent",
        protocolVersion,
        command,
        buttonPhase: "press",
      }))).toMatchObject({ command, buttonPhase: "press" });
      expect(parseWireMessage(JSON.stringify({
        type: "buttonEvent",
        protocolVersion,
        command,
        buttonPhase: "release",
      }))).toMatchObject({ command, buttonPhase: "release" });
    }
    expect(parseWireMessage(JSON.stringify({
      type: "buttonEvent",
      protocolVersion,
      command: "power",
      buttonPhase: "double",
    }))).toBeUndefined();
  });

  it("accepts the optional button event capability without changing protocol version", () => {
    expect(parseWireMessage(JSON.stringify({
      type: "sessionReady",
      protocolVersion,
      capabilities: [buttonEventsCapability],
    }))).toMatchObject({ capabilities: [buttonEventsCapability] });
    expect(parseWireMessage(JSON.stringify({
      type: "sessionReady",
      protocolVersion,
      capabilities: ["unknown"],
    }))).toBeUndefined();
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
