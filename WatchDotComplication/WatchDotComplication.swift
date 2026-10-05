import SwiftUI
import WidgetKit
import UIKit

private struct LauncherEntry: TimelineEntry {
    let date: Date
    let icon: UIImage?

    init(date: Date, pointSide: CGFloat = 50) {
        self.date = date
        // SwiftUI's resizable() only changes layout. WidgetKit must receive an image
        // whose actual pixels fit the complication, not the 1024-pixel app icon.
        let pixels = max(1, Int((pointSide * 2).rounded(.down)))
        guard let source = UIImage(named: "WatchDotIcon")?.cgImage,
              let context = CGContext(data: nil, width: pixels, height: pixels,
                                      bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            icon = nil
            return
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        icon = context.makeImage().map { UIImage(cgImage: $0, scale: 2, orientation: .up) }
    }
}

private struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry {
        entry(in: context, stage: "placeholder")
    }
    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(entry(in: context, stage: "snapshot"))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        // The icon never changes. No account, network, timer, or periodic refresh.
        completion(Timeline(entries: [entry(in: context, stage: "timeline")], policy: .never))
    }

    private func entry(in context: Context, stage: String) -> LauncherEntry {
        let maximumSide: CGFloat = context.family == .accessoryCorner ? 40 : 50
        let side = min(maximumSide, context.displaySize.width, context.displaySize.height)
        let entry = LauncherEntry(date: .now, pointSide: side)
        #if DEBUG
        // Three bounded local files for device validation; no personal data or network.
        let record: [String: Any] = [
            "revision": 6, "stage": stage, "date": Date.now.timeIntervalSince1970,
            "family": context.family.rawValue, "preview": context.isPreview,
            "width": context.displaySize.width, "height": context.displaySize.height,
            "imageLoaded": entry.icon != nil,
            "pixelWidth": entry.icon?.cgImage?.width ?? 0,
            "pixelHeight": entry.icon?.cgImage?.height ?? 0
        ]
        let url = URL.cachesDirectory.appendingPathComponent("watchdot-icon-\(stage).json")
        if let data = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys) {
            try? data.write(to: url, options: .atomic)
        }
        #endif
        return entry
    }
}

private struct LauncherIcon: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let appIcon: UIImage?

    var body: some View {
        Group {
            if let appIcon {
                // Archive only the bitmap prepared at the complication's actual pixel size.
                icon(Image(uiImage: appIcon).renderingMode(.original).resizable())
                    .scaledToFit()
                    .clipShape(Circle())
            } else {
                Text("WD").font(.headline).foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .privacySensitive(false)
        .unredacted()
        .accessibilityLabel("Abrir Watch Dot")
        .containerBackground(.clear, for: .widget)
    }

    @ViewBuilder
    private func icon(_ image: Image) -> some View {
        if renderingMode == .accented {
            if #available(watchOS 11.0, *) {
                image.widgetAccentedRenderingMode(.desaturated)
            } else {
                Color.white.mask(image.scaledToFit().luminanceToAlpha())
            }
        } else {
            image
        }
    }
}

@main
struct WatchDotComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "cl.australapps.watchdot.launcher", provider: LauncherProvider()) { entry in
            LauncherIcon(appIcon: entry.icon)
        }
        .configurationDisplayName("Watch Dot")
        .description("Abre el chat con Andy.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
        .contentMarginsDisabled()
    }
}

#Preview("Circular", as: .accessoryCircular) {
    WatchDotComplication()
} timeline: {
    LauncherEntry(date: .now)
}

#Preview("Esquina", as: .accessoryCorner) {
    WatchDotComplication()
} timeline: {
    LauncherEntry(date: .now)
}

#Preview("Icono con redacción del sistema") {
    LauncherIcon(appIcon: LauncherEntry(date: .now).icon)
        .frame(width: 50, height: 50)
        .redacted(reason: .placeholder)
        .environment(\.colorScheme, .dark)
}
