// @vitest-environment jsdom
import { afterEach, expect, it, vi } from "vitest";
import { isUbuntuDesktop } from "./ubuntu-messages";
import { t } from "./i18n";
import { isRecommendedVoiceEndpoint, openVbCableDownloadPage } from "./bridge";
import { invoke } from "@tauri-apps/api/core";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

it("routes the packaged Ubuntu audio setup to its PipeWire source and Sound settings", async () => {
  vi.stubGlobal("__TAURI_INTERNALS__", {});
  vi.spyOn(window.navigator, "platform", "get").mockReturnValue("Linux x86_64");
  expect(isUbuntuDesktop()).toBe(true);
  expect(isRecommendedVoiceEndpoint({id:"sayall.rc003.mic", name:"SayAll RC003", isVirtualCableCandidate:true})).toBe(true);
  expect(t("需要安装 VB-CABLE")).toMatch(/麦克风|microphone/);
  await openVbCableDownloadPage();
  expect(invoke).toHaveBeenCalledWith("open_windows_settings", { section: "sound" });
});
