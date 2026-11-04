import Foundation

/// All production paths belong to Rhythm after the explicit authority commit.
/// This file is shared with the independent Footprints widget extension.
enum FootprintsIntegratedStorage {
    static func dataDirectory() throws -> URL {
        let root = try RhythmIntegrationPaths.moduleDirectory("footprints")
        try requireDirectory(root)
        let file = root.appendingPathComponent("footprints.sqlite")
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0 else {
            throw StorageFailure("迁入的足迹资料库缺失或不可读，未创建空库。")
        }
        return root
    }

    static func widgetDirectory() throws -> URL {
        let root = try RhythmIntegrationPaths.moduleDirectory("footprints")
            .appendingPathComponent("WidgetData", isDirectory: true)
        try requireDirectory(root)
        return root
    }

    private static func requireDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw StorageFailure("足迹整合目录缺失或类型无效，未初始化新资料。")
        }
    }

    private struct StorageFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
