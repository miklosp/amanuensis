import Testing
@testable import DictationCore

@Suite struct CommitControllerTests {
    @Test func belowWindowCommitsNothing() {
        var c = CommitController(stabilityCount: 2)
        c.update(partial: "hello")
        #expect(c.committed == "")
        #expect(c.volatileTail == "hello")
        #expect(c.fullHypothesis == "hello")
    }

    @Test func commitsStableWordBoundaryPrefix() {
        var c = CommitController(stabilityCount: 2)
        c.update(partial: "the qu")
        c.update(partial: "the quick")        // LCP "the qu" -> trim "the "
        #expect(c.committed == "the ")
        #expect(c.volatileTail == "quick")
    }

    @Test func noCommittedChurnWhenRevisionStaysInVolatile() {
        var c = CommitController(stabilityCount: 2)
        c.update(partial: "I want")
        c.update(partial: "I want to")        // commits "I "
        c.update(partial: "I wanted to")      // "want"->"wanted" but still volatile
        #expect(c.committed == "I ")
    }

    @Test func committedShrinksOnLateRevision() {
        var c = CommitController(stabilityCount: 2)
        c.update(partial: "I think")
        c.update(partial: "I think it")       // commits "I "
        c.update(partial: "I think it is")    // commits "I think "
        #expect(c.committed == "I think ")
        c.update(partial: "I thought it is")  // think->thought AFTER commit
        #expect(c.committed == "I ")          // committed shrank (hard case)
    }

    @Test func finalizeAccumulatesAcrossSegments() {
        var c = CommitController(stabilityCount: 2)
        c.finalize("Hello.")
        #expect(c.committed == "Hello.")
        #expect(c.volatileTail == "")
        c.update(partial: " world")
        c.finalize(" world wide.")
        #expect(c.committed == "Hello. world wide.")
    }
}
