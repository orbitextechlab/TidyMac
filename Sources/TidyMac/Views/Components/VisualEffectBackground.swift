import SwiftUI
import AppKit

/// Behind-window blur: lets the desktop wallpaper glow through the window,
/// the way the Sweep design layers its translucent shell over the wallpaper.
/// Place a semi-opaque surface tint on top for contrast.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
