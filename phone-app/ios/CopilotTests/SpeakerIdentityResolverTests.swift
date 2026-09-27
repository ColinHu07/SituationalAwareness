import XCTest
@testable import Copilot

final class SpeakerIdentityResolverTests: XCTestCase {
  func testUnresolvedLabelDisplaysRawLabel() {
    let resolver = SpeakerIdentityResolver()
    XCTAssertEqual(resolver.displayName(for:"P1", people:[]), "P1")
  }

  func testExplicitSelfIdentificationResolvesProfileWithoutPresence() {
    let sam = Person(name:"Sam Patel")
    var resolver = SpeakerIdentityResolver()
    XCTAssertTrue(resolver.observeFinalTurn(label:"P1", text:"I'm Sam Patel.", people:[sam], presentPersonIDs:[]))
    XCTAssertEqual(resolver.personID(for:"P1"), sam.id)
    XCTAssertEqual(resolver.displayName(for:"P1", people:[sam]), "Sam Patel")
    XCTAssertEqual(resolver.contexts(people:[sam]), [
      SpeakerIdentityContext(label:"P1", personId:sam.id.uuidString, name:"Sam Patel"),
    ])
  }

  func testNaturalLowercaseSelfIntroductionResolvesKnownProfileImmediately() {
    let sam = Person(name:"Sam Patel")
    var resolver = SpeakerIdentityResolver()
    XCTAssertTrue(resolver.observeFinalTurn(label:"P1", text:"Hey everyone, I'm sam patel, nice to meet you.",
                                             people:[sam], presentPersonIDs:[]))
    XCTAssertEqual(resolver.displayName(for:"P1", people:[sam]), "Sam Patel")
  }

