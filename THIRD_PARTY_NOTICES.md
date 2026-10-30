# Third-party notices

Spoken Margins itself is licensed under the GNU Affero General Public License, version 3 only, with an App Store permission ([NOTICE](NOTICE)). The components below keep their own licences.

This file is generated from [docs/legal/third-party-components.json](docs/legal/third-party-components.json) by `scripts/third_party_notices.py`, which fails when a dependency, bundled model or bundled folder has no entry. Do not edit it by hand.

## Ships in the app

These are compiled into or packaged with the app, and some are also stored in this repository.

### ONNX Runtime, through onnxruntime-swift-package-manager 1.24.2

- Licence: MIT
- From: Microsoft Corporation
- Source: <https://github.com/microsoft/onnxruntime-swift-package-manager>
- Where: `Packages/SessionKit/Package.swift`
- Licence text: [ONNXRUNTIME_MIT.txt](App/SpokenMarginsApp/Resources/Supertonic/licenses/ONNXRUNTIME_MIT.txt), [ONNXRUNTIME_THIRD_PARTY_NOTICES.txt](App/SpokenMarginsApp/Resources/Supertonic/licenses/ONNXRUNTIME_THIRD_PARTY_NOTICES.txt), [onnxruntime-mit.txt](Contracts/voice-models/licenses/onnxruntime-mit.txt)

Runs the voice models on the phone. ONNX Runtime's own third-party components (MIT, BSD, Apache-2.0, zlib, Boost, ISC, public domain and MPL-2.0 for Eigen) are listed in the second file.

### ZIPFoundation 0.9.20

- Licence: MIT
- From: Thomas Zoechling
- Source: <https://github.com/weichsel/ZIPFoundation>
- Licence text: [ZIPFoundation-LICENSE.txt](App/SpokenMarginsApp/Resources/Legal/ZIPFoundation-LICENSE.txt)

Reads and writes .spokenmargins packets.

### Defuddle 0.19.5

- Licence: MIT
- From: Steph Ango
- Source: <https://github.com/kepano/defuddle>
- Where: `App/SharedResources/browserTextCapture.js`, `App/SharedResources/Defuddle-LICENSE.txt`, `App/SharedResources/BundledJavaScript-NOTICES.txt`, `App/SpokenMarginsShareExtension/Resources`
- Licence text: [Defuddle-LICENSE.txt](App/SharedResources/Defuddle-LICENSE.txt)

Reads web pages. Compiled into browserTextCapture.js and SourceLinkPreprocessor.js for the app, the Safari extension and the Share extension. The Share extension carries identical copies of the two notice files (checked).

### React 19.3.1

- Licence: MIT
- From: Meta Platforms, Inc. and affiliates
- Source: <https://github.com/facebook/react>
- Where: `Web`
- Licence text: <https://github.com/facebook/react/blob/main/LICENSE>

Ships in the web app (Web/), compiled by Vite into the JavaScript that the page serves to browsers. Not in the iOS app. Listed in Web/package.json; the web app tools entry claims that manifest.

### React DOM 19.3.1

- Licence: MIT
- From: Meta Platforms, Inc. and affiliates
- Source: <https://github.com/facebook/react>
- Where: `Web`
- Licence text: <https://github.com/facebook/react/blob/main/LICENSE>

Ships in the web app (Web/), compiled by Vite into the JavaScript that the page serves to browsers. Not in the iOS app. Listed in Web/package.json.

### scheduler 0.28.0

- Licence: MIT
- From: Meta Platforms, Inc. and affiliates
- Source: <https://github.com/facebook/react>
- Where: `Web`
- Licence text: <https://github.com/facebook/react/blob/main/LICENSE>

Ships in the web app (Web/), compiled by Vite into the JavaScript that the page serves to browsers. Not in the iOS app. React DOM depends on it (Web/package-lock.json); Web/package.json does not list it itself.

### turndown 7.2.4

- Licence: MIT
- From: Dom Christie
- Source: <https://github.com/mixmark-io/turndown>
- Licence text: [BundledJavaScript-NOTICES.txt](App/SharedResources/BundledJavaScript-NOTICES.txt)

Compiled into Defuddle's bundle.

### temml 0.13.3

