// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from "vitest";
import { triggerHaptic } from "./haptics";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("triggerHaptic", () => {
  it("uses vibration when the browser supports it", () => {
    const vibrate = vi.fn(() => true);
    vi.stubGlobal("navigator", { vibrate });

    expect(triggerHaptic("emphasized")).toBe(true);
    expect(vibrate).toHaveBeenCalledWith([18, 18, 18]);
  });

  it("falls back without failing when vibration is unavailable", () => {
    vi.stubGlobal("navigator", {});

    expect(triggerHaptic("light")).toBe(false);
  });
});
