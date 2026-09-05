import XCTest

@MainActor
final class TranscriptModelTests: XCTestCase {
    // Keep every model created by a test alive for the process lifetime.
    // Xcode 26's isolated-deinit path for @MainActor-isolated ObservableObjects
    // races XCTest's post-test memory checker and aborts with a spurious
    // "pointer being freed was not allocated" - reproduces even for a bare
    // ObservableObject with no Muesli code involved. Retaining sidesteps it.
    private static var keepAlive: [TranscriptModel] = []

    private func makeModel() -> TranscriptModel {
        let model = TranscriptModel()
        Self.keepAlive.append(model)
        return model
    }

    private func partialLine(stream: String, t0: Double, text: String) -> String {
        """
        {"type":"partial","stream":"\(stream)","speaker_id":"unknown","t0":\(t0),"text":"\(text)"}
        """
    }

    private func segmentLine(stream: String, t0: Double, t1: Double, text: String, speakerID: String = "unknown") -> String {
        """
        {"type":"segment","stream":"\(stream)","speaker_id":"\(speakerID)","t0":\(t0),"t1":\(t1),"text":"\(text)"}
        """
    }

    // 1. A mic partial survives a system final's arrival (the flicker bug).
    func testOtherStreamPartialSurvivesFinal() {
        let model = makeModel()
        model.echoSuppressionEnabled = false

        model.ingest(jsonLine: partialLine(stream: "mic", t0: 10.0, text: "hello there"))
        XCTAssertEqual(model.segments.count, 1)

        model.ingest(jsonLine: segmentLine(stream: "system", t0: 1.0, t1: 2.0, text: "unrelated final"))

        let micPartials = model.segments.filter { $0.isPartial && $0.stream == "mic" }
        XCTAssertEqual(micPartials.count, 1, "mic partial must survive a system final")
        XCTAssertEqual(micPartials.first?.text, "hello there")
    }