- Licence: MIT
- From: Ron Kok
- Source: <https://github.com/ronkok/Temml>
- Licence text: [BundledJavaScript-NOTICES.txt](App/SharedResources/BundledJavaScript-NOTICES.txt)

Compiled into Defuddle's bundle.

### mathml-to-latex 1.8.0

- Licence: MIT
- From: Alexandre Nunes
- Source: <https://github.com/asnunes/mathml-to-latex>
- Licence text: [BundledJavaScript-NOTICES.txt](App/SharedResources/BundledJavaScript-NOTICES.txt)

Compiled into Defuddle's bundle.

### @xmldom/xmldom 0.9.12

- Licence: MIT
- From: Christopher J. Brody and contributors
- Source: <https://github.com/xmldom/xmldom>
- Licence text: [BundledJavaScript-NOTICES.txt](App/SharedResources/BundledJavaScript-NOTICES.txt)

Compiled into Defuddle's bundle.

### Kitten fallback voice (KittenTTS nano model and the Jasper voice style) 0.8 (fp32)

- Licence: Apache-2.0
- From: KittenML
- Source: <https://huggingface.co/KittenML/kitten-tts-nano-0.8-fp32>
- Where: `App/SpokenMarginsApp/Resources/Kitten`
- Licence text: [NOTICES.txt](App/SpokenMarginsApp/Resources/Kitten/NOTICES.txt), [apache-2-0.txt](Contracts/voice-models/licenses/apache-2-0.txt)

The voice that stays in the app. About 62 MB with the inputs below. The same folder holds the misaki 0.9.4 pronunciation lexicon (hexgrad, Apache-2.0), the g2p_en 2.1.0 letter-to-sound weights (Kyubyong Park and Jongseok Kim, Apache-2.0) and the CMU Pronouncing Dictionary (Carnegie Mellon University, BSD-style, CMUdict-LICENSE.txt). No GPL code or data; espeak-ng is not used.

### CMU Pronouncing Dictionary

- Licence: BSD-style (Carnegie Mellon University)
- From: Carnegie Mellon University
- Source: <http://www.speech.cs.cmu.edu/cgi-bin/cmudict>
- Licence text: [CMUdict-LICENSE.txt](App/SpokenMarginsApp/Resources/Kitten/CMUdict-LICENSE.txt), [cmudict.txt](Contracts/voice-models/licenses/cmudict.txt)

Part of the Kitten voice's pronunciations.

### Supertonic Swift inference code

- Licence: MIT
- From: Supertone Inc.
- Source: <https://github.com/supertone-inc/supertonic>
- Where: `Packages/SessionKit/Sources/SessionKitSupertonic/SupertonicRuntime.swift`
- Licence text: [SUPERTONIC_CODE_MIT.txt](App/SpokenMarginsApp/Resources/Supertonic/licenses/SUPERTONIC_CODE_MIT.txt), [supertonic-code-mit.txt](Contracts/voice-models/licenses/supertonic-code-mit.txt)

SupertonicRuntime.swift is adapted from Supertone's Swift example; its header says so.

### Gradium ptts (PhononTTS Swift package and its compiled PhononCore) 0.4.2

- Licence: MIT OR Apache-2.0 (used under Apache-2.0)
- From: Gradium
- Source: <https://github.com/gradium-ai/xn-ptts>
- Where: `project.yml`, `scripts/phonon-core-source-check.sh`
- Licence text: [xn-ptts-apache-2-0.txt](Contracts/voice-models/licenses/xn-ptts-apache-2-0.txt)