  func testIntroducingSomeoneElseDoesNotIdentifyTheCurrentSpeaker() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    XCTAssertFalse(resolver.observeFinalTurn(label:"P1", text:"This is my friend Sam.",
                                              people:[sam], presentPersonIDs:[]))
    XCTAssertNil(resolver.personID(for:"P1"))
  }

  func testWearerDisplaysYou() {
    var resolver = SpeakerIdentityResolver()
    XCTAssertTrue(resolver.markWearer(label:"P1", people:[], presentPersonIDs:[]))
    XCTAssertEqual(resolver.displayName(for:"P1", people:[]), "You")
    XCTAssertTrue(resolver.contexts(people:[]).isEmpty)
  }

  func testRawDiarizationLabelRemainsOnCaptionRow() {
    var roster = PhoneCaptionRoster()
    roster.consume(.init(type:"transcript.final", turnId:1, speaker:"P1", text:"I'm Sam."), at:1_000)
    XCTAssertEqual(roster.rows.first?.id, "P1")
    XCTAssertEqual(roster.rows.first?.speakerLabel, "P1")
  }

  func testPresenceAloneDoesNotIdentifySpeakerInMultiPersonSession() {
    let sam = Person(name:"Sam"), priya = Person(name:"Priya")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.markWearer(label:"P1", people:[sam,priya], presentPersonIDs:[sam.id,priya.id])
    _ = resolver.observeFinalTurn(label:"P2", text:"First ordinary turn.", people:[sam,priya], presentPersonIDs:[sam.id,priya.id])
    _ = resolver.observeFinalTurn(label:"P2", text:"Second ordinary turn.", people:[sam,priya], presentPersonIDs:[sam.id,priya.id])
    XCTAssertNil(resolver.personID(for:"P2"))
  }

  func testAmbiguousFirstNameDoesNotResolve() {
    let samLee = Person(name:"Sam Lee"), samPatel = Person(name:"Sam Patel")
    var resolver = SpeakerIdentityResolver()
    XCTAssertFalse(resolver.observeFinalTurn(label:"P1", text:"I'm Sam.", people:[samLee,samPatel],
                                             presentPersonIDs:[samLee.id,samPatel.id]))
    XCTAssertNil(resolver.personID(for:"P1"))
    XCTAssertTrue(resolver.conflictingLabels.contains("P1"))
  }

  func testIncidentalNamePhraseDoesNotCountAsSelfIdentification() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    XCTAssertFalse(resolver.observeFinalTurn(label:"P1", text:"They think my name is Sam.", people:[sam],
                                             presentPersonIDs:[sam.id]))
    XCTAssertNil(resolver.personID(for:"P1"))
  }

  func testConflictingEvidenceCannotOverwriteMapping() {
    let sam = Person(name:"Sam"), priya = Person(name:"Priya")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"My name is Sam.", people:[sam,priya], presentPersonIDs:[sam.id,priya.id])
    XCTAssertFalse(resolver.observeFinalTurn(label:"P1", text:"I'm Priya.", people:[sam,priya], presentPersonIDs:[sam.id,priya.id]))
    XCTAssertEqual(resolver.personID(for:"P1"), sam.id)
    XCTAssertTrue(resolver.conflictingLabels.contains("P1"))
  }

  func testOnePersonCannotMapToTwoLabels() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"I'm Sam.", people:[sam], presentPersonIDs:[sam.id])
    XCTAssertFalse(resolver.observeFinalTurn(label:"P2", text:"My name is Sam.", people:[sam], presentPersonIDs:[sam.id]))
    XCTAssertEqual(resolver.personID(for:"P1"), sam.id)
    XCTAssertNil(resolver.personID(for:"P2"))
  }

  func testCaptionLabelRestartClearsMappingsAndEvidence() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"I'm Sam.", people:[sam], presentPersonIDs:[sam.id])
    resolver.resetLabelMappings()
    XCTAssertNil(resolver.personID(for:"P1"))
    XCTAssertNil(resolver.wearerLabel)
    XCTAssertTrue(resolver.finalizedTurnCounts.isEmpty)
    XCTAssertEqual(resolver.displayName(for:"P1", people:[sam]), "P1")
  }

  func testSessionStopClearsAllResolverState() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"I'm Sam.", people:[sam], presentPersonIDs:[sam.id])
    resolver.resetSession()
    XCTAssertTrue(resolver.personByLabel.isEmpty)
    XCTAssertTrue(resolver.conflictingLabels.isEmpty)
  }

  func testUniquePersonFusionRequiresWearerAndTwoFinalTurns() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P2", text:"First turn.", people:[sam], presentPersonIDs:[sam.id])
    XCTAssertNil(resolver.personID(for:"P2"), "Presence and one turn are insufficient")
    _ = resolver.markWearer(label:"P1", people:[sam], presentPersonIDs:[sam.id])
    XCTAssertNil(resolver.personID(for:"P2"), "The non-wearer label still needs two finalized turns")
    XCTAssertTrue(resolver.observeFinalTurn(label:"P2", text:"Second turn.", people:[sam], presentPersonIDs:[sam.id]))
    XCTAssertEqual(resolver.personID(for:"P2"), sam.id)
  }

  func testMultiplePresentPeoplePreventUniquePersonFusion() {
    let sam = Person(name:"Sam"), priya = Person(name:"Priya")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.markWearer(label:"P1", people:[sam,priya], presentPersonIDs:[sam.id,priya.id])
    _ = resolver.observeFinalTurn(label:"P2", text:"First turn.", people:[sam,priya], presentPersonIDs:[sam.id,priya.id])
    _ = resolver.observeFinalTurn(label:"P2", text:"Second turn.", people:[sam,priya], presentPersonIDs:[sam.id,priya.id])
    XCTAssertNil(resolver.personID(for:"P2"))
  }

  func testDirectAddressAndImmediateResponseResolvesPresentPerson() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"Hey Sam, how was the exam?", endMs:1_000, people:[sam], presentPersonIDs:[sam.id])
    XCTAssertTrue(resolver.observeFinalTurn(label:"P2", text:"Pretty good.", endMs:3_000, people:[sam], presentPersonIDs:[sam.id]))
    XCTAssertEqual(resolver.personID(for:"P2"), sam.id)
    XCTAssertEqual(resolver.displayName(for:"P2", people:[sam]), "Sam")
    XCTAssertEqual(resolver.confidence(for:"P2"), "strong")
  }

  func testGenericMentionDoesNotResolveSpeaker() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"Did Sam finish the exam?", endMs:1_000, people:[sam], presentPersonIDs:[sam.id])
    XCTAssertFalse(resolver.observeFinalTurn(label:"P2", text:"I don't know.", endMs:3_000, people:[sam], presentPersonIDs:[sam.id]))
    XCTAssertNil(resolver.personID(for:"P2"))
  }

  func testDirectAddressWithoutResponseDoesNotMapRandomSpeaker() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"Hey Sam, are you there?", endMs:1_000, people:[sam], presentPersonIDs:[sam.id])
    XCTAssertNil(resolver.personID(for:"P1"))
    XCTAssertTrue(resolver.personByLabel.isEmpty)
  }

  func testReplyFromSameSpeakerDoesNotMap() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"Hey Sam, are you coming?", endMs:1_000, people:[sam], presentPersonIDs:[sam.id])
    _ = resolver.observeFinalTurn(label:"P1", text:"I hope so.", endMs:2_000, people:[sam], presentPersonIDs:[sam.id])
    XCTAssertNil(resolver.personID(for:"P1"))
  }

  func testInterveningSpeakerBreaksAdjacency() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.markWearer(label:"P3", people:[sam], presentPersonIDs:[sam.id])
    _ = resolver.observeFinalTurn(label:"P1", text:"Hey Sam, how was the exam?", endMs:1_000, people:[sam], presentPersonIDs:[sam.id])
    _ = resolver.observeFinalTurn(label:"P3", text:"Wait for me.", endMs:2_000, people:[sam], presentPersonIDs:[sam.id])
    _ = resolver.observeFinalTurn(label:"P2", text:"Pretty good.", endMs:3_000, people:[sam], presentPersonIDs:[sam.id])
    XCTAssertNil(resolver.personID(for:"P2"))
    XCTAssertNil(resolver.personID(for:"P3"))
  }

  func testReplyOutsideTimeWindowDoesNotResolveDirectAddress() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"Hey Sam, how was the exam?", endMs:1_000, people:[sam], presentPersonIDs:[sam.id])
    _ = resolver.observeFinalTurn(label:"P2", text:"Pretty good.", endMs:10_000, people:[sam], presentPersonIDs:[sam.id])
    XCTAssertNil(resolver.personID(for:"P2"))
  }

  func testRepeatedDirectAddressIncreasesEvidenceCount() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"Hey Sam, how are you?", endMs:1_000, people:[sam], presentPersonIDs:[sam.id])
    _ = resolver.observeFinalTurn(label:"P2", text:"Good.", endMs:2_000, people:[sam], presentPersonIDs:[sam.id])
    XCTAssertEqual(resolver.evidence(for:"P2")?.directAddressCount, 1)
    XCTAssertEqual(resolver.confidence(for:"P2"), "strong")

    _ = resolver.observeFinalTurn(label:"P1", text:"Sam, want to grab lunch?", endMs:4_000, people:[sam], presentPersonIDs:[sam.id])
    _ = resolver.observeFinalTurn(label:"P2", text:"Sure!", endMs:5_000, people:[sam], presentPersonIDs:[sam.id])
    XCTAssertEqual(resolver.evidence(for:"P2")?.directAddressCount, 2)
    XCTAssertEqual(resolver.confidence(for:"P2"), "strong_repeated")
  }

  func testDirectAddressWithTwoPresentPeopleResolvesOnlyAddressedPerson() {
    let sam = Person(name:"Sam"), priya = Person(name:"Priya")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"Sam, what time is the meeting?", endMs:1_000, people:[sam,priya], presentPersonIDs:[sam.id,priya.id])
    _ = resolver.observeFinalTurn(label:"P2", text:"At three.", endMs:2_000, people:[sam,priya], presentPersonIDs:[sam.id,priya.id])
    XCTAssertEqual(resolver.personID(for:"P2"), sam.id)
    XCTAssertNil(resolver.label(for:priya.id))
  }

  func testSinglePartnerFusionFailsIfCompetingUnknownPersonExists() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.markWearer(label:"P1", people:[sam], presentPersonIDs:[sam.id], hasCompetingUnknownPerson:true)
    _ = resolver.observeFinalTurn(label:"P2", text:"First turn.", people:[sam], presentPersonIDs:[sam.id], hasCompetingUnknownPerson:true)
    _ = resolver.observeFinalTurn(label:"P2", text:"Second turn.", people:[sam], presentPersonIDs:[sam.id], hasCompetingUnknownPerson:true)
    XCTAssertNil(resolver.personID(for:"P2"))
  }

  func testPresenceAloneNeverMapsPLabel() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    for i in 1...5 {
      _ = resolver.observeFinalTurn(label:"P2", text:"Turn \(i).", people:[sam], presentPersonIDs:[sam.id])
    }
    XCTAssertNil(resolver.personID(for:"P2"), "Presence without wearer marking or conversational cues must never map")
  }

  func testInvalidatePersonIDRemovesMapping() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"I'm Sam.", people:[sam], presentPersonIDs:[])
    XCTAssertEqual(resolver.personID(for:"P1"), sam.id)
    XCTAssertTrue(resolver.invalidate(personID:sam.id))
    XCTAssertNil(resolver.personID(for:"P1"))
    XCTAssertEqual(resolver.displayName(for:"P1", people:[sam]), "P1")
  }

  func testInvalidateLabelRemovesMapping() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"I'm Sam.", people:[sam], presentPersonIDs:[])
    XCTAssertTrue(resolver.invalidate(label:"P1"))
    XCTAssertNil(resolver.personID(for:"P1"))
  }

  func testStrongSelfIdentificationCorrectsWeakerInferredMapping() {
    let sam = Person(name:"Sam"), alex = Person(name:"Alex")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"Hey Sam!", endMs:1_000, people:[sam,alex], presentPersonIDs:[sam.id,alex.id])
    _ = resolver.observeFinalTurn(label:"P2", text:"Hey there.", endMs:2_000, people:[sam,alex], presentPersonIDs:[sam.id,alex.id])
    XCTAssertEqual(resolver.personID(for:"P2"), sam.id)

    // Strong self-identification corrects weaker mapping
    _ = resolver.observeFinalTurn(label:"P2", text:"Actually I'm Alex.", endMs:4_000, people:[sam,alex], presentPersonIDs:[sam.id,alex.id])
    XCTAssertEqual(resolver.personID(for:"P2"), alex.id)
    XCTAssertEqual(resolver.displayName(for:"P2", people:[sam,alex]), "Alex")
  }

  func testStrongerEvidenceUnbindsPersonFromOldLabel() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.markWearer(label:"P1", people:[sam], presentPersonIDs:[sam.id])
    _ = resolver.observeFinalTurn(label:"P2", text:"Turn one.", people:[sam], presentPersonIDs:[sam.id])
    _ = resolver.observeFinalTurn(label:"P2", text:"Turn two.", people:[sam], presentPersonIDs:[sam.id])
    XCTAssertEqual(resolver.personID(for:"P2"), sam.id)

    // P3 introduces themselves as Sam (strength 100 > singlePartner strength 5)
    _ = resolver.observeFinalTurn(label:"P3", text:"I'm Sam.", people:[sam], presentPersonIDs:[sam.id])
    XCTAssertEqual(resolver.personID(for:"P3"), sam.id)
    XCTAssertNil(resolver.personID(for:"P2"))
  }

  func testWearerLabelCannotMapToAnotherPerson() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.markWearer(label:"P1", people:[sam], presentPersonIDs:[sam.id])
    _ = resolver.observeFinalTurn(label:"P1", text:"I'm Sam.", people:[sam], presentPersonIDs:[sam.id])
    XCTAssertEqual(resolver.displayName(for:"P1", people:[sam]), "You")
    XCTAssertNil(resolver.personID(for:"P1"))
  }

  func testOldResolvedMappingDoesNotLeakIntoNextSession() {
    let sam = Person(name:"Sam")
    var resolver = SpeakerIdentityResolver()
    _ = resolver.observeFinalTurn(label:"P1", text:"I'm Sam.", people:[sam], presentPersonIDs:[sam.id])
    XCTAssertEqual(resolver.personID(for:"P1"), sam.id)
    resolver.resetSession()
    XCTAssertNil(resolver.personID(for:"P1"))
    XCTAssertEqual(resolver.displayName(for:"P1", people:[sam]), "P1")
    XCTAssertTrue(resolver.contexts(people:[sam]).isEmpty)
  }
}