    // 2a. A same-stream partial IS removed when a covering final arrives.
    func testSameStreamPartialRemovedWhenCoveredByFinal() {
        let model = makeModel()
        model.echoSuppressionEnabled = false

        model.ingest(jsonLine: partialLine(stream: "mic", t0: 5.0, text: "in progress"))
        XCTAssertEqual(model.segments.count, 1)

        // Final covers the audio the partial was describing (t1 >= partial.t0).
        model.ingest(jsonLine: segmentLine(stream: "mic", t0: 4.0, t1: 6.0, text: "final version"))

        let micPartials = model.segments.filter { $0.isPartial && $0.stream == "mic" }
        XCTAssertTrue(micPartials.isEmpty, "covered same-stream partial should be dropped")
        let finals = model.segments.filter { !$0.isPartial }
        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals.first?.text, "final version")
    }

    // 2b. A same-stream partial survives when the final is for earlier audio.
    func testSameStreamPartialSurvivesEarlierFinal() {
        let model = makeModel()
        model.echoSuppressionEnabled = false

        model.ingest(jsonLine: partialLine(stream: "mic", t0: 20.0, text: "still talking"))
        XCTAssertEqual(model.segments.count, 1)

        // Final describes older audio; ends well before the partial started.
        model.ingest(jsonLine: segmentLine(stream: "mic", t0: 1.0, t1: 2.0, text: "earlier final"))

        let micPartials = model.segments.filter { $0.isPartial && $0.stream == "mic" }
        XCTAssertEqual(micPartials.count, 1, "partial describing later audio must survive an earlier final")
        XCTAssertEqual(micPartials.first?.text, "still talking")
    }

    // 3. A partial update in place keeps the same id.
    func testPartialUpdateKeepsSameID() {
        let model = makeModel()
        model.echoSuppressionEnabled = false

        model.ingest(jsonLine: partialLine(stream: "mic", t0: 1.0, text: "he"))
        guard let firstID = model.segments.first?.id else {
            return XCTFail("expected a segment")
        }

        model.ingest(jsonLine: partialLine(stream: "mic", t0: 1.2, text: "hello"))
        XCTAssertEqual(model.segments.count, 1)
        XCTAssertEqual(model.segments.first?.id, firstID, "in-place partial update must preserve row identity")
        XCTAssertEqual(model.segments.first?.text, "hello")
    }

    // 4. Overlap dedupe still works (re-emitted overlapping final replaced, not duplicated).
    func testOverlapDedupeReplacesNotDuplicates() {
        let model = makeModel()
        model.echoSuppressionEnabled = false

        model.ingest(jsonLine: segmentLine(stream: "mic", t0: 10.0, t1: 12.0, text: "short"))
        XCTAssertEqual(model.segments.count, 1)

        // Re-emission with a longer/better transcription of (almost) the same window.
        model.ingest(jsonLine: segmentLine(stream: "mic", t0: 10.0, t1: 12.0, text: "a much longer re-emitted transcription"))

        let finals = model.segments.filter { !$0.isPartial && $0.stream == "mic" }
        XCTAssertEqual(finals.count, 1, "overlapping re-emission should replace, not duplicate")
        XCTAssertEqual(finals.first?.text, "a much longer re-emitted transcription")
    }

    // 5. Echo suppression still works (mic segment matching a recent system segment is dropped).
    func testEchoSuppressionDropsMicEchoOfSystem() {
        let model = makeModel()
        model.echoSuppressionEnabled = true

        model.ingest(jsonLine: segmentLine(stream: "system", t0: 3.0, t1: 4.0, text: "this is the system speaking now"))
        XCTAssertEqual(model.segments.count, 1)

        // Mic picks up the same audio as an echo shortly after.
        model.ingest(jsonLine: segmentLine(stream: "mic", t0: 3.05, t1: 4.05, text: "this is the system speaking now"))

        let micFinals = model.segments.filter { !$0.isPartial && $0.stream == "mic" }
        XCTAssertTrue(micFinals.isEmpty, "mic echo of a recent system segment should be dropped")
        XCTAssertEqual(model.segments.count, 1)
    }

    // 6. Out-of-order final still results in sorted segments.
    func testOutOfOrderFinalResultsInSortedSegments() {
        let model = makeModel()
        model.echoSuppressionEnabled = false

        model.ingest(jsonLine: segmentLine(stream: "mic", t0: 10.0, t1: 11.0, text: "second"))
        model.ingest(jsonLine: segmentLine(stream: "mic", t0: 1.0, t1: 2.0, text: "first"))

        let finals = model.segments.filter { !$0.isPartial }
        XCTAssertEqual(finals.map { $0.text }, ["first", "second"])
        XCTAssertEqual(finals.map { $0.t0 }, finals.map { $0.t0 }.sorted())
    }

    // Additional: partials trail finals, and both streams' partials can coexist
    // alongside finals without being clobbered.
    func testFinalsAndMultiStreamPartialsCoexist() {
        let model = makeModel()
        model.echoSuppressionEnabled = false

        model.ingest(jsonLine: partialLine(stream: "mic", t0: 15.0, text: "mic partial"))
        model.ingest(jsonLine: partialLine(stream: "system", t0: 16.0, text: "system partial"))
        model.ingest(jsonLine: segmentLine(stream: "mic", t0: 1.0, t1: 2.0, text: "mic final"))

        XCTAssertEqual(model.segments.count, 3)
        let partials = model.segments.filter { $0.isPartial }
        XCTAssertEqual(Set(partials.map { $0.stream }), Set(["mic", "system"]))
        let finals = model.segments.filter { !$0.isPartial }
        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals.first?.text, "mic final")
    }
}

