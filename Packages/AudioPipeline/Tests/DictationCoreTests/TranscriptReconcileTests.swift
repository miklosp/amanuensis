import Testing
@testable import DictationCore

@Suite struct TranscriptReconcileTests {
    @Test func reconcilePureAppend() {
        #expect(reconcile(from: "ab", to: "abc") == TextDiff(backspaces: 0, insert: "c"))
    }

    @Test func reconcileReplaceSuffix() {
        #expect(reconcile(from: "abc", to: "abd") == TextDiff(backspaces: 1, insert: "d"))
    }

    @Test func reconcileFullReplace() {
        #expect(reconcile(from: "abc", to: "xyz") == TextDiff(backspaces: 3, insert: "xyz"))
    }

    @Test func reconcileEmptyOld() {
        #expect(reconcile(from: "", to: "new") == TextDiff(backspaces: 0, insert: "new"))
    }

    @Test func reconcileEmptyNew() {
        #expect(reconcile(from: "old", to: "") == TextDiff(backspaces: 3, insert: ""))
    }

    @Test func reconcileIdentical() {
        #expect(reconcile(from: "same", to: "same") == TextDiff(backspaces: 0, insert: ""))
    }

    @Test func lcpOfArray() {
        #expect(longestCommonPrefix(of: ["I want to", "I wanted to"]) == "I want")
    }

    @Test func trimDropsTrailingPartialWord() {
        #expect(trimToLastWordBoundary("I wanted to") == "I wanted ")
        #expect(trimToLastWordBoundary("hello") == "")
        #expect(trimToLastWordBoundary("") == "")
    }
}