Runs the downloadable Phonon voice (#2704). Swift Package Manager fetches tag v0.4.2 (cc0c32bc), whose manifest pins Gradium's compiled PhononCore.xcframework.zip by SHA-256. The Rust core links about 150 crates on iOS, all MIT, Apache-2.0, BSD, ISC, Zlib, Unicode-3.0, Unlicense or BSL-1.0 (dual with Apache); none is GPL-family or MPL. scripts/phonon-core-source-check.sh builds the core from the tagged source and checks the release library links the same crates.

### kokoro-coreml (its KokoroPipeline Swift library) e8bf3d4e80d7dd30ed58e343c1527fad09cc9d1f

- Licence: Apache-2.0
- From: Matt Mireles
- Source: <https://github.com/mattmireles/kokoro-coreml>
- Where: `App/SpokenMarginsApp/Resources/Kokoro`
- Licence text: [Kokoro-NOTICES.txt](App/SpokenMarginsApp/Resources/Kokoro/Kokoro-NOTICES.txt), [apache-2-0.txt](Contracts/voice-models/licenses/apache-2-0.txt)

Runs the downloadable Kokoro voice's Core ML stages on the Neural Engine and CPU (#2705). Only the KokoroPipeline product is linked; the text front end reads misaki's gold and silver dictionaries first (hexgrad, Apache-2.0, downloaded with the voice) and falls back to the bundled Kitten voice's, respelled with misaki's espeak table.

## Downloaded, not distributed here

Fetched on request. They are not in this repository or in the app. Where the voice catalog (#1818) publishes the current address and licence text, it is the reference.

### Supertonic 3 model and preset voice styles (INT8)

- Licence: BigScience Open RAIL-M
- From: Supertone Inc.; INT8 conversion by the k2-fsa sherpa-onnx project
- Source: <https://huggingface.co/Supertone/supertonic-3>
- Where: `App/SpokenMarginsApp/Resources/Supertonic`, `Contracts/voice-models/licenses`
- Licence text: [SUPERTONIC_MODEL_OPENRAIL-M.txt](App/SpokenMarginsApp/Resources/Supertonic/licenses/SUPERTONIC_MODEL_OPENRAIL-M.txt), [SHERPA_ONNX_APACHE-2.0.txt](App/SpokenMarginsApp/Resources/Supertonic/licenses/SHERPA_ONNX_APACHE-2.0.txt), [THIRD_PARTY_NOTICES.txt](App/SpokenMarginsApp/Resources/Supertonic/licenses/THIRD_PARTY_NOTICES.txt), [supertonic-model-openrail-m.txt](Contracts/voice-models/licenses/supertonic-model-openrail-m.txt), [apache-2-0.txt](Contracts/voice-models/licenses/apache-2-0.txt)

Downloaded, not in the app or this repository since #1820: Settings › Voices fetches it from the voice catalog, each file pinned by sha256 in Contracts/voice-models/sources.json. The app keeps only the licence texts and the modification notice (App/SpokenMarginsApp/Resources/Supertonic) and the catalog's licence copies (Contracts/voice-models/licenses). The graphs are modified, quantized derivatives of Supertone's model; the sherpa-onnx conversion is Apache-2.0. The licence's use restrictions are part of the app's Terms of Use.

### Kyutai Pocket TTS voice

- Licence: CC-BY-4.0 (weights, ONNX export and the alba voice); MIT (Kyutai's code)
- From: Kyutai
- Source: <https://huggingface.co/kyutai/pocket-tts>
- Where: `Packages/SessionKit/Sources/SessionKitPocket`
- Licence text: [cc-by-4.0-pocket-tts.txt](Contracts/voice-models/licenses/cc-by-4.0-pocket-tts.txt), <https://huggingface.co/kyutai/pocket-tts>

Downloaded, not distributed here. No Pocket TTS model or voice file is in this repository or the app, and the app doesn't link its runtime yet. The repository holds only our own runtime code and a tokenizer test fixture. The research harness fetches the int8 ONNX export (KevinAHM/pocket-tts-onnx) and alba's voice state (kyutai/pocket-tts-without-voice-cloning), both CC BY 4.0, so the voice needs an attribution line where it is offered. The voice catalog (#1818) will carry the current download address and licence text. The MIT code licence is recorded in research/C2/README.md; the licence texts are on the model page. Details: research/C2/pocket/README.md.

### Phonon 31M (English) Core ML bundle and voices

- Licence: Apache-2.0; Mimi codec credited under CC-BY-4.0
- From: Gradium; Mimi codec by Kyutai
- Source: <https://github.com/gradium-ai/xn-ptts/releases/tag/v0.4.2>
- Where: `Contracts/voice-models/content/phonon-31m-en`
- Licence text: [xn-ptts-apache-2-0.txt](Contracts/voice-models/licenses/xn-ptts-apache-2-0.txt), [cc-by-4-0.txt](Contracts/voice-models/licenses/cc-by-4-0.txt), [NOTICE.txt](Contracts/voice-models/content/phonon-31m-en/licenses/NOTICE.txt)

Downloaded, not in the app or this repository: Settings › Voices takes 38 files from Gradium's phonon-31m-en-coreml.zip release asset, pinned by sha256 in Contracts/voice-models/sources.json. Exported from gradium/phonon-31m-en and gradium/phonon-voices (Apache-2.0). No 40M (CC BY-NC) file is used.

### Kokoro-82M voice (Core ML build) and its 28 English voices HF mattmireles/kokoro-coreml@0c1d78b47d19f39be6bc0cf0d07316822ae879d4

- Licence: Apache-2.0
- From: hexgrad (Core ML build by Matt Mireles)
- Source: <https://huggingface.co/mattmireles/kokoro-coreml>
- Licence text: [NOTICE.txt](Contracts/voice-models/content/kokoro-82m/licenses/NOTICE.txt), [apache-2-0.txt](Contracts/voice-models/licenses/apache-2-0.txt)

Downloaded from Settings › Voices, each file pinned by SHA-256 (about 402 MB). It includes misaki's us_gold.json and us_silver.json (hexgrad, Apache-2.0, github.com/hexgrad/misaki commit e820629b), pinned by hash. The NOTICE carries the Kokoro card's CC BY training-data credit (Koniwa tnc, CC BY 3.0; SIWIS, CC BY 4.0).

## Build, test and research tools

Used to build, test or research. None of them ships in the app.

### swift-crypto 3.15.1

- Licence: Apache-2.0
- From: Apple Inc. and the SwiftCrypto project authors
- Source: <https://github.com/apple/swift-crypto>
- Licence text: <https://github.com/apple/swift-crypto/blob/main/LICENSE.txt>

Replaces CryptoKit when SessionKit's tests build on Linux. Never part of the app. SwiftPM may also fetch swift-crypto's own dependencies there (for example swift-asn1, Apache-2.0); they are build-time only.

### esbuild 0.28.1

- Licence: MIT
- From: Evan Wallace
- Source: <https://github.com/evanw/esbuild>
- Where: `Tools/BrowserExtraction`
- Licence text: <https://github.com/evanw/esbuild/blob/main/LICENSE.md>

Builds the page-reading scripts. Not shipped.

### linkedom 0.18.13

- Licence: ISC
- From: Andrea Giammarchi
- Source: <https://github.com/WebReflection/linkedom>
- Where: `Tools/BrowserExtraction`
- Licence text: <https://github.com/WebReflection/linkedom/blob/main/LICENSE>

Stands in for a browser page in the page-reading tests. Not shipped.

### Web app build and test tools (npm)

- Licence: MIT (Vite, @vitejs/plugin-react, @types/node, @types/react, @types/react-dom); Apache-2.0 (TypeScript, Playwright)
- From: Their authors
- Where: `Web`

Web/package.json's devDependencies, installed by npm from Web/package-lock.json and never copied into this repository: Vite 8.3.5 (MIT, VoidZero Inc. and Vite contributors) and @vitejs/plugin-react 6.1.2 (MIT) build the page; TypeScript 5.9.3 (Apache-2.0, Microsoft) and the @types/node 24.19.2, @types/react 19.3.0 and @types/react-dom 19.3.0 type packages (MIT, DefinitelyTyped) check it; @playwright/test 1.64.1 (Apache-2.0, Microsoft) runs its journey tests. What the page itself ships is in the React, React DOM and scheduler entries.

### jsonschema (Python) 4.26.0

- Licence: MIT
- From: Julian Berman
- Source: <https://github.com/python-jsonschema/jsonschema>
- Where: `scripts`
- Licence text: <https://github.com/python-jsonschema/jsonschema/blob/main/COPYING>

Checks the repository's JSON contracts. Installed from requirements-dev.txt with its format-nongpl extra, which pulls in further small validator packages (for example idna, webcolors, jsonpointer, referencing); all are build-time only and none ships.

### PyYAML (Python) 6.0.2

- Licence: MIT
- From: Kirill Simonov and the PyYAML contributors
- Source: <https://github.com/yaml/pyyaml>
- Where: `scripts`
- Licence text: <https://github.com/yaml/pyyaml/blob/main/LICENSE>

Parses the workflow files in scripts/tests/test_workflow_files.py. Installed from requirements-dev.txt; build-time only and none ships.

### lxml (Python) 6.1.3

- Licence: BSD-3-Clause
- From: lxml developers
- Source: <https://github.com/lxml/lxml>
- Where: `research/C1/tools`
- Licence text: <https://github.com/lxml/lxml/blob/master/doc/licenses/BSD.txt>

Parses HTML in the research ground-truth tests (research/C1/tools). Installed from requirements-dev.txt so the hosted research step really runs them (#2596); build-time only and none ships.

### Design prototypes' npm packages

- Licence: Each package's own licence, installed by npm
- From: Their authors
- Where: `Design`

Design/UXProposal20260909 is a web prototype. Its packages are listed in its package.json and installed on request; none are copied into this repository or the app.

### Research harness dependencies (Python, Swift, Go)

- Licence: Each package's own licence, installed by the developer
- From: Their authors
- Where: `research`

The voice and PDF experiments under research/ install packages such as onnxruntime, pocket-tts, kokoro-onnx, piper-tts, pymupdf and pdfminer.six from public registries when run. Nothing is copied here and nothing ships in the app. The Go bridge server in research/B4/server has no outside module. If one is added, this entry must name it.

### MisakiSwift

- Licence: Apache-2.0
- From: Matt Mireles
- Source: <https://github.com/mattmireles/MisakiSwift>
- Licence text: <https://github.com/mattmireles/MisakiSwift>

Resolved by SwiftPM only because kokoro-coreml's manifest names it for its KokoroTTS product, which Spoken Margins does not link. Never built into or shipped with the app (#2705).

### MLX Swift

- Licence: MIT
- From: Apple Inc.
- Source: <https://github.com/ml-explore/mlx-swift>
- Licence text: <https://github.com/ml-explore/mlx-swift>

Resolved by SwiftPM only because kokoro-coreml's manifest names it for its KokoroTTS product, which Spoken Margins does not link. Never built into or shipped with the app (#2705).

### MLXUtilsLibrary

- Licence: Apache-2.0
- From: mlalma
- Source: <https://github.com/mlalma/MLXUtilsLibrary>
- Licence text: <https://github.com/mlalma/MLXUtilsLibrary>

Resolved by SwiftPM only because kokoro-coreml's manifest names it for its KokoroTTS product, which Spoken Margins does not link. Never built into or shipped with the app (#2705).

### Swift Numerics

- Licence: Apache-2.0
- From: Apple Inc.
- Source: <https://github.com/apple/swift-numerics>
- Licence text: <https://github.com/apple/swift-numerics>

Resolved by SwiftPM only because kokoro-coreml's manifest names it for its KokoroTTS product, which Spoken Margins does not link. Never built into or shipped with the app (#2705).

## Third-party content in the repository

Data and text captured from other people's work. This project does not license it; the rights stay with their owners.

### Starter podcast catalog and recorded feed heads

- Licence: Not licensed by this project: each publisher's rights apply
- From: Show names, descriptions and artwork belong to their publishers
- Source: <Each show's own podcast feed, listed in research/B1/shows.json>
- Where: `Site/onboarding/catalog`, `research/B1/recorded`

A hand-picked list of shows. Each show's title, author, description, website and artwork link are read from that show's own feed (#1732), and no artwork link points at Apple's servers. research/B1/recorded holds the feed heads (the text before the first episode) that research/B1/build_catalog.py read, so the list can be rebuilt offline.

### Test fixtures and traces saved from public feeds and pages

- Licence: Not licensed by this project: copyright stays with each publisher
- From: Podcast and website publishers
- Where: `Contracts/fixtures`, `Contracts/traces`, `fixtures`, `traces`, `App/TestFixtures`, `Packages/SessionKit/Tests/SessionKitTests/Fixtures`

Some of these are saved copies of feeds, pages, OPML and search responses, kept so tests can replay them; the rest are written for the tests. The saved copies keep feed metadata (show and post titles, authors, links) but no third-party article body: every article body, transcript and page body in them is placeholder text written for the tests, shaped like the original (#1994). Contracts/fixtures and Contracts/traces are also bundled in the app today for its test hooks. The public-source audit (#1383) prunes or confirms them.
