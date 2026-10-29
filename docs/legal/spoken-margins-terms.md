# Spoken Margins Terms architecture

Status: implemented for automated verification. Product-owner/legal review is
required before distribution.

## Contract layers

1. Apple's Standard EULA remains the App Store license. Spoken Margins does not
   install a custom EULA in App Store Connect.
2. Versioned Spoken Margins Terms of Use supplement the Standard EULA. The
   authoritative bundled copy for version 1.0 is
   `App/SpokenMarginsApp/Resources/Legal/SPOKEN_MARGINS_TERMS_OF_USE.txt`.
3. The public copy is published at
   `https://spokenmargins.proximitytoprogress.com/terms/`.
4. Complete third-party notices and licenses remain bundled in the app.
5. The Privacy Policy remains a separate document describing data practices.

## Supertonic gate

Supertonic 3 is distributed under the BigScience Open RAIL-M License. Paragraph
4(a) requires paragraph 5's use-based restrictions to appear as an enforceable
provision in a legal agreement governing use or distribution of the model.

Spoken Margins therefore:

- uses the iOS system voice until the current Terms version is accepted;
- presents the complete Terms when the user selects James or Lily in Settings;
- at a first Play, before the listener has chosen anything, presents one short screen instead: a summary, a link to
  the complete Terms, and the same two actions in view without scrolling (#2853);
- provides explicit Agree and Enable On-Device Voice and Not Now (shown as "Use iOS Voice") actions;
- stores the accepted Terms version and acceptance date locally;
- checks acceptance again at the Supertonic renderer boundary; and
- bundles the complete OpenRAIL-M license and third-party notices.

A future material revision increments `SpokenMarginsTerms.currentVersion` and
updates both the bundled and public Terms. Existing acceptance will then no
longer enable the affected feature until the new version is accepted.

## Release gate

Automated checks can verify storage, version expiry, UI routing, fallback, and
the renderer guard. Only the product owner records product-flow validation, and
legal review must confirm enforceability and license sufficiency before public
distribution.
