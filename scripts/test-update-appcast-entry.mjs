#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { updateAppcastEntry, validateAppcast } from "./update-appcast-entry.mjs";

const original = `<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <language>en</language>
        <item>
            <title>3.9.4</title>
            <sparkle:shortVersionString>3.9.4</sparkle:shortVersionString>
            <enclosure url="https://example.invalid/3.9.4.zip" sparkle:version="3090499"
              sparkle:minimumSystemVersion="15.0" length="40" sparkle:edSignature="old-394" />
        </item>
        <item>
            <title>Peekaboo 3.9.2</title>
            <enclosure url="https://example.invalid/3.9.2.zip" sparkle:version="3090299"
              sparkle:shortVersionString="3.9.2" sparkle:minimumSystemVersion="15.0"
              length="20" sparkle:edSignature="old-392" />
        </item>
    </channel>
</rss>
`;

const entry = {
  version: "3.9.5",
  releaseUrl: "https://github.com/openclaw/Peekaboo/releases/tag/v3.9.5",
  assetUrl: "https://github.com/openclaw/Peekaboo/releases/download/v3.9.5/Peekaboo-3.9.5.app.zip",
  buildNumber: "3090599",
  zipLength: "17009920",
  edSignature: "test-signature",
  minimumSystemVersion: "15.0",
  pubDate: "Sat, 18 Jul 2026 20:00:00 +0000",
};

const updated = updateAppcastEntry(original, entry);
assert.equal(updated.match(/sparkle:shortVersionString="3\.9\.5"/g)?.length, 1);
assert.match(updated, /length="17009920"/);
assert.match(updated, /sparkle:edSignature="test-signature"/);
assert.match(updated, /<sparkle:shortVersionString>3\.9\.4<\/sparkle:shortVersionString>/);
assert.match(updated, /sparkle:shortVersionString="3\.9\.2"/);
assert.ok(updated.indexOf("3.9.5") < updated.indexOf("3.9.4"));
assert.doesNotThrow(() => validateAppcast(updated, entry));

const replaced = updateAppcastEntry(updated, {
  ...entry,
  zipLength: "17009921",
  edSignature: "replacement-signature",
});
assert.equal(replaced.match(/sparkle:shortVersionString="3\.9\.5"/g)?.length, 1);
assert.doesNotMatch(replaced, /length="17009920"/);
assert.match(replaced, /length="17009921"/);
assert.match(replaced, /sparkle:edSignature="replacement-signature"/);
assert.throws(() => updateAppcastEntry(original, { ...entry, buildNumber: "3090499" }), /not newer/);
assert.throws(() => updateAppcastEntry(updated, { ...entry, buildNumber: "3090598" }), /changed/);
assert.throws(() => validateAppcast(updated.replace('sparkle:version="3090299"',
  'sparkle:version="3090499"'), entry), /duplicated|descending/);
assert.throws(() => validateAppcast(updated.replace('sparkle:minimumSystemVersion="15.0"',
  'sparkle:minimumSystemVersion="14.0"'), entry), /minimum system version/);
assert.throws(() => validateAppcast(updated.replaceAll(entry.releaseUrl,
  'https://example.invalid/wrong-release'), entry), /release link|release notes link/);

// Validate with an XML consumer: query strings must survive RSS serialization.
const queryEntry = {
  ...entry,
  releaseUrl: `${entry.releaseUrl}?channel=stable&source=app`,
  assetUrl: `${entry.assetUrl}?channel=stable&source=app`,
};
const queryXml = updateAppcastEntry(original, queryEntry);
assert.match(queryXml, /channel=stable&amp;source=app/);
assert.doesNotThrow(() => validateAppcast(queryXml, queryEntry));
assertUrlRoundTrip(queryXml, queryEntry);
assert.equal(updateAppcastEntry(queryXml, queryEntry), queryXml);

const literalEntry = {
  ...entry,
  releaseUrl: `${entry.releaseUrl}?literal=$&$'$$&entity=&amp;&quote="notes"`,
  assetUrl: `${entry.assetUrl}?literal=$&$'$$&entity=&lt;&quote="asset"`,
};
const emptyFeed = original.replace(/^[ \t]*<item>[\s\S]*?^[ \t]*<\/item>[ \t]*\n/gm, "");
for (const source of [original, emptyFeed]) {
  const xml = updateAppcastEntry(source, literalEntry);
  assertUrlRoundTrip(xml, literalEntry);
  assert.doesNotThrow(() => validateAppcast(xml, literalEntry));
  assert.equal(updateAppcastEntry(xml, literalEntry), xml);
}

const directory = mkdtempSync(join(tmpdir(), "peekaboo-appcast-entry-"));
try {
  const path = join(directory, "appcast.xml");
  writeFileSync(path, original);
  const result = spawnSync(process.execPath, [fileURLToPath(new URL("./update-appcast-entry.mjs", import.meta.url))], {
    env: {
      PATH: process.env.PATH,
      APPCAST_PATH: path,
      VERSION: queryEntry.version,
      RELEASE_URL: queryEntry.releaseUrl,
      ASSET_URL: queryEntry.assetUrl,
      BUILD_NUMBER: queryEntry.buildNumber,
      ZIP_LENGTH: queryEntry.zipLength,
      ED_SIGNATURE: queryEntry.edSignature,
      MINIMUM_SYSTEM_VERSION: queryEntry.minimumSystemVersion,
    },
    encoding: "utf8",
    timeout: 5000,
  });
  assert.equal(result.status, 0, result.stderr);
  const xml = readFileSync(path, "utf8");
  assertUrlRoundTrip(xml, queryEntry);
  assert.doesNotThrow(() => validateAppcast(xml, queryEntry));
} finally {
  rmSync(directory, { recursive: true, force: true });
}

console.log("test-update-appcast-entry: ok");

function assertUrlRoundTrip(xml, expected) {
  const parsed = spawnSync("python3", ["-c", `
import sys, xml.etree.ElementTree as ET
item = ET.fromstring(sys.stdin.read()).find('channel/item')
assert item.find('link').text == sys.argv[1]
assert item.find('enclosure').attrib['url'] == sys.argv[2]
`, expected.releaseUrl, expected.assetUrl], { input: xml, encoding: "utf8", timeout: 5000 });
  assert.equal(parsed.status, 0, parsed.stderr);
}
