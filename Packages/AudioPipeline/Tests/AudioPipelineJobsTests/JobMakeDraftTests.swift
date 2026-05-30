import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct JobMakeDraft {
    @Test func draftHasNoProvider() {
        let draft = Job.makeDraft()
        #expect(draft.providerID == nil)
        #expect(draft.name == "Untitled")
        #expect(draft.model == "")
        #expect(draft.fields == [:])
        #expect(draft.outputExt == "txt")
        #expect(draft.outputFolderPath == nil)
    }

    @Test func assignsDistinctIDsPerCall() {
        let a = Job.makeDraft()
        let b = Job.makeDraft()
        #expect(a.id != b.id)
    }
}
