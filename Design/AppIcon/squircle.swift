import SwiftUI
import AppKit

// Dump the exact continuous-corner rounded rectangle (Apple squircle) that
// macOS app icons use, as SVG path data.
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: rect).cgPath

var out = ""
path.applyWithBlock { el in
    let p = el.pointee.points
    switch el.pointee.type {
    case .moveToPoint:    out += "M\(r(p[0].x)) \(r(p[0].y)) "
    case .addLineToPoint: out += "L\(r(p[0].x)) \(r(p[0].y)) "
    case .addQuadCurveToPoint: out += "Q\(r(p[0].x)) \(r(p[0].y)) \(r(p[1].x)) \(r(p[1].y)) "
    case .addCurveToPoint: out += "C\(r(p[0].x)) \(r(p[0].y)) \(r(p[1].x)) \(r(p[1].y)) \(r(p[2].x)) \(r(p[2].y)) "
    case .closeSubpath:   out += "Z"
    @unknown default: break
    }
}
func r(_ v: CGFloat) -> String { String(format: "%.2f", v) }
print(out)
