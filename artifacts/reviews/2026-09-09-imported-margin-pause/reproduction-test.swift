import AVFoundation
    func testImportedMarginPauseReproduction() async throws {
        SpokenMarginsTerms.recordAcceptance()
        let audio = FileManager.default.temporaryDirectory.appending(path: "margin-repro.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 720_000))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { channel[i] = sin(Float(i) * 0.03) * 0.02 }
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: buffer)
        }
        defer { try? FileManager.default.removeItem(at: audio) }
        let liveActivity = RecordingLiveActivityController()
        let controller = Gate2CompactControlController(liveActivity: liveActivity)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            gate2CompactControls: controller
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let layer = ImportedCommentaryLayer(
            id: "layer-received",
            itemId: "item-pill",
            packageDigest: "digest-received",
            packageId: "package-received",
            itemIdentity: SharedItemIdentity(itemType: .text, title: "You Can't Inspect the Pill"),
            displayLabel: "Cole",
            importedAt: Date(timeIntervalSince1970: 42),
            sourceResolutionStatus: .resolved,
            isEnabled: true,
            isMuted: true,
            revealMode: .companion
        )
        let record = ImportedCommentaryInterjection(
            id: "received-margin-7",
            layerId: layer.id,
            packageScopedId: "margin-7",
            createdAt: Date(timeIntervalSince1970: 43),
            anchorEvidence: PortableAnchorEvidence(anchorType: .text, startChar: 120, endChar: 140),
            approvedTranscript: "Remember this part.",
            audioPath: audio.path,
            audioDurationMs: 30_000,
            resolution: ImportedAnchorResolution(
                evidenceClass: .articleTextVerified,
                localStartChar: 120,
                localEndChar: 140,
                confidence: 1
            )
        )
        model.selectedItem.importedCommentaryLayers = [layer]
        model.selectedItem.importedCommentaryInterjections = [layer.id: [record]]

        XCTAssertTrue(
            model.handleGate2CompactApplicationCommand(
                Gate2CompactApplicationCommand.jumpToSharedMargin,
                targetID: record.id
            )
        )

        XCTAssertEqual(model.pendingImportedCommentary?.id, record.id)
        XCTAssertEqual(model.pendingImportedCommentary?.senderLabel, "Cole")
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(liveActivity.lastSharedMarginPrompt?.senderLabel, "Cole")
        XCTAssertEqual(model.diagnostics["lastSharedMarginNavigation"], "opened:received-margin-7")
        model.listenToPendingImportedCommentary()
        let player = try XCTUnwrap(Mirror(reflecting: model).children.first(where: { $0.label == "interjectionAudioPlayer" })?.value as? AVPlayer)
        for _ in 0..<150 where player.currentTime().seconds < 0.2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(player.currentTime().seconds, 0.1)
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.playingImportedCommentary?.id, record.id)
        print("REPRO before toggle: source=\(model.snapshot.status), marginTime=\(player.currentTime().seconds), marginRate=\(player.rate)")
        model.playPause()
        XCTAssertEqual(model.snapshot.status, .playing, "Bug: main toggle resumes source while Margin owns audio")
        XCTAssertEqual(model.playingImportedCommentary?.id, record.id, "Margin card remains visible with Return to Source")
        print("REPRO after toggle: source=\(model.snapshot.status), marginRate=\(player.rate), card=\(model.playingImportedCommentary != nil)")
        model.pause()
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertGreaterThan(player.rate, 0, "Explicit pause does not pause Margin player")
        XCTAssertEqual(model.playingImportedCommentary?.id, record.id)
        print("REPRO after explicit pause: source=\(model.snapshot.status), marginRate=\(player.rate), card=\(model.playingImportedCommentary != nil)")
        model.returnToSourceFromImportedCommentary()
    }

