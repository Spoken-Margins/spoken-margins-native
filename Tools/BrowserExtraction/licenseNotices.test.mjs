import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { build } from "esbuild";
import { BUNDLES, LICENSE_DIRECTORIES, esbuildOptions } from "./bundleConfig.mjs";
import {
  NOTICES_FILE_NAME,
  bundledPackages,
  missingNotices,
  readPackage,
  renderNotices,
  unaccountedDependencies
} from "./licenseNotices.mjs";

async function shippedBundles() {
  const bundles = [];
  for (const configuration of BUNDLES) {
    const result = await build({ ...esbuildOptions(configuration), write: false });
    bundles.push({
      name: path.basename(configuration.outfile),
      packages: bundledPackages(result.metafile, configuration.outfile)
    });
  }
  return bundles;
}

test("every package compiled into a shipped script has its license in each bundled notices file", async () => {
  const bundles = await shippedBundles();
  const shipped = [...new Set(bundles.flatMap((bundle) => bundle.packages))].sort();
  // Defuddle's prebuilt bundle inlines these; the metafile alone can't see them.
  assert.deepEqual(shipped, ["@xmldom/xmldom", "defuddle", "mathml-to-latex", "temml", "turndown"]);
  for (const directory of LICENSE_DIRECTORIES) {
    const notices = fs.readFileSync(`${directory}/${NOTICES_FILE_NAME}`, "utf8");
    assert.deepEqual(missingNotices(notices, shipped), [], `${directory}/${NOTICES_FILE_NAME}`);
    assert.equal(notices, renderNotices(bundles), `${directory}/${NOTICES_FILE_NAME} is stale; run npm run build:browser-extraction`);
  }
});

test("every dependency of a shipped package is either shipped with a notice or known to be left out", async () => {
  const bundles = await shippedBundles();
  const shipped = [...new Set(bundles.flatMap((bundle) => bundle.packages))];
  assert.deepEqual(unaccountedDependencies(shipped), []);
});

test("the notices check reports a shipped package whose license section is missing", async () => {
  const bundles = await shippedBundles();
  const notices = renderNotices(bundles);
  const temml = readPackage("temml");
  const withoutTemml = notices.replace(temml.licenseText, "");
  assert.deepEqual(missingNotices(withoutTemml, ["defuddle", "temml"]), ["temml"]);
});

test("a dependency nobody accounted for, or a package with no license file, fails", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "notices-"));
  const writePackage = (name, manifest, license) => {
    fs.mkdirSync(path.join(root, name), { recursive: true });
    fs.writeFileSync(path.join(root, name, "package.json"), JSON.stringify({ name, version: "1.0.0", license: "MIT", ...manifest }));
    if (license) {
      fs.writeFileSync(path.join(root, name, "LICENSE"), license);
    }
  };
  writePackage("host", { optionalDependencies: { inlined: "1", commander: "1" } }, "host license");
  writePackage("inlined", {}, null);
  assert.deepEqual(unaccountedDependencies(["host"], root), ["host -> inlined"]);
  assert.throws(() => readPackage("inlined", root), /no license file/);
});
