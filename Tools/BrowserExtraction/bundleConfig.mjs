export const BUNDLES = [
  {
    entryPoints: ["Tools/BrowserExtraction/browserTextCapture.entry.mjs"],
    outfile: "App/SharedResources/browserTextCapture.js"
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

// Resource folders that ship a bundle using Defuddle. The Safari extension
// takes its copy from App/SharedResources (see project.yml).
export const LICENSE_DIRECTORIES = [
  "App/SharedResources",
  "App/SpokenMarginsShareExtension/Resources"
];

export function esbuildOptions(configuration) {
  return {
    entryPoints: configuration.entryPoints,
    outfile: configuration.outfile,
    bundle: true,
    format: "iife",
    platform: "browser",
    target: ["safari16"],
    minify: true,
    sourcemap: false,
    legalComments: "none",
    metafile: true,
    banner: { js: configuration.banner || "/* Bundled Defuddle 0.19.5; see Defuddle-LICENSE.txt */" }
  };
}
