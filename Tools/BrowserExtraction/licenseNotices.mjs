import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

export const NOTICES_FILE_NAME = "BundledJavaScript-NOTICES.txt";

// Defuddle ships `dist/index.full.js` already bundled by webpack, so esbuild's
// metafile sees one Defuddle input and none of the packages inlined into it.
// These are the packages that prebuilt file contains.
export const PREBUNDLED_PACKAGES = {
  defuddle: ["turndown", "temml", "mathml-to-latex", "@xmldom/xmldom"]
};

// The code inside defuddle's prebuilt file is whatever defuddle's own build
// installed, which the copy in node_modules/<name> need not match. The notices
// must not claim that copy's version, so a prebundled package is headed
// "inlined in defuddle X". Each one also has a marker string that exists only in
// fixed releases; the notices test requires it in the installed copy and in the
// shipped bundle, so a bump that fixes one and not the other fails.
export const PREBUNDLED_MARKERS = {
  "@xmldom/xmldom": { marker: "_nsIndex", reason: "0.9.12 attribute index; 0.9.10 has known advisories" }
};

// Dependencies of shipped packages that are not compiled into any bundle.
// A dependency that is neither shipped nor listed here fails the notices test,
// so a package upgrade that inlines something new can't ship without a notice.
export const NOT_SHIPPED = {
  commander: "Defuddle's command-line tool only",
  linkedom: "Defuddle's Node entry only; the bundles use the page's own DOM",
  "@mixmark-io/domino": "turndown's browser build maps it to false"
};

const LICENSE_FILE_PATTERN = /^(licen[cs]e|copying)(\.(md|txt))?$/i;

function packageNameFromInput(inputPath) {
  const marker = "node_modules/";
  const index = inputPath.lastIndexOf(marker);
  if (index < 0) {
    return null;
  }
  const parts = inputPath.slice(index + marker.length).split("/");
  return parts[0].startsWith("@") ? `${parts[0]}/${parts[1]}` : parts[0];
}

/** Packages compiled into one esbuild output, sorted by name. */
export function bundledPackages(metafile, outfile) {
  const output = metafile.outputs[outfile];
  if (!output) {
    throw new Error(`esbuild metafile has no output named ${outfile}`);
  }
  const names = new Set();
  for (const inputPath of Object.keys(output.inputs)) {
    const name = packageNameFromInput(inputPath);
    if (name) {
      names.add(name);
      for (const inlined of PREBUNDLED_PACKAGES[name] || []) {
        names.add(inlined);
      }
    }
  }
  return [...names].sort();
}

export function readPackage(name, root = "node_modules") {
  const directory = path.join(root, name);
  const manifest = JSON.parse(readFileSync(path.join(directory, "package.json"), "utf8"));
  const licenseFile = readdirSync(directory).filter((file) => LICENSE_FILE_PATTERN.test(file)).sort()[0];
  if (!licenseFile) {
    throw new Error(`${name} has no license file in ${directory}`);
  }
  return {
    name,
    version: manifest.version,
    license: manifest.license,
    dependencies: Object.keys({ ...manifest.dependencies, ...manifest.optionalDependencies }).sort(),
    licenseText: readFileSync(path.join(directory, licenseFile), "utf8").trim()
  };
}

/** Dependencies of shipped packages that are neither shipped nor known to be left out. */
export function unaccountedDependencies(packageNames, root = "node_modules") {
  const shipped = new Set(packageNames);
  const gaps = [];
  for (const name of packageNames) {
    for (const dependency of readPackage(name, root).dependencies) {
      if (!shipped.has(dependency) && !(dependency in NOT_SHIPPED)) {
        gaps.push(`${name} -> ${dependency}`);
      }
    }
  }
  return gaps;
}

function hostOf(name) {
  return Object.entries(PREBUNDLED_PACKAGES).find(([, inlined]) => inlined.includes(name))?.[0] || null;
}

function packageHeading(info, root = "node_modules") {
  const host = hostOf(info.name);
  if (host) {
    return `${info.name} (${info.license}), inlined in ${host} ${readPackage(host, root).version}`;
  }
  return `${info.name} ${info.version} (${info.license})`;
}

/**
 * Renders the notices for every bundle. `bundles` is a list of
 * `{ name, packages }`, where `name` is the shipped script's file name.
 */
export function renderNotices(bundles, root = "node_modules") {
  const rule = "=".repeat(72);
  const lines = [
    "Spoken Margins bundled JavaScript notices",
    "",
    "These open-source packages are compiled into the scripts Spoken Margins",
    "uses to read web pages. Each package's license follows.",
    ""
  ];
  for (const bundle of bundles) {
    const names = bundle.packages.length ? bundle.packages.join(", ") : "no third-party packages";
    lines.push(`${bundle.name}: ${names}`);
  }
  const allNames = [...new Set(bundles.flatMap((bundle) => bundle.packages))].sort();
  for (const name of allNames) {
    const info = readPackage(name, root);
    lines.push("", rule, packageHeading(info, root), rule, "", info.licenseText);
  }
  return `${lines.join("\n")}\n`;
}

/** Shipped packages whose heading or license text is missing from `noticesText`. */
export function missingNotices(noticesText, packageNames, root = "node_modules") {
  return packageNames.filter((name) => {
    const info = readPackage(name, root);
    return !noticesText.includes(packageHeading(info, root)) || !noticesText.includes(info.licenseText);
  });
}
