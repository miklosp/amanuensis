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
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassTile(in: Capsule())
            .fixedSize()
            .animation(.smooth(duration: 0.3), value: model.state)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onResize($0) }
    }

    @ViewBuilder
    private var content: some View {
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
