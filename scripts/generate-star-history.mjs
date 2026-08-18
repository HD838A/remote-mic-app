#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

const repository = process.env.GITHUB_REPOSITORY ?? "HD838A/remote-mic-app";
const outputPath = path.resolve(process.argv[2] ?? "Screenshots/star-history.svg");
const apiVersion = "2022-11-28";

async function fetchWithToken(token) {
  const stars = [];
  for (let page = 1; ; page += 1) {
    const response = await fetch(`https://api.github.com/repos/${repository}/stargazers?per_page=100&page=${page}`, {
      headers: {
        Accept: "application/vnd.github.star+json",
        Authorization: `Bearer ${token}`,
        "X-GitHub-Api-Version": apiVersion,
        "User-Agent": "sayall-star-history",
      },
    });
    if (!response.ok) throw new Error(`GitHub API 请求失败：${response.status} ${response.statusText}`);
    const pageStars = await response.json();
    stars.push(...pageStars);
    if (pageStars.length < 100) return stars;
  }
}

function fetchWithGitHubCli() {
  const output = execFileSync("gh", [
    "api",
    "--paginate",
    "--slurp",
    "-H", "Accept: application/vnd.github.star+json",
    "-H", `X-GitHub-Api-Version: ${apiVersion}`,
    `repos/${repository}/stargazers?per_page=100`,
  ], { encoding: "utf8" });
  return JSON.parse(output).flat();
}

function xml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function shortDate(timestamp) {
  return new Date(timestamp).toISOString().slice(0, 10);
}

function render(stars) {
  const events = stars
    .map((star) => Date.parse(star.starred_at))
    .filter(Number.isFinite)
    .sort((left, right) => left - right);
  const width = 1200;
  const height = 620;
  const plot = { left: 96, right: 48, top: 138, bottom: 82 };
  const plotWidth = width - plot.left - plot.right;
  const plotHeight = height - plot.top - plot.bottom;
  const oneDay = 24 * 60 * 60 * 1000;
  const firstEvent = events[0] ?? Date.UTC(2026, 0, 1);
  const lastEvent = events.at(-1) ?? firstEvent + oneDay;
  const xMin = events.length === 1 ? firstEvent - oneDay : firstEvent;
  const xMax = events.length === 1 ? lastEvent + oneDay : Math.max(lastEvent, xMin + oneDay);
  const yMax = Math.max(5, Math.ceil(events.length / 5) * 5);
  const x = (time) => plot.left + ((time - xMin) / (xMax - xMin)) * plotWidth;
  const y = (count) => plot.top + plotHeight - (count / yMax) * plotHeight;

  const pathParts = [`M ${x(xMin).toFixed(2)} ${y(0).toFixed(2)}`];
  events.forEach((time, index) => {
    pathParts.push(`H ${x(time).toFixed(2)} V ${y(index + 1).toFixed(2)}`);
  });
  pathParts.push(`H ${x(xMax).toFixed(2)}`);

  const horizontalGrid = Array.from({ length: 6 }, (_, index) => {
    const count = Math.round((yMax * index) / 5);
    const position = y(count);
    return `<line x1="${plot.left}" y1="${position}" x2="${width - plot.right}" y2="${position}" class="grid"/><text x="${plot.left - 18}" y="${position + 6}" class="axis" text-anchor="end">${count}</text>`;
  }).join("");
  const dateTicks = Array.from({ length: 6 }, (_, index) => {
    const time = xMin + ((xMax - xMin) * index) / 5;
    const position = x(time);
    return `<line x1="${position}" y1="${plot.top}" x2="${position}" y2="${plot.top + plotHeight}" class="grid vertical"/><text x="${position}" y="${height - 42}" class="axis" text-anchor="middle">${shortDate(time)}</text>`;
  }).join("");
  const lastDate = events.length > 0 ? shortDate(lastEvent) : "No stars yet";

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-labelledby="title description">
  <title id="title">${xml(repository)} GitHub Star History</title>
  <desc id="description">${events.length} GitHub stars through ${xml(lastDate)}</desc>
  <defs>
    <linearGradient id="area" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#16a34a" stop-opacity="0.30"/>
      <stop offset="100%" stop-color="#16a34a" stop-opacity="0.03"/>
    </linearGradient>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="120%">
      <feDropShadow dx="0" dy="8" stdDeviation="12" flood-color="#0f172a" flood-opacity="0.08"/>
    </filter>
  </defs>
  <style>
    .title { font: 700 34px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #0f172a; }
    .subtitle { font: 500 18px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #64748b; }
    .count { font: 700 28px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #16a34a; }
    .axis { font: 500 14px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #64748b; }
    .grid { stroke: #e2e8f0; stroke-width: 1; }
    .vertical { stroke-dasharray: 4 8; }
  </style>
  <rect width="${width}" height="${height}" rx="28" fill="#ffffff"/>
  <rect x="28" y="28" width="${width - 56}" height="${height - 56}" rx="22" fill="#ffffff" stroke="#e2e8f0" filter="url(#shadow)"/>
  <text x="${plot.left}" y="72" class="title">GitHub Star History</text>
  <text x="${plot.left}" y="104" class="subtitle">${xml(repository)}</text>
  <text x="${width - plot.right}" y="78" class="count" text-anchor="end">★ ${events.length}</text>
  ${horizontalGrid}
  ${dateTicks}
  <path d="${pathParts.join(" ")} L ${x(xMax).toFixed(2)} ${y(0).toFixed(2)} Z" fill="url(#area)"/>
  <path d="${pathParts.join(" ")}" fill="none" stroke="#16a34a" stroke-width="5" stroke-linejoin="round"/>
  <circle cx="${x(xMax).toFixed(2)}" cy="${y(events.length).toFixed(2)}" r="7" fill="#16a34a" stroke="#ffffff" stroke-width="4"/>
  <text x="${width - plot.right}" y="${height - 18}" class="axis" text-anchor="end">Data through ${xml(lastDate)}</text>
</svg>
`;
}

const stars = process.env.GITHUB_TOKEN
  ? await fetchWithToken(process.env.GITHUB_TOKEN)
  : fetchWithGitHubCli();
if (stars.some((star) => typeof star.starred_at !== "string")) {
  throw new Error("GitHub API 未返回带时间的 Star 数据");
}
await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, render(stars), "utf8");
console.log(`已生成 ${repository} 的 ${stars.length} 条 Star 历史：${outputPath}`);
