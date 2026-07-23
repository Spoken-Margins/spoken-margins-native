import { build } from "esbuild";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";

const builds = [
  {
    entryPoints: ["Tools/BrowserExtraction/browserTextCapture.entry.mjs"],
    outfile: "App/SpokenMarginsBrowserTextExtension/Resources/Scripts/browserTextCapture.js"
  },
  {
    entryPoints: ["Tools/BrowserExtraction/sourceLinkPreprocessor.entry.mjs"],
    outfile: "App/SpokenMarginsShareExtension/Resources/SourceLinkPreprocessor.js"
  },
  {
    entryPoints: ["Tools/BrowserExtraction/popup.entry.mjs"],
    outfile: "App/SpokenMarginsBrowserTextExtension/Resources/Scripts/popup.js",
    banner: "/* Spoken Margins Safari capture transport */"
  }
];

for (const configuration of builds) {
  await build({
    ...configuration,
    bundle: true,
    format: "iife",
    platform: "browser",
    target: ["safari16"],
    minify: true,
    sourcemap: false,
    legalComments: "none",
    banner: { js: configuration.banner || "/* Bundled Defuddle 0.19.1; see Defuddle-LICENSE.txt */" }
  });
  const bundledSource = await readFile(configuration.outfile, "utf8");
  const cleanSource = bundledSource
    .split("\n")
    .map((line) => line.replace(/[ \t]+$/g, ""))
    .join("\n");
  await writeFile(configuration.outfile, cleanSource);
}

for (const directory of [
  "App/SpokenMarginsBrowserTextExtension/Resources",
  "App/SpokenMarginsShareExtension/Resources"
]) {
  await mkdir(directory, { recursive: true });
  await copyFile("node_modules/defuddle/LICENSE", `${directory}/Defuddle-LICENSE.txt`);
}