extension TranscriptModelTests {
    func testResumedPermutedLabelsKeepNamesAcrossSaveAndReplay() throws {
        let model = makeModel()
        model.echoSuppressionEnabled = false
        // Session A label 0 is Alex; session B reuses label 0 for Blair.
        for (source, label, t0, text) in [("A", "system:SPEAKER_00", 0.0, "Alex first"),
                                         ("B", "system:SPEAKER_00", 5.0, "Blair resumed"),
                                         ("B", "system:SPEAKER_01", 8.0, "Alex resumed")] {
            model.ingest(jsonLine: segmentLine(stream: "system", t0: t0, t1: t0 + 1, text: text, speakerID: label), sourceSessionID: source)
        }
        model.speakerNames["system:SPEAKER_00"] = "Wrong legacy name"
        XCTAssertEqual(model.displayName(for: model.segments[0]), "system:SPEAKER_00")
        XCTAssertFalse(model.applySpeakerName(id: "SPEAKER_00", name: "Wrong inferred name"))
        let names = ["Alex", "Blair", "Alex"]
        for (index, name) in names.enumerated() {
            XCTAssertTrue(model.applySpeakerName(id: model.segments[index].speakerKey, name: name))
        }
        let encoded = try TranscriptModel.jsonLines(from: model.segments)
        XCTAssertFalse(encoded.contains("Blair" + "\""))
        let lines = encoded.split(separator: "\n")
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["speaker_id"] as? String, "system:SPEAKER_00")
        XCTAssertEqual(first["source_session_id"] as? String, "A")
        let replay = makeModel()
        replay.echoSuppressionEnabled = false
        for line in lines { replay.ingest(jsonLine: String(line)) }
        replay.speakerNames = try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(model.speakerNames))
        XCTAssertEqual(replay.segments.map(\.speakerKey), model.segments.map(\.speakerKey))
        XCTAssertEqual(replay.segments.map { replay.displayName(for: $0) }, names)
        XCTAssertTrue(replay.asPlainText().contains("[source B]"))
    }

    func testIdentityIncludesStreamAndUnambiguousSource() {
        let identities = [
            TranscriptSpeakerIdentity(sourceSessionID: nil, stream: "system", speakerID: "0"),
            TranscriptSpeakerIdentity(sourceSessionID: "", stream: "system", speakerID: "0"),
            TranscriptSpeakerIdentity(sourceSessionID: "A", stream: "system", speakerID: "0"),
            TranscriptSpeakerIdentity(sourceSessionID: "A", stream: "mic", speakerID: "0"),
            TranscriptSpeakerIdentity(sourceSessionID: "A:system", stream: "mic", speakerID: "0")
        ]
        XCTAssertEqual(Set(identities.map(\.storageKey)).count, identities.count)
        for identity in identities { XCTAssertEqual(TranscriptSpeakerIdentity(storageKey: identity.storageKey), identity) }
    }

    func testPartialsOverlapAndEchoStayWithinSource() {
        let model = makeModel()
        model.ingest(jsonLine: partialLine(stream: "system", t0: 0, text: "first source partial"), sourceSessionID: "A")
        model.ingest(jsonLine: partialLine(stream: "system", t0: 0, text: "second source partial"), sourceSessionID: "B")
        XCTAssertEqual(model.segments.count, 2)
        model.ingest(jsonLine: segmentLine(stream: "system", t0: 0, t1: 1, text: "identical words here"), sourceSessionID: "B")
        XCTAssertEqual(model.segments.filter(\.isPartial).map(\.sourceSessionID), ["A"])
        model.ingest(jsonLine: segmentLine(stream: "system", t0: 0, t1: 1, text: "identical words here"), sourceSessionID: "A")
        XCTAssertEqual(model.segments.count, 2, "same-stream overlap from another source must survive")
        model.ingest(jsonLine: segmentLine(stream: "mic", t0: 0, t1: 1, text: "identical words here"), sourceSessionID: "C")
        XCTAssertEqual(model.segments.count, 3, "echo matching cannot cross source boundaries")
    }

    func testSpeakerEventsUsePerEntrySourceAndStreamAndPreserveReviewedName() {
        let model = makeModel()
        model.ingest(jsonLine: #"{"type":"speakers","known":[{"speaker_id":"0","source_session_id":"A","stream":"system","name":"Alex"},{"speaker_id":"0","source_session_id":"B","stream":"mic","name":"Blair"}]}"#)
        let a = TranscriptSpeakerIdentity(sourceSessionID: "A", stream: "system", speakerID: "0")
        let b = TranscriptSpeakerIdentity(sourceSessionID: "B", stream: "mic", speakerID: "0")
        XCTAssertEqual(model.speakerNames[a.storageKey], "Alex")
        XCTAssertEqual(model.speakerNames[b.storageKey], "Blair")
        model.renameSpeaker(id: a.storageKey, to: "Reviewed Alex")
        model.ingest(jsonLine: #"{"type":"speakers","known":[{"speaker_id":"0","stream":"system","name":"Machine label"}]}"#, sourceSessionID: "A")
        XCTAssertEqual(model.speakerNames[a.storageKey], "Reviewed Alex")
        model.ingest(jsonLine: #"{"type":"segment","source_session_id":"explicit","stream":"system","speaker_id":"0","t0":2,"t1":3,"text":"one"}"#, sourceSessionID: "fallback")
        XCTAssertEqual(model.segments.first?.sourceSessionID, "explicit")
    }

    func testLegacyNameCompatibilityDoesNotNameScopedRecord() {
        let model = makeModel()
        model.echoSuppressionEnabled = false
        model.ingest(jsonLine: segmentLine(stream: "system", t0: 0, t1: 1, text: "legacy", speakerID: "0"))
        model.ingest(jsonLine: segmentLine(stream: "system", t0: 2, t1: 3, text: "scoped", speakerID: "0"), sourceSessionID: "new")
        XCTAssertTrue(model.applySpeakerName(id: "0", name: "Legacy Alex"))
        XCTAssertEqual(model.displayName(for: model.segments[0]), "Legacy Alex")
        XCTAssertEqual(model.displayName(for: model.segments[1]), "0")
    }
}
