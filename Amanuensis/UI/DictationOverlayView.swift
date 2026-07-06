import SwiftUI
import DictationCore

/// What the dictation overlay pill is currently showing — derived from the
/// dictation phase, plus a transient flash message.
enum DictationOverlayState: Equatable {
    case loadingModel
    case listening
    case transcribing
    case inserted
    case flash(String)
}

/// Drives the persistent overlay hosting view. The controller mutates `state`
/// and SwiftUI cross-fades the pill's contents. This indirection is what makes
/// the animation possible: the controller keeps one hosting view alive for the
/// panel's lifetime, so SwiftUI can diff state changes — rebuilding the hosting
/// view per change (the old approach) gives it nothing to animate between.
@MainActor
@Observable
final class DictationOverlayModel {
    var state: DictationOverlayState = .listening
    /// Compact rendering for always-on auto-listening: a small dot while
    /// listening, a short "typing…" pill while transcribing — instead of the
    /// full labelled pill the one-shot flow uses.
    var compact = false
}

/// Bottom-center dictation HUD: a Liquid Glass pill whose contents cross-fade
/// between states. Reports its (animating) size via `onResize` so the hosting
/// panel can track the pill's width as it grows and shrinks.
struct DictationOverlayView: View {
    let model: DictationOverlayModel
    let onResize: (CGSize) -> Void

    var body: some View {
        content
            .font(.callout)
            .padding(.horizontal, model.compact ? 10 : 16)
            .padding(.vertical, model.compact ? 7 : 9)
            .glassTile(in: Capsule())
            .fixedSize()
            .animation(.smooth(duration: 0.3), value: model.state)
            .background {
                // Pre-macOS-15 size reporting: a background GeometryReader
                // doesn't affect the pill's layout, and `.onChange` fires on the
                // main actor as the animated width changes. Replaces the macOS-15
                // `.onGeometryChange`.
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.size, initial: true) { _, newSize in
                            onResize(newSize)
                        }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.compact { compactContent } else { fullContent }
    }

    /// Small always-on indicator for auto-listening: a pulsing dot while
    /// listening, a short "typing…" pill during transcription. Errors still get
    /// the text flash so failures aren't silent.
    @ViewBuilder
    private var compactContent: some View {
        switch model.state {
        case .listening, .inserted:
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
                .transition(.blurReplace)
        case .transcribing:
            pill {
                ProgressView().controlSize(.mini)
                Text("typing…")
            }
            .font(.caption)
        case .loadingModel:
            ProgressView().controlSize(.mini).transition(.blurReplace)
        case .flash(let message):
            Text(message).font(.caption).transition(.blurReplace)
        }
    }

    @ViewBuilder
    private var fullContent: some View {
        switch model.state {
        case .loadingModel:
            pill {
                ProgressView().controlSize(.small)
                Text("Loading model…")
            }
        case .listening:
            pill {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("Listening…")
            }
        case .transcribing:
            pill {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
            }
        case .inserted:
            pill {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Inserted")
            }
        case .flash(let message):
            Text(message)
                .transition(.blurReplace)
        }
    }

    private func pill(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8, content: content)
            .transition(.blurReplace)
    }
}