@MainActor
final class SpeakerIdentitySessionTests: XCTestCase {
  func testThatWasMeMarksRealtimeLabelWithoutChangingRawTranscript() {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.phase = .active
    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:1, speaker:"P1", text:"The project went well."))
    XCTAssertEqual(model.captionText, "P1: The project went well.")
    XCTAssertNil(model.transcript.last?.speaker)
    XCTAssertEqual(model.transcript.last?.speakerAlias, "P1")
    XCTAssertEqual(model.realtimeWearerCandidateLabel, "P1")
    XCTAssertTrue(model.canMarkLastLineAsMine)
    XCTAssertTrue(model.markLastLineAsMine())
    XCTAssertEqual(model.captionText, "You: The project went well.")
    XCTAssertEqual(model.transcript.last?.speaker, "wearer")
    XCTAssertEqual(model.transcript.last?.speakerAlias, "P1")
    model.stop()
  }

  func testDirectAddressResolvesCaptionAndMarkNotHereRevertsDisplay() {
    let store = PeopleStore(fileURL:nil)
    let sam = store.addPerson("Sam")!
    let model = SessionModel(people:store)
    model.phase = .active
    let t = nowMs()
    model.applyFaceMatches([sam], at:t)
    model.applyFaceMatches([sam], at:t + 1)
    XCTAssertTrue(model.presentPeople.contains(where: { $0.id == sam }))

    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:1, speaker:"P1", text:"Hey Sam, how was the exam?"))
    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:2, speaker:"P2", text:"Pretty good."))

    XCTAssertEqual(model.displaySpeakerName(for:"P2"), "Sam")
    XCTAssertEqual(model.captionText, "P1: Hey Sam, how was the exam?\nSam: Pretty good.")
    XCTAssertEqual(model.speakerIdentityContexts.first?.personId, sam.uuidString)

    // User marks Sam "Not here"
    model.markNotHere(sam)
    XCTAssertEqual(model.displaySpeakerName(for:"P2"), "P2")
    XCTAssertEqual(model.captionText, "P1: Hey Sam, how was the exam?\nP2: Pretty good.")
    XCTAssertTrue(model.speakerIdentityContexts.isEmpty)
  }

  func testNewPartialCannotMarkPreviousFinalizedSpeakerAsWearer() {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.phase = .active
    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:1, speaker:"P1", text:"Partner line."))
    model.applyRealtimeCaption(.init(type:"transcript.partial", turnId:2, speaker:"P2", text:"My current line"))
    XCTAssertNil(model.transcript.last?.speaker, "Wearer role is unknown before confirmation")
    XCTAssertEqual(model.transcript.last?.speakerAlias, "P1", "P2 is not finalized yet")
    XCTAssertNil(model.realtimeWearerCandidateLabel)
    XCTAssertFalse(model.canMarkLastLineAsMine)
    XCTAssertFalse(model.markLastLineAsMine())
    XCTAssertEqual(model.displaySpeakerName(for:"P1"), "P1")

    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:2, speaker:"P2", text:"My current line."))
    XCTAssertEqual(model.realtimeWearerCandidateLabel, "P2")
    XCTAssertTrue(model.markLastLineAsMine())
    XCTAssertEqual(model.captionText, "P1: Partner line.\nYou: My current line.")
    XCTAssertEqual(model.transcript.last?.speaker, "wearer")
    XCTAssertEqual(model.transcript.last?.speakerAlias, "P2")
    XCTAssertEqual(model.transcript.first?.speaker, "other")
    XCTAssertEqual(model.transcript.first?.speakerAlias, "P1")
    model.stop()
  }

  func testResolvedPersonLabelCannotBeConfirmedAsWearer() {
    let store = PeopleStore(fileURL:nil)
    let sam = store.addPerson("Sam")!
    let model = SessionModel(people:store)
    model.phase = .active
    model.applyFaceMatches([sam], at:1_000)
    model.applyFaceMatches([sam], at:1_001)
    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:1, speaker:"P1", text:"I'm Sam."))
    XCTAssertEqual(model.realtimeWearerCandidateLabel, "P1")
    XCTAssertFalse(model.canMarkLastLineAsMine)
    XCTAssertFalse(model.markLastLineAsMine())
    XCTAssertEqual(model.captionText, "Sam: I'm Sam.")
    model.stop()
  }

  func testAbandonedPartialDoesNotBlockLaterFinalForever() {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.phase = .active
    model.applyRealtimeCaption(.init(type:"transcript.partial", turnId:1, speaker:"P1", text:"Abandoned"))
    XCTAssertFalse(model.canMarkLastLineAsMine)

    model.expireCaption(at:Date().timeIntervalSince1970 * 1000 + 15_001)
    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:2, speaker:"P2", text:"This one is complete."))
    XCTAssertEqual(model.realtimeWearerCandidateLabel, "P2")
    XCTAssertTrue(model.canMarkLastLineAsMine)
    model.stop()
  }

  func testNoMappingsLeavesExistingCaptionBehaviorUnchanged() {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.phase = .active
    model.applyRealtimeCaption(.init(type:"transcript.partial", turnId:1, speaker:"P1", text:"Hello"))
    XCTAssertEqual(model.captionText, "P1: Hello")
    XCTAssertEqual(model.displaySpeakerName(for:"P1"), "P1")
    model.stop()
  }

  func testFinalizedTurnBeforeSpeakerUpdatedResolvesProfileOnLateSpeaker() {
    let store = PeopleStore(fileURL:nil)
    _ = store.addPerson("Sam")
    let model = SessionModel(people:store)
    model.phase = .active
    defer { model.stop() }

    // 1. transcript.final arrives first with speaker: nil
    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:1, speaker:nil, text:"I am Sam."))
    XCTAssertEqual(model.captionText, "Speaker…: I am Sam.")
    XCTAssertNil(model.transcript.first?.speaker)
    XCTAssertNil(model.transcript.first?.speakerAlias)
    XCTAssertNil(model.sessionLog.first?.speaker)
    XCTAssertNil(model.sessionLog.first?.speakerAlias)

    // 2. speaker.updated arrives later with speaker: "P1"
    model.applyRealtimeCaption(.init(type:"speaker.updated", turnId:1, speaker:"P1"))
    XCTAssertEqual(model.displaySpeakerName(for:"P1"), "Sam")
    XCTAssertEqual(model.captionText, "Sam: I am Sam.")
    XCTAssertEqual(model.captionRows.first?.speakerLabel, "P1")
    XCTAssertNil(model.transcript.first?.speaker)
    XCTAssertEqual(model.transcript.first?.speakerAlias, "P1")
    XCTAssertNil(model.sessionLog.first?.speaker)
    XCTAssertEqual(model.sessionLog.first?.speakerAlias, "P1")

    // 3. Duplicate late speaker.updated does not duplicate or reprocess
    let transcriptCountBefore = model.transcript.count
    let logCountBefore = model.sessionLog.count
    model.applyRealtimeCaption(.init(type:"speaker.updated", turnId:1, speaker:"P1"))
    XCTAssertEqual(model.transcript.count, transcriptCountBefore)
    XCTAssertEqual(model.sessionLog.count, logCountBefore)
    XCTAssertEqual(model.captionText, "Sam: I am Sam.")
  }

  func testSpeakerUpdatedBeforeFinalizedTurnResolvesProfileImmediately() {
    let store = PeopleStore(fileURL:nil)
    _ = store.addPerson("Sam")
    let model = SessionModel(people:store)
    model.phase = .active
    defer { model.stop() }

    // 1. speaker.updated arrives first
    model.applyRealtimeCaption(.init(type:"speaker.updated", turnId:1, speaker:"P1"))

    // 2. transcript.final arrives second with speaker: nil
    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:1, speaker:nil, text:"I am Sam."))
    XCTAssertEqual(model.displaySpeakerName(for:"P1"), "Sam")
    XCTAssertEqual(model.captionText, "Sam: I am Sam.")
    XCTAssertEqual(model.captionRows.first?.speakerLabel, "P1")
    XCTAssertNil(model.transcript.first?.speaker)
    XCTAssertEqual(model.transcript.first?.speakerAlias, "P1")
    XCTAssertNil(model.sessionLog.first?.speaker)
    XCTAssertEqual(model.sessionLog.first?.speakerAlias, "P1")
  }

  func testDisplayUsesRoleThenIdentityThenRawAlias() {
    let store = PeopleStore(fileURL:nil)
    let sam = store.addPerson("Sam")!
    let model = SessionModel(people:store)
    model.phase = .active
    defer { model.stop() }

    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:1, speaker:"P2", text:"I'm Sam."))
    let known = model.transcript[0]
    XCTAssertEqual(known.speakerAlias, "P2")
    XCTAssertEqual(model.displaySpeakerName(for:known), "Sam")

    let unresolved = TranscriptEntry(text:"Hello", startMs:0, endMs:1, confidence:nil, speakerAlias:"P3")
    XCTAssertEqual(model.displaySpeakerName(for:unresolved), "P3")
    let wearer = TranscriptEntry(text:"Mine", startMs:0, endMs:1, confidence:nil,
                                 speaker:"wearer", speakerAlias:"P1")
    XCTAssertEqual(model.displaySpeakerName(for:wearer), "You")
    XCTAssertEqual(model.transcript[0].speakerAlias, "P2", "Identity resolution must not replace the raw alias")
    XCTAssertEqual(model.speakerIdentityContexts.first?.personId, sam.uuidString)
  }

  func testLearningSnapshotSurvivesResetAndRejectsReusedAliasAcrossReconnect() {
    let sam = Person(name:"Sam"), alex = Person(name:"Alex")
    let old = TranscriptEntry(text:"I got the internship.", startMs:1, endMs:2, confidence:nil,
                              speaker:"other", speakerAlias:"P1")
    let new = TranscriptEntry(text:"I moved apartments.", startMs:3, endMs:4, confidence:nil,
                              speaker:"other", speakerAlias:"P1")

    let preserved = SessionModel.learningSpeakerIdentities(
      log:[old], logGenerations:[old.id:1], identityMappings:[1:["P1":sam.id]], people:[sam,alex]
    )
    XCTAssertEqual(preserved, [SpeakerIdentityContext(label:"P1", personId:sam.id.uuidString, name:"Sam")])

    let conflictingReconnect = SessionModel.learningSpeakerIdentities(
      log:[old,new], logGenerations:[old.id:1,new.id:2],
      identityMappings:[1:["P1":sam.id],2:["P1":alex.id]], people:[sam,alex]
    )
    XCTAssertTrue(conflictingReconnect.isEmpty,
                  "A new connection's P1 must not attribute an old connection's P1 speech")

    let unresolvedReconnect = SessionModel.learningSpeakerIdentities(
      log:[old,new], logGenerations:[old.id:1,new.id:2],
      identityMappings:[1:["P1":sam.id],2:[:]], people:[sam,alex]
    )
    XCTAssertTrue(unresolvedReconnect.isEmpty)
  }
}
