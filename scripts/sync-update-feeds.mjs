import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const repository = "GetSayAll/sayall-private-platform";
const workflow = "sync-mac-update-feeds.yml";
function github(args) {
  try {
    return execFileSync("gh", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 30_000 }).trim();
  } catch {
    // Do not copy private workflow logs, response bodies, or credentials to the public release log.
    throw new Error(`Feed synchronization GitHub command failed (${args[0]})`);
  }
}

export async function syncUpdateFeeds({ tag, mode = "sync", gh = github,
  now = () => performance.now(), pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds)),
  timeoutMilliseconds = 12 * 60_000 }) {
  if (!/^v\d+\.\d+\.\d+$/.test(tag ?? "") || !["preflight", "sync"].includes(mode)) {
    throw new Error("A valid public release tag and synchronization mode are required");
  }
  gh(["auth", "status", "--hostname", "github.com"]);
  if (gh(["api", "user", "--jq", ".login"]) !== "HD838A") throw new Error("Feed synchronization requires HD838A authorization");
  const list = ["run", "list", "--repo", repository, "--workflow", workflow, "--branch", "main",
    "--event", "workflow_dispatch", "--limit", "20", "--json", "databaseId,displayTitle,status,conclusion"];
  const previous = JSON.parse(gh(list));
  const lastID = Math.max(0, ...previous.map(run => run.databaseId));
  gh(["workflow", "run", workflow, "--repo", repository, "--ref", "main",
    "--raw-field", `expected_tag=${tag}`, "--raw-field", `mode=${mode}`]);
  const title = `sync-mac-update-feeds ${mode} ${tag}`;
  const deadline = now() + timeoutMilliseconds;
  while (now() < deadline) {
    const runs = JSON.parse(gh(list));
    const run = runs.filter(run => run.databaseId > lastID && run.displayTitle === title)
      .sort((a, b) => a.databaseId - b.databaseId)[0];
    if (run?.status === "completed") {
      if (run.conclusion !== "success") throw new Error(`Feed synchronization ${mode} did not succeed`);
      return { mode, result: "passed" };
    }
    await pause(10_000);
  }
  throw new Error(`Feed synchronization ${mode} exceeded its bounded wait; inspect the private workflow before retrying`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  const mode = args[0] === "--preflight" ? (args.shift(), "preflight") : "sync";
  if (args.length !== 1 || !process.env.GH_TOKEN) {
    console.error("Usage: GH_TOKEN=<scoped feed-sync credential> node scripts/sync-update-feeds.mjs [--preflight] <public-tag>");
    process.exitCode = 1;
  } else {
    try { console.log(JSON.stringify(await syncUpdateFeeds({ tag: args[0], mode }))); }
    catch (error) { console.error(error.message); process.exitCode = 1; }
  }
}
