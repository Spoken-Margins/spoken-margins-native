# Library quality-of-life continuation

Implemented on the existing provisional-next lane, preserving the earlier uncommitted QoL bundle. Development version 0.1 (27), base commit de9dc82060a19c435d4045c30f957c04a4dbe871; this is not the distributed Build 27. No commit or distribution performed.

The Library defaults to Unfinished (unplayed plus in progress). On the first launch with this change, an absent or All listening preference becomes Unfinished; specific saved filters remain. Later choices persist. This is a preferences-only transition; no item or session migration occurs.

Completed items remain in the Library store and accessible through Show completed or the Listening filter. Searching while they are hidden displays Include in search, which expands the listening filter to All while keeping the query and other filters. The visible filter summary describes the scope; Reset filters retains the search and sort and restores Unfinished. The no-results action clears both search and filters. A Library containing only completed items shows You’re caught up.

Mark Complete offers a persistent, dismissible Undo Mark Complete banner. Undo removes only the explicit item mark if it still matches the saved action; it never modifies listening history, natural session completion, or Margins. The banner represents the latest manual completion and is cleared by a fixture reset. It is not a general Mark Unfinished action and does not survive relaunch.

## Owner check (pending)

Devices: iPhone and iPad, iOS 18+. Automated simulator checks use iOS 26.5. Only the owner can mark these flows human_validated.

Use an existing unfinished item with a Margin, or add a disposable text item titled Library QoL check. No Library reset is needed.

1. Launch and confirm Unfinished appears by default, or a previously selected specific filter remains. Choose All, relaunch, and confirm that choice persists.
2. Mark the disposable item complete. It should disappear from Unfinished. Tap Undo Mark Complete and confirm it returns with its prior progress and Margins.
3. Mark it complete again. Search for its title, then tap Include in search. Confirm it appears without clearing your query. Choose Show completed from an empty search and inspect its saved Margins.
4. Apply a content/offline filter; check the visible summary. Reset filters should restore Unfinished but keep search and sort. Reset search and filters in the empty state clears the query too.
5. In a disposable all-completed Library, check You’re caught up and Show completed. Check the banner and controls with larger text on your device.

Known limits: completion undo covers only the latest explicit mark in this process. Natural completion is preserved. The All-to-Unfinished transition cannot distinguish a previously intentional All selection from the old saved default; it runs only once. Search inclusion continues to respect content/offline filters, which remain visible in the summary.

Diagnostics: Settings → Developer tools → diagnostic export; include item and step. Cleanup: delete only the disposable source if desired. Verification identities/results are recorded in [verification.json](verification.json). Human checks remain pending.

## Verification result

Final source passed the fast plan, all 424 app tests, and generic simulator/device builds. The dedicated completion/undo/search route and compact-row test passed on both phone and iPad. Phone also passed the broader accessibility route with a 180-second execution allowance (the plan’s existing maximum). The iPad broader route exceeded 180 seconds later in Add Source, after its Library checks; that broader gate remains incomplete and was not retried again. This is not a release-wide or human validation claim.

Screenshots inspected: [phone](library-phone.png), [iPad](library-ipad.png). Undo sits in scrolling Library content, preserving toolbar access with the search keyboard open. Earlier test failures and interrupted obsolete runs are retained in verification.json; they are not counted as passes.

Weekly usage: 62% → 66% used, 34% remaining. These are rounded account-wide readings; no reset credit was consumed.

## Personal phone installation

At the owner’s request, the same verified source was built with Xcode for Slaw’s iPhone 17 Pro (iOS 26.6.2), installed over the existing app via local network, and launched successfully. No uninstall, Library reset, or test-fixture launch arguments were used. Version 0.1 (27) is this local development build; TestFlight distribution is unchanged. Exact executable/source identity and install/launch results are under `phone-install/`. Product validation remains pending.
