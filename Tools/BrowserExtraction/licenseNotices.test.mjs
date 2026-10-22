import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { build } from "esbuild";
import { BUNDLES, LICENSE_DIRECTORIES, esbuildOptions } from "./bundleConfig.mjs";
import {
  NOTICES_FILE_NAME,
  PREBUNDLED_MARKERS,
  PREBUNDLED_PACKAGES,
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

test("a prebundled package's notice names the host that inlined it, never the node_modules copy's version", async () => {
  const notices = renderNotices(await shippedBundles());
  const hostVersion = readPackage("defuddle").version;
  for (const [host, inlined] of Object.entries(PREBUNDLED_PACKAGES)) {
    for (const name of inlined) {
      const info = readPackage(name);
      assert.ok(
        notices.includes(`${name} (${info.license}), inlined in ${host} ${readPackage(host).version}`),
        `${name} must be headed as inlined in ${host}`
      );
      assert.ok(!notices.includes(`${name} ${info.version} (`), `${name} ${info.version} would claim a version the bundle may not contain`);
    }
  }
  assert.ok(fs.readFileSync(BUNDLES[0].outfile, "utf8").slice(0, 200).includes(`Bundled Defuddle ${hostVersion};`));
});

test("code inlined by defuddle carries the fix marker that the installed copy has", async () => {
  const shipped = await shippedBundles();
  const withDefuddle = BUNDLES.filter((configuration, index) => shipped[index].packages.includes("defuddle"));
  assert.ok(withDefuddle.length >= 2);
  for (const [name, { marker, reason }] of Object.entries(PREBUNDLED_MARKERS)) {
    const installed = fs.readdirSync(`node_modules/${name}/lib`).map((file) => fs.readFileSync(`node_modules/${name}/lib/${file}`, "utf8")).join("\n");
    assert.ok(installed.includes(marker), `installed ${name} lacks ${marker} (${reason})`);
    for (const configuration of withDefuddle) {
      assert.ok(fs.readFileSync(configuration.outfile, "utf8").includes(marker), `${configuration.outfile} still carries unfixed ${name} code (${reason})`);
    }
  }
});
