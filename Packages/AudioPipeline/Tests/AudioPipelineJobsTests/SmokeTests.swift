import Testing
@testable import AudioPipelineJobs

@Suite struct AudioPipelineJobsSmoke {
    @Test func module_imports() {
        // Compiling and linking is the assertion.
        #expect(true)
    }
}
