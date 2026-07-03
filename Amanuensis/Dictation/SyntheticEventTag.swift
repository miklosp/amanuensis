/// Written to `kCGEventSourceUserData` on every CGEvent this app synthesizes for
/// text insertion, and read back by `HotkeyTapMonitor` to tell our own injected
/// keystrokes apart from real user input.
///
/// This matters only for live streaming dictation, which types *while the trigger
/// key is still held*: without the tag those synthetic key events read as
/// `.foreignInput`, cancel the dictation gesture, and the real trigger release is
/// never seen (dictation gets stuck on). Value is arbitrary but non-zero ('AMAN').
let syntheticEventUserData: Int64 = 0x414D_414E
