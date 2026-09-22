import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const thinAssets = [
  ['darwin_arm64', 'peekaboo-macos-arm64.tar.gz'],
  ['darwin_amd64', 'peekaboo-macos-x86_64.tar.gz'],
];
const universalAsset = 'peekaboo-macos-universal.tar.gz';

export function selectHomebrewReleaseAssets(release, tag) {
  if (!tag || release?.tag_name !== tag || release.draft !== false || !Array.isArray(release.assets)) {
    throw new Error('Expected the published release inventory for the requested tag');
  }
  const byName = new Map();
  for (const name of [...thinAssets.map(([, name]) => name), universalAsset]) {
    const matches = release.assets.filter((asset) => asset.name === name);
    if (matches.length > 1) throw new Error(`Duplicate release asset: ${name}`);
    if (matches.length === 1) byName.set(name, matches[0]);
  }
  const present = thinAssets.filter(([, name]) => byName.has(name));
  if (present.length === 1) throw new Error('Both thin macOS CLI archives are required');
  if (present.length === 0) {
    // Older published releases contain only the universal CLI archive.
    if (byName.get(universalAsset)?.state !== 'uploaded') {
      throw new Error(`Missing uploaded release asset: ${universalAsset}`);
    }
    return { macos_artifact: universalAsset };
  }
  const assets = {};
  for (const [target, name] of thinAssets) {
    const asset = byName.get(name);
    if (asset.state !== 'uploaded' || !/^sha256:[0-9a-f]{64}$/.test(asset.digest ?? '')) {
      throw new Error(`Expected an uploaded asset with a SHA-256 digest: ${name}`);
    }
    assets[target] = { name, sha256: asset.digest.slice('sha256:'.length) };
  }
  return { assets: JSON.stringify(assets) };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const inputs = selectHomebrewReleaseAssets(JSON.parse(readFileSync(0, 'utf8')), process.argv[2]);
    for (const [key, value] of Object.entries(inputs)) console.log(`${key}=${value}`);
  } catch (error) {
    console.error(`Homebrew asset selection failed: ${error.message}`);
    process.exitCode = 1;
  }
}
