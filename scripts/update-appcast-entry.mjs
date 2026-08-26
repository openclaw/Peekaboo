#!/usr/bin/env node

import fs from "node:fs";
import { pathToFileURL } from "node:url";

const itemPattern = /^[ \t]*<item>[\s\S]*?^[ \t]*<\/item>[ \t]*(?:\r?\n)?/gm;

function containsVersion(item, version) {
  return item.includes(`sparkle:shortVersionString="${version}"`) ||
    item.includes(`<sparkle:shortVersionString>${version}</sparkle:shortVersionString>`);
}

function attribute(item, name) {
  return item.match(new RegExp(`${name}="([^"]+)"`))?.[1] ?? null;
}

function element(item, name) {
  return item.match(new RegExp(`<${name}>([^<]+)</${name}>`))?.[1] ?? null;
}

function itemVersion(item) {
  return attribute(item, 'sparkle:shortVersionString') ??
    item.match(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/)?.[1] ?? null;
}

function itemBuild(item) {
  const value = attribute(item, 'sparkle:version') ??
    item.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)?.[1] ?? null;
  return value !== null && /^[1-9][0-9]*$/.test(value) ? BigInt(value) : null;
}

function validateCandidate(existingItems, entry) {
  if (!/^[1-9][0-9]*$/.test(entry.buildNumber)) throw new Error('Appcast build number is invalid');
  const candidateBuild = BigInt(entry.buildNumber);
  for (const existing of existingItems) {
    const version = itemVersion(existing[0]);
    const build = itemBuild(existing[0]);
    if (build === null) continue;
    if (version === entry.version) {
      if (build !== candidateBuild) throw new Error('Appcast replacement changed the existing build number');
    } else if (build >= candidateBuild) {
      throw new Error('Appcast build number is not newer than every published version');
    }
  }
}

export function validateAppcast(xml, expected) {
  const items = [...xml.matchAll(itemPattern)].map((match) => match[0]);
  const versions = items.map(itemVersion);
  if (new Set(versions).size !== versions.length || versions.some((value) => value === null)) {
    throw new Error('Appcast versions are missing or duplicated');
  }
  const builds = items.map(itemBuild);
  if (builds.some((value) => value === null)) {
    throw new Error('Appcast build numbers are missing');
  }
  const modernBuilds = builds.filter((value) => value > 1n);
  const legacyIndex = builds.findIndex((value) => value <= 1n);
  if (legacyIndex >= 0 && builds.slice(legacyIndex).some((value) => value > 1n)) {
    throw new Error('Appcast modern build follows the legacy tail');
  }
  if (new Set(modernBuilds.map(String)).size !== modernBuilds.length) {
    throw new Error('Appcast modern build numbers are duplicated');
  }
  for (let index = 1; index < modernBuilds.length; index += 1) {
    if (modernBuilds[index - 1] <= modernBuilds[index]) {
      throw new Error('Appcast modern build numbers are not strictly descending');
    }
  }
  const current = items.filter((item) => itemVersion(item) === expected.version);
  if (current.length !== 1 || items[0] !== current[0]) throw new Error('Expected appcast version is not the first item');
  const item = current[0];
  const required = [
    [attribute(item, 'sparkle:version'), expected.buildNumber, 'build number'],
    [attribute(item, 'sparkle:minimumSystemVersion'), expected.minimumSystemVersion, 'minimum system version'],
    [attribute(item, 'url'), expected.assetUrl, 'asset URL'],
    [attribute(item, 'length'), expected.zipLength, 'asset length'],
    [attribute(item, 'sparkle:edSignature'), expected.edSignature, 'signature'],
    [element(item, 'link'), expected.releaseUrl, 'release link'],
    [element(item, 'sparkle:releaseNotesLink'), expected.releaseUrl, 'release notes link'],
  ];
  for (const [observed, value, label] of required) {
    if (observed !== String(value)) throw new Error(`Appcast ${label} differs from the release artifact`);
  }
}

export function updateAppcastEntry(xml, entry) {
  const existingItems = [...xml.matchAll(itemPattern)];
  validateCandidate(existingItems, entry);
  const firstIndent = existingItems[0]?.[0].match(/^([ \t]*)<item>/)?.[1] ?? "        ";
  const childIndent = `${firstIndent}    `;
  const item = `${firstIndent}<item>
${childIndent}<title>Peekaboo ${entry.version}</title>
${childIndent}<link>${entry.releaseUrl}</link>
${childIndent}<sparkle:releaseNotesLink>${entry.releaseUrl}</sparkle:releaseNotesLink>
${childIndent}<pubDate>${entry.pubDate}</pubDate>
${childIndent}<enclosure
${childIndent}  url="${entry.assetUrl}"
${childIndent}  sparkle:version="${entry.buildNumber}"
${childIndent}  sparkle:shortVersionString="${entry.version}"
${childIndent}  sparkle:minimumSystemVersion="${entry.minimumSystemVersion}"
${childIndent}  length="${entry.zipLength}"
${childIndent}  type="application/octet-stream"
${childIndent}  sparkle:edSignature="${entry.edSignature}" />
${firstIndent}</item>`;

  const withoutCurrentVersion = xml.replace(itemPattern, (existingItem) =>
    containsVersion(existingItem, entry.version) ? "" : existingItem);
  const nextFirstItem = withoutCurrentVersion.match(itemPattern)?.[0];

  let updated;
  if (nextFirstItem) {
    updated = withoutCurrentVersion.replace(nextFirstItem, `${item}\n${nextFirstItem}`);
  } else {
    const languagePattern = /(<language>en<\/language>[ \t]*\r?\n)/;
    if (!languagePattern.test(withoutCurrentVersion)) {
      throw new Error("Appcast channel is missing <language>en</language>");
    }
    updated = withoutCurrentVersion.replace(languagePattern, `$1${item}\n`);
  }
  validateAppcast(updated, entry);
  return updated;
}

function requiredEnvironment(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

if (process.argv[1] && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
  const appcastPath = requiredEnvironment("APPCAST_PATH");
  const xml = fs.readFileSync(appcastPath, "utf8");
  const updated = updateAppcastEntry(xml, {
    version: requiredEnvironment("VERSION"),
    releaseUrl: requiredEnvironment("RELEASE_URL"),
    assetUrl: requiredEnvironment("ASSET_URL"),
    buildNumber: requiredEnvironment("BUILD_NUMBER"),
    zipLength: requiredEnvironment("ZIP_LENGTH"),
    edSignature: requiredEnvironment("ED_SIGNATURE"),
    minimumSystemVersion: requiredEnvironment("MINIMUM_SYSTEM_VERSION"),
    pubDate: new Date().toUTCString().replace("GMT", "+0000"),
  });
  fs.writeFileSync(appcastPath, updated);
}
