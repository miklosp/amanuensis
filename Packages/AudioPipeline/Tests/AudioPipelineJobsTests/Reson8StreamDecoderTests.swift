import Testing
@testable import AudioPipelineJobs

@Suite struct Reson8StreamDecoding {
    @Test func interimTranscript_isPartial() {
        let e = Reson8StreamDecoder.decode(#"{"type":"transcript","text":"the patient","is_final":false}"#)
        #expect(e == .partial("the patient"))
    }
    @Test func finalTranscript_isFinal() {
        let e = Reson8StreamDecoder.decode(#"{"type":"transcript","text":"the patient presented","is_final":true}"#)
        #expect(e == .final("the patient presented"))
    }
    @Test func transcriptWithoutIsFinal_defaultsToFinal() {
        let e = Reson8StreamDecoder.decode(#"{"type":"transcript","text":"hello"}"#)
        #expect(e == .final("hello"))
    }
    @Test func transcriptWithoutText_isIgnored() {
        let e = Reson8StreamDecoder.decode(#"{"type":"transcript","is_final":true}"#)
        #expect(e == .ignored)
    }
    @Test func flushConfirmationWithID() {
        let e = Reson8StreamDecoder.decode(#"{"type":"flush_confirmation","id":"stop"}"#)
        #expect(e == .flushConfirmed(id: "stop"))
    }
    @Test func flushConfirmationWithoutID() {
        let e = Reson8StreamDecoder.decode(#"{"type":"flush_confirmation"}"#)
        #expect(e == .flushConfirmed(id: nil))
    }
    @Test func unknownType_isIgnored() {
        #expect(Reson8StreamDecoder.decode(#"{"type":"turn_start"}"#) == .ignored)
    }
    @Test func malformedJSON_isIgnored() {
        #expect(Reson8StreamDecoder.decode("not json at all") == .ignored)
    }
}
