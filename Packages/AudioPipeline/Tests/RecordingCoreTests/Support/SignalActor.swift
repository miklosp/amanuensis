import Foundation

// Test helper. Lets a test pause an `await wait()` call until another task calls
// `fire()`. Used to hold a fake conversion mid-flight while assertions run.
actor SignalActor {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }
}
