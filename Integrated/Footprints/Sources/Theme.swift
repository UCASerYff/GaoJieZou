import SwiftUI
import AppKit
import ImageIO

// Series-wide chrome theme, aligned with 搞健康 / 搞月供.
enum Theme {
    static let blue = Color(red:0.20,green:0.45,blue:0.82)
    static let teal = Color(red:0.16,green:0.63,blue:0.53)
    static let orange = Color(red:0.92,green:0.53,blue:0.20)
    static let purple = Color(red:0.48,green:0.36,blue:0.78)
    static func background(_ dark: Bool) -> Color {
        Color(nsColor: dark ? NSColor(srgbRed:0.075,green:0.082,blue:0.095,alpha:1) : NSColor(srgbRed:0.975,green:0.98,blue:0.985,alpha:1))
    }
}
// Parchment palette, reserved for the map artwork itself (canvas, export image).
enum Ink {
    static let text = Color(red:0.24,green:0.21,blue:0.17)
    static let muted = Color(red:0.52,green:0.46,blue:0.37)
    static let paper = Color(red:0.97,green:0.95,blue:0.90)
    static let panel = Color(red:0.99,green:0.98,blue:0.94)
    static let ochre = Color(red:0.68,green:0.37,blue:0.17)
    static let green = Color(red:0.31,green:0.39,blue:0.30)
    static let line = Color(red:0.63,green:0.53,blue:0.38).opacity(0.23)
}
extension View {
    func card(_ padding: CGFloat = 20) -> some View {
        self.padding(padding).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(0.07)))
    }
}
// Panel keeps its call-site shape but renders as the series card.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.card() }
}
struct Heading: View {
    var title: String; var subtitle: String = ""
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.system(size:25,weight:.semibold))
            if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }
}
struct Tile: View {
    var symbol: String; var color: Color = Theme.teal
    var body: some View {
        Image(systemName:symbol).font(.system(size:18,weight:.semibold)).foregroundStyle(color)
            .frame(width:42,height:42).background(color.opacity(0.1),in:RoundedRectangle(cornerRadius:11))
    }
}
struct EmptyJournal: View {
    let symbol: String; let title: String; let subtitle: String
    var body: some View {
        VStack(spacing:14) {
            Image(systemName:symbol).font(.system(size:34)).foregroundStyle(Theme.teal)
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth:.infinity,minHeight:170).padding(24)
    }
}
struct StatItem: View {
    let value: String; let label: String
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            Text(value).font(.system(size:26,weight:.semibold,design:.rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
struct PhotoTile: View {
    let url: URL?
    var size: CGFloat = 76
    var body: some View {
        Group { if let url, let image = thumbnail(url) { Image(nsImage:image).resizable().scaledToFill() } else { Image(systemName:"photo").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.primary.opacity(0.06)) } }
            .frame(width:size,height:size).clipped().clipShape(RoundedRectangle(cornerRadius:8))
    }
    private static let cache = NSCache<NSString, NSImage>()
    private func thumbnail(_ url: URL) -> NSImage? {
        let key = url.path as NSString
        if let hit = Self.cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil), let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:240,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
        let image = NSImage(cgImage:cg,size:.zero)
        Self.cache.setObject(image, forKey: key)
        return image
    }
}
