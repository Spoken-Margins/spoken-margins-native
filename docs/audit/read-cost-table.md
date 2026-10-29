# Read-cost table (#2513)

Written by `SESSIONKIT_READ_COST_TABLE=<file> swift test --filter testReadCostTableAtEveryScale` in `Packages/SessionKit` (Linux cloud box, median of 5 runs after a warm-up). It is the input of `scripts/rank_main_thread_reads.py`. Compare rows with each other, not with the phone. The table-seeding assumptions are in `Packages/SessionKit/Tests/SessionKitCoreTests/LibraryFixtureTables.swift`.

| read | small: ms | rows | bytes | library: ms | rows | bytes | 3x: ms | rows | bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `listItems()` | 8.59 | 32 | 2.3 MB | 53 | 319 | 16.6 MB | 161 | 957 | 49.7 MB |
| `listDeletedItems()` | 8.19 | 32 | 2.3 MB | 66 | 319 | 16.6 MB | 156 | 957 | 49.7 MB |
| `loadItem(article)` | 0.05 | 1 | 37.5 KB | 0.06 | 1 | 21.0 KB | 0.09 | 1 | 51.4 KB |
| `loadItem(mapped)` | 0.07 | 1 | 189 | 0.03 | 1 | 189 | 0.02 | 1 | 189 |
| `loadSessions()` | 0.66 | 36 | 10.5 KB | 7.04 | 361 | 105.6 KB | 20 | 1083 | 317.5 KB |
| `loadSessions(itemId: article)` | 0.03 | 1 | 289 | 0.03 | 1 | 291 | 0.06 | 1 | 291 |
| `loadSession(id:)` | 0.03 | 1 | 313 | 0.03 | 1 | 313 | 0.05 | 1 | 314 |
| `loadInterjections(itemId: mapped)` | 0.42 | 18 | 11.2 KB | 0.42 | 18 | 11.2 KB | 0.61 | 18 | 11.2 KB |
| `loadInterjections(sessionId:)` | 0.41 | 18 | 11.2 KB | 0.51 | 18 | 11.2 KB | 0.44 | 18 | 11.2 KB |
| `loadTurns(sessionId:)` | 0.03 | 1 | 755 | 0.02 | 1 | 755 | 0.03 | 1 | 755 |
| `loadListeningMap(mapped)` | 0.09 | 1 | 2.4 KB | 0.09 | 1 | 2.4 KB | 0.10 | 1 | 2.4 KB |
| `loadTranscriptTimeline(itemId: mapped)` | 11 | 2 | 497.6 KB | 12 | 2 | 497.6 KB | 11 | 2 | 497.6 KB |
| `loadTranscriptTimelineSummary(mapped)` | 0.24 | 1 | 37 | 0.27 | 1 | 37 | 0.26 | 1 | 37 |
| `transcriptTimelineStamp(mapped)` | 0.22 | 1 | 37 | 0.26 | 1 | 37 | 0.21 | 1 | 37 |
| `sourceTranscriptSizes()` | 0.01 | 2 | 0 | 0.02 | 2 | 0 | 0.01 | 2 | 0 |
| `loadAudioAssets(itemId: mapped)` | 0.18 | 15 | 4.7 KB | 0.25 | 15 | 4.7 KB | 0.26 | 15 | 4.7 KB |
| `loadCanonicalSource(article)` | 0.49 | 1 | 44.5 KB | 0.36 | 1 | 25.0 KB | 0.57 | 1 | 61.2 KB |
| `loadStructuredDocument(article)` | 0.60 | 1 | 45.3 KB | 0.43 | 1 | 26.3 KB | 0.76 | 1 | 61.3 KB |
| `loadStructuredDocumentItemIds()` | 0.01 | 5 | 33 | 0.03 | 49 | 379 | 0.06 | 147 | 1.2 KB |
| `loadResolvedListeningMapProjection(mapped)` | 1.04 | 1 | 26.7 KB | 1.33 | 1 | 26.7 KB | 1.13 | 1 | 26.7 KB |
| `loadPortableListeningMapProposals(mapped)` | 0.69 | 2 | 16.0 KB | 0.48 | 2 | 16.0 KB | 0.46 | 2 | 16.0 KB |
| `loadImportedCommentaryLayers()` | 0.06 | 1 | 287 | 0.15 | 6 | 1.7 KB | 0.34 | 19 | 5.5 KB |
| `loadSharedMarginTallies()` | 0.11 | 1 | 0 | 0.23 | 6 | 0 | 0.57 | 19 | 0 |
| `loadPodcastDownloads()` | 0.07 | 2 | 627 | 0.38 | 26 | 7.8 KB | 1.37 | 79 | 23.8 KB |
| `loadPreparedAudioManifests()` | 2.63 | 8 | 85.4 KB | 36 | 74 | 1.1 MB | 102 | 220 | 3.1 MB |
| `loadPreparedAudioManifestSummaries()` | 0.99 | 8 | 8.8 KB | 12 | 74 | 84.4 KB | 38 | 220 | 250.0 KB |
| `loadAudioPreparationJobs()` | 0.03 | 2 | 447 | 0.14 | 12 | 2.7 KB | 0.35 | 38 | 8.5 KB |
| `loadEpisodeMapPreparationJobs()` | 0.02 | 1 | 206 | 0.04 | 3 | 618 | 0.09 | 9 | 1.9 KB |
| `loadOwnedOfflineAssets()` | 0.14 | 9 | 3.4 KB | 1.41 | 91 | 34.3 KB | 3.78 | 272 | 102.5 KB |
| `loadOfflineStorageReservations()` | 0.03 | 2 | 270 | 0.04 | 2 | 270 | 0.03 | 2 | 270 |
| `loadItemCollections()` | 0.07 | 4 | 1.3 KB | 0.08 | 4 | 1.4 KB | 0.08 | 4 | 1.4 KB |
| `loadFeedSubscriptions()` | 0.05 | 3 | 609 | 0.29 | 26 | 5.3 KB | 0.90 | 78 | 16.1 KB |
| `loadFeedEntries(all)` | 1.06 | 41 | 399.1 KB | 18 | 407 | 3.8 MB | 41 | 1221 | 11.6 MB |
| `loadFeedEntries(one source)` | 1.02 | 41 | 399.1 KB | 19 | 407 | 3.8 MB | 47 | 1221 | 11.6 MB |
| `allMarginAudioPaths()` | 0.22 | 22 | 13.5 KB | 0.51 | 54 | 31.8 KB | 1.15 | 126 | 73.0 KB |
| `quarantinedRecordCount()` | 0.00 | 1 | 0 | 0.01 | 1 | 0 | 0.00 | 1 | 0 |
| `listItemSummaries()` | 6.79 | 32 | 20.4 KB | 40 | 319 | 201.1 KB | 99 | 957 | 603.4 KB |
| `listItemSummaries(includeDeleted)` | 7.12 | 32 | 20.4 KB | 39 | 319 | 201.1 KB | 102 | 957 | 603.4 KB |
| `itemRevision(article)` | 0.00 | 0 | 0 | 0.00 | 0 | 0 | 0.00 | 0 | 0 |
| `loadPodcastDownload(itemId: mapped)` | 0.04 | 1 | 364 | 0.04 | 1 | 364 | 0.05 | 1 | 364 |
| `loadPreparedAudioManifest(id:)` | 0.50 | 1 | 9.6 KB | 0.16 | 1 | 5.7 KB | 0.73 | 1 | 13.3 KB |
| `loadPreparedAudioManifests(itemId:)` | 0.40 | 1 | 9.6 KB | 0.17 | 1 | 5.7 KB | 0.73 | 1 | 13.3 KB |
| `loadOfflineStorageBudget()` | 0.01 | 1 | 25 | 0.02 | 1 | 25 | 0.03 | 1 | 25 |
| `loadAIJobs(sessionId:)` | 0.02 | 1 | 776 | 0.02 | 1 | 776 | 0.04 | 1 | 776 |
| `loadWatchAudioPackage(id:)` | 0.01 | 0 | 0 | 0.01 | 0 | 0 | 0.01 | 0 | 0 |
| `loadWatchAudioPackages(itemId:)` | 0.01 | 0 | 0 | 0.01 | 0 | 0 | 0.01 | 0 | 0 |
| `loadWatchSyncEvents(sessionId:)` | 0.01 | 0 | 0 | 0.01 | 0 | 0 | 0.01 | 0 | 0 |
| `loadWatchSyncEvent(id:)` | 0.01 | 0 | 0 | 0.01 | 0 | 0 | 0.01 | 0 | 0 |
| `loadWatchPackageRequests(itemId:)` | 0.01 | 0 | 0 | 0.01 | 0 | 0 | 0.01 | 0 | 0 |
| `loadTranscriptTimeline(id:)` | 9.79 | 1 | 497.6 KB | 11 | 1 | 497.6 KB | 9.30 | 1 | 497.6 KB |
| `loadTranscriptTimelineChapters(mapped)` | 0.23 | 1 | 37 | 0.27 | 1 | 37 | 0.21 | 1 | 37 |
| `resolveSourceAnchorContexts(mapped)` | 0.19 | 1 | 37 | 0.27 | 1 | 37 | 0.24 | 1 | 37 |
| `loadEditionFingerprintSpine(mapped)` | 0.35 | 1 | 11.1 KB | 0.37 | 1 | 11.1 KB | 0.36 | 1 | 11.1 KB |
| `loadTranscriptPhraseSketch(mapped)` | 2.67 | 1 | 81.1 KB | 2.58 | 1 | 81.2 KB | 4.09 | 1 | 81.1 KB |
| `loadFeedRefreshState(subscriptionId:)` | 0.02 | 1 | 129 | 0.02 | 1 | 129 | 0.05 | 1 | 129 |
| `loadSourceSuggestionDecision(sourceId:)` | 0.03 | 1 | 97 | 0.01 | 1 | 97 | 0.02 | 1 | 97 |
| `loadPublisherAudio(itemId:)` | 0.01 | 1 | 107 | 0.01 | 1 | 107 | 0.02 | 1 | 107 |
| `loadCommunityMapUpload(episodeKey:)` | 0.03 | 1 | 126 | 0.02 | 1 | 126 | 0.02 | 1 | 126 |
| `loadCommunityMapUploads()` | 0.02 | 1 | 126 | 0.04 | 2 | 252 | 0.04 | 2 | 252 |
| `loadInterjectionShareRevisions(interjectionId:)` | 0.08 | 4 | 1.8 KB | 0.08 | 6 | 2.7 KB | 0.09 | 6 | 2.7 KB |
| `loadImportedCommentaryLayer(id:)` | 0.04 | 1 | 287 | 0.03 | 1 | 288 | 0.02 | 1 | 288 |
| `loadImportedCommentaryLayer(packageDigest:)` | 0.03 | 1 | 287 | 0.10 | 6 | 1.7 KB | 0.29 | 19 | 5.5 KB |
| `loadImportedCommentaryLayers(itemId:)` | 0.03 | 1 | 287 | 0.03 | 1 | 288 | 0.03 | 1 | 288 |
| `loadImportedCommentaryInterjections(layerId:)` | 0.33 | 12 | 6.6 KB | 0.35 | 12 | 6.6 KB | 0.49 | 12 | 6.6 KB |
| `isLiveImportedCommentaryLayer(id:)` | 0.04 | 1 | 287 | 0.03 | 1 | 288 | 0.03 | 1 | 288 |
| `hasImportedWatchSyncEvent(id:)` | 0.01 | 0 | 0 | 0.01 | 0 | 0 | 0.01 | 0 | 0 |
| `importedCommentaryRecordsMention(_:)` | 0.03 | 0 | 0 | 0.10 | 0 | 0 | 0.36 | 0 | 0 |
| `marginNoteChanges(after:)` | 0.07 | 37 | 369 | 0.31 | 362 | 3.9 KB | 1.75 | 1084 | 11.9 KB |
| `quarantinedMarginAudioPaths(itemId:)` | 0.00 | 1 | 0 | 0.00 | 1 | 0 | 0.01 | 1 | 0 |
| `screen: LibraryReadSnapshot.read(store:)` | 11 | 86 | 117.4 KB | 84 | 847 | 1.4 MB | 218 | 2543 | 4.0 MB |
| `screen: refreshAudioPreparationPresentation` | 9.76 | 78 | 116.7 KB | 89 | 766 | 1.4 MB | 219 | 2298 | 4.0 MB |
| `screen: refreshMarginRows (MarginCollection.build)` | 11 | 104 | 2.3 MB | 69 | 813 | 16.8 MB | 235 | 2414 | 50.2 MB |
| `screen: ItemDetailLoader.load(article)` | 6.64 | 19 | 135.5 KB | 4.40 | 19 | 80.5 KB | 9.15 | 19 | 182.1 KB |
| `screen: ItemDetailLoader.load(mapped)` | 3.70 | 27 | 58.0 KB | 3.93 | 27 | 58.0 KB | 3.75 | 27 | 58.0 KB |

Scales: small = 32 items, 36 sessions, 3 sources, 41 entries, 2.3 MB article text; library = 319 items, 361 sessions, 26 sources, 407 entries, 16.6 MB article text; 3x = 957 items, 1083 sessions, 78 sources, 1221 entries, 49.5 MB article text
