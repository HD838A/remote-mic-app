export type WebHaptic = "light" | "emphasized" | "release";

const patterns: Record<WebHaptic, number | number[]> = {
  light: 10,
  emphasized: [18, 18, 18],
  release: 8,
};

export function triggerHaptic(kind: WebHaptic): boolean {
  if (typeof navigator.vibrate !== "function") return false;
  return navigator.vibrate(patterns[kind]);
}
