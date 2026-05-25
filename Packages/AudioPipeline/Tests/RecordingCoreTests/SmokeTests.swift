import Testing
import RecordingCore

// Placeholder test that asserts the RecordingCore module compiles into a
// test target. Real tests (RecorderStateMachine, OutputConversionPlanner,
// FLACExporter against fixture CAF) will replace this per the
// test-coverage spec
// (docs/superpowers/specs/2026-05-22-test-coverage-design.md).
@Test func moduleImports() {
    #expect(Bool(true))
}
