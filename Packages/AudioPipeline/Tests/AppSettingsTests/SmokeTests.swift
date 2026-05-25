import Testing
import AppSettings

// Placeholder test that asserts the AppSettings module compiles into a
// test target. Real tests will replace this per the test-coverage spec
// (docs/superpowers/specs/2026-05-22-test-coverage-design.md).
@Test func outputFormatHasThreeCases() {
    #expect(AppSettings.OutputFormat.allCases.count == 3)
}
