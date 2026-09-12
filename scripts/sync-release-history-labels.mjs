import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";

const repository = process.env.GITHUB_REPOSITORY ?? "HD838A/remote-mic-app";
const files = [
  {
    path: "Resources/zh-Hans.lproj/ReleaseHistory.md",
    stable: "（正式版）",
    preview: "（预发布）",
  },
  {
    path: "Resources/en.lproj/ReleaseHistory.md",
    stable: " (Stable)",
    preview: " (Pre-release)",
  },
];

const releasePages = JSON.parse(execFileSync(
  "gh",
  [
    "api",
    `repos/${repository}/releases`,
    "--paginate",
    "--slurp",
    "-H",
    "X-GitHub-Api-Version: 2022-11-28",
  ],
  { encoding: "utf8", env: process.env },
));
const statusByVersion = new Map(
  releasePages
    .flat()
    .filter((release) => !release.draft)
    .map((release) => {
      const match = /^v?(\d+\.\d+\.\d+)$/.exec(release.tag_name ?? "");
      return match ? [match[1], release.prerelease ? "preview" : "stable"] : null;
    })
    .filter(Boolean),
);

const update = (text, labels) => text.replace(
  /^##[\t ]+(\d+\.\d+\.\d+)(?:[\t ]*(（正式版）|（预发布）|\(Stable\)|\(Pre-release\)))?[\t ]*$/gm,
  (_, version, existingLabel = "") => {
    const knownStatus = statusByVersion.get(version);
    const existingStatus = /预发布|Pre-release/.test(existingLabel) ? "preview" : "stable";
    const status = knownStatus ?? existingStatus;
    return `## ${version}${status === "preview" ? labels.preview : labels.stable}`;
  },
);

let changed = false;
for (const file of files) {
  const before = await readFile(file.path, "utf8");
  const after = update(before, file);
  if (before !== after) {
    await writeFile(file.path, after, "utf8");
    changed = true;
    console.log(`Updated ${file.path}`);
  }
}

if (!changed) console.log("Release history labels are already up to date");
