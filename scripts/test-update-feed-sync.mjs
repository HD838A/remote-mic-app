import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { syncUpdateFeeds } from "./sync-update-feeds.mjs";

function fixture({ mode = "sync", conclusion = "success", login = "HD838A", timeout = false } = {}) {
  const calls = [];
  let time = 0;
  let lists = 0;
  const previous = { databaseId: 10, displayTitle: `sync-mac-update-feeds ${mode} v2.0.0`, status: "completed", conclusion: "success" };
  const options = { tag: "v2.0.0", mode, timeoutMilliseconds: 30_000,
    now: () => time, pause: async ms => { time += ms; },
    gh: args => {
      calls.push(args);
      if (args[0] === "auth") return "";
      if (args[0] === "api") return login;
      if (args[0] === "workflow") return "";
      if (++lists === 1 || timeout) return JSON.stringify([previous]);
      return JSON.stringify([previous, { ...previous, databaseId: 11,
        status: lists < 4 ? "in_progress" : "completed", conclusion }]);
    },
  };
  return { calls, options };
}

test("sync dispatches only the controlled main workflow and waits for the new run", async () => {
  const { options, calls } = fixture();
  assert.deepEqual(await syncUpdateFeeds(options), { mode: "sync", result: "passed" });
  const dispatch = calls.find(args => args[0] === "workflow");
  assert.deepEqual(dispatch, ["workflow", "run", "sync-mac-update-feeds.yml", "--repo", "GetSayAll/sayall-private-platform", "--ref", "main",
    "--raw-field", "expected_tag=v2.0.0", "--raw-field", "mode=sync"]);
  assert.ok(calls.filter(args => args[0] === "run").length >= 4);
});

test("preflight uses the no-deployment mode before a release can be published", async () => {
  const { options, calls } = fixture({ mode: "preflight" });
  assert.deepEqual(await syncUpdateFeeds(options), { mode: "preflight", result: "passed" });
  assert.ok(calls.find(args => args.includes("mode=preflight")));
});

test("invalid tags and the wrong write identity stop before dispatch", async () => {
  const invalid = fixture();
  await assert.rejects(syncUpdateFeeds({ ...invalid.options, tag: "v2.0.0;command" }), /valid public release/);
  assert.equal(invalid.calls.length, 0);
  const wrong = fixture({ login: "other-account" });
  await assert.rejects(syncUpdateFeeds(wrong.options), /HD838A/);
  assert.equal(wrong.calls.filter(args => args[0] === "workflow").length, 0);
});

test("failed or missing new runs cannot masquerade as a successful old sync", async () => {
  await assert.rejects(syncUpdateFeeds(fixture({ conclusion: "failure" }).options), /did not succeed/);
  await assert.rejects(syncUpdateFeeds(fixture({ timeout: true }).options), /bounded wait/);
});

test("both official publication workflows gate mutation on preflight and wait for feed sync afterward", () => {
  for (const [workflow, mutation] of [["mac-preview-publication.yml", "./scripts/publish-preview-release.sh"],
    ["mac-stable-promote.yml", "./scripts/promote-preview-release.sh"]]) {
    const source = readFileSync(new URL("../.github/workflows/" + workflow, import.meta.url), "utf8");
    const before = source.indexOf("node scripts/sync-update-feeds.mjs --preflight");
    const publish = source.indexOf(mutation);
    const after = source.indexOf("node scripts/sync-update-feeds.mjs \"");
    assert.ok(before >= 0 && before < publish && after > publish);
    assert.equal((source.match(/GH_TOKEN: \$\{\{ secrets.SAYALL_FEED_SYNC_TOKEN \}\}/g) ?? []).length, 2);
    assert.ok([...source.matchAll(/secrets\.([A-Z0-9_]+)/g)].every(match => match[1] === "SAYALL_FEED_SYNC_TOKEN"));
  }
});
