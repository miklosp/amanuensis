import Testing
@testable import DictationCore

@Test func quickTapEmitsToggle() {
    var r = ModifierGestureRecognizer(trigger: .rightCommand)
    #expect(r.triggerDown() == .startHoldTimer)
    #expect(r.triggerUp() == .toggle)
}

@Test func holdEmitsPTTStartThenEnd() {
    var r = ModifierGestureRecognizer(trigger: .rightCommand)
    #expect(r.triggerDown() == .startHoldTimer)
    #expect(r.holdElapsed() == .pttStart)
    #expect(r.triggerUp() == .pttEnd)
}

@Test func foreignKeyDuringPressCancelsAndSwallowsRelease() {
    var r = ModifierGestureRecognizer(trigger: .rightCommand)
    #expect(r.triggerDown() == .startHoldTimer)
    #expect(r.foreignInput() == .cancel)
    #expect(r.triggerUp() == .none)        // the ⌘ release after ⌘C must NOT toggle
}

@Test func holdElapsedWithoutTrackingIsNoop() {
    var r = ModifierGestureRecognizer(trigger: .rightCommand)
    #expect(r.holdElapsed() == .none)
}

@Test func secondHoldElapsedIsNoop() {
    var r = ModifierGestureRecognizer(trigger: .rightCommand)
    _ = r.triggerDown()
    #expect(r.holdElapsed() == .pttStart)
    #expect(r.holdElapsed() == .none)
}

@Test func reentrantTriggerDownIsIgnoredWhileTracking() {
    var r = ModifierGestureRecognizer(trigger: .rightCommand)
    #expect(r.triggerDown() == .startHoldTimer)
    #expect(r.triggerDown() == .none)
}
