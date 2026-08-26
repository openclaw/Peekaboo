#!/usr/bin/env node

import assert from "node:assert/strict";
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

console.log("test-update-appcast-entry: ok");
