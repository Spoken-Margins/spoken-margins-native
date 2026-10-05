import { build } from "esbuild";
import path from "node:path";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { BUNDLES, LICENSE_DIRECTORIES, esbuildOptions } from "./bundleConfig.mjs";
import { NOTICES_FILE_NAME, bundledPackages, renderNotices, unaccountedDependencies } from "./licenseNotices.mjs";

const noticeBundles = [];

for (const configuration of BUNDLES) {
  const result = await build(esbuildOptions(configuration));
  const bundledSource = await readFile(configuration.outfile, "utf8");
  const cleanSource = bundledSource
    .split("\n")
    .map((line) => line.replace(/[ \t]+$/g, ""))
    .join("\n");
  await writeFile(configuration.outfile, cleanSource);
  noticeBundles.push({
    name: path.basename(configuration.outfile),
    packages: bundledPackages(result.metafile, configuration.outfile)
  });
}

const gaps = unaccountedDependencies([...new Set(noticeBundles.flatMap((bundle) => bundle.packages))]);
if (gaps.length) {
  throw new Error(
    `Shipped packages depend on packages with no notice: ${gaps.join("; ")}. ` +
    "Add each to PREBUNDLED_PACKAGES or NOT_SHIPPED in licenseNotices.mjs."
  );
}
const notices = renderNotices(noticeBundles);

for (const directory of LICENSE_DIRECTORIES) {
  await mkdir(directory, { recursive: true });
  await copyFile("node_modules/defuddle/LICENSE", `${directory}/Defuddle-LICENSE.txt`);
  await writeFile(`${directory}/${NOTICES_FILE_NAME}`, notices);
}
