import XCTest
@testable import Copilot

final class SpeakerIdentityResolverTests: XCTestCase {
  func testUnresolvedLabelDisplaysRawLabel() {
    let resolver = SpeakerIdentityResolver()
    XCTAssertEqual(resolver.displayName(for:"P1", people:[]), "P1")
  }

  func testExplicitSelfIdentificationResolvesPresentProfile() {
    let sam = Person(name:"Sam Patel")
    var resolver = SpeakerIdentityResolver()
    XCTAssertTrue(resolver.observeFinalTurn(label:"P1", text:"I'm Sam Patel.", people:[sam], presentPersonIDs:[sam.id]))
    XCTAssertEqual(resolver.personID(for:"P1"), sam.id)
    XCTAssertEqual(resolver.displayName(for:"P1", people:[sam]), "Sam Patel")
    XCTAssertEqual(resolver.contexts(people:[sam]), [
      SpeakerIdentityContext(label:"P1", personId:sam.id.uuidString, name:"Sam Patel"),
    ])
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
}

@MainActor
final class SpeakerIdentitySessionTests: XCTestCase {
  func testThatWasMeMarksRealtimeLabelWithoutChangingRawTranscript() {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.phase = .active
    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:1, speaker:"P1", text:"The project went well."))
    XCTAssertEqual(model.captionText, "P1: The project went well.")
    XCTAssertEqual(model.realtimeWearerCandidateLabel, "P1")
    XCTAssertTrue(model.canMarkLastLineAsMine)
    XCTAssertTrue(model.markLastLineAsMine())
    XCTAssertEqual(model.captionText, "You: The project went well.")
    XCTAssertEqual(model.transcript.last?.speaker, "P1")
    model.stop()
  }

  func testNewPartialCannotMarkPreviousFinalizedSpeakerAsWearer() {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.phase = .active
    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:1, speaker:"P1", text:"Partner line."))
    model.applyRealtimeCaption(.init(type:"transcript.partial", turnId:2, speaker:"P2", text:"My current line"))
    XCTAssertEqual(model.transcript.last?.speaker, "P1", "P2 is not finalized yet")
    XCTAssertNil(model.realtimeWearerCandidateLabel)
    XCTAssertFalse(model.canMarkLastLineAsMine)
    XCTAssertFalse(model.markLastLineAsMine())
    XCTAssertEqual(model.displaySpeakerName(for:"P1"), "P1")

    model.applyRealtimeCaption(.init(type:"transcript.final", turnId:2, speaker:"P2", text:"My current line."))
    XCTAssertEqual(model.realtimeWearerCandidateLabel, "P2")
    XCTAssertTrue(model.markLastLineAsMine())
    XCTAssertEqual(model.captionText, "P1: Partner line.\nYou: My current line.")
    XCTAssertEqual(model.transcript.last?.speaker, "P2")
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
}
