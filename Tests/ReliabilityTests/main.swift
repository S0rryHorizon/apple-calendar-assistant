import Foundation
let tests = ReliabilityTests()
run(tests, name: "testReplayDoesNotCallBackendOrPreflight", body: tests.testReplayDoesNotCallBackendOrPreflight)
run(tests, name: "testSameIDWithDifferentPayloadRejected", body: tests.testSameIDWithDifferentPayloadRejected)
run(tests, name: "testWriteThenFailureIsUnknownAndNeverRetried", body: tests.testWriteThenFailureIsUnknownAndNeverRetried)
run(tests, name: "testInterruptedExecutionSurvivesReopen", body: tests.testInterruptedExecutionSurvivesReopen)
run(tests, name: "testPreflightRejectsWithoutStartingMutation", body: tests.testPreflightRejectsWithoutStartingMutation)
run(tests, name: "testConcurrentJournalIsRejected", body: tests.testConcurrentJournalIsRejected)
run(tests, name: "testPatchPreservesFieldsAndDuration", body: tests.testPatchPreservesFieldsAndDuration)
run(tests, name: "testPatchExplicitClearAndAmbiguousClear", body: tests.testPatchExplicitClearAndAmbiguousClear)
if TestResults.shared.failures > 0 { exit(1) }
print("8 reliability scenarios passed")
