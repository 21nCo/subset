import Foundation

enum LauncherMode: Equatable {
    case search
    case quickNote
}

enum SearchResultKind: String, CaseIterable, Identifiable {
    case app = "Apps"
    case file = "Files"
    case shortcut = "Shortcuts"
    case emoji = "Emoji"
    case window = "Window"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .app: return "app.dashed"
        case .file: return "doc.text.magnifyingglass"
        case .shortcut: return "sparkles"
        case .emoji: return "face.smiling"
        case .window: return "macwindow"
        }
    }
}

enum SearchFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case apps = "Apps"
    case files = "Files"
    case images = "Images"
    case text = "Text"
    case shortcuts = "Shortcuts"
    case emoji = "Emoji"
    case calculator = "Calculator"

    var id: String { rawValue }

    static let searchChips: [SearchFilter] = [
        .all,
        .apps,
        .files,
        .images,
        .text,
        .shortcuts
    ]
}

struct SearchResult: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let kind: SearchResultKind
    let url: URL?
    let copyText: String?
    let windowCommand: WindowCommand?

    static func app(name: String, url: URL) -> SearchResult {
        SearchResult(
            id: "app-\(url.path)",
            title: name,
            subtitle: url.path,
            kind: .app,
            url: url,
            copyText: nil,
            windowCommand: nil
        )
    }

    static func file(url: URL) -> SearchResult {
        SearchResult(
            id: "file-\(url.path)",
            title: url.lastPathComponent,
            subtitle: url.deletingLastPathComponent().path,
            kind: .file,
            url: url,
            copyText: nil,
            windowCommand: nil
        )
    }

    static func shortcut(name: String) -> SearchResult {
        SearchResult(
            id: "shortcut-\(name)",
            title: name,
            subtitle: "Siri Shortcut",
            kind: .shortcut,
            url: nil,
            copyText: nil,
            windowCommand: nil
        )
    }

    static func emoji(symbol: String, name: String) -> SearchResult {
        SearchResult(
            id: "emoji-\(symbol)-\(name)",
            title: symbol,
            subtitle: name,
            kind: .emoji,
            url: nil,
            copyText: symbol,
            windowCommand: nil
        )
    }

    static func windowCommand(_ command: WindowCommand) -> SearchResult {
        SearchResult(
            id: "window-\(command.rawValue)",
            title: command.title,
            subtitle: command.subtitle,
            kind: .window,
            url: nil,
            copyText: nil,
            windowCommand: command
        )
    }
}

extension SearchResult {
    var isImageFile: Bool {
        guard kind == .file, let url, !url.hasDirectoryPath else { return false }
        return ["png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp", "webp", "svg"].contains(url.pathExtension.lowercased())
    }

    var isTextFile: Bool {
        guard kind == .file, let url, !url.hasDirectoryPath else { return false }
        return ["txt", "md", "rtf", "json", "csv", "xml", "html", "css", "js", "ts", "swift", "py", "rb", "yml", "yaml", "log"].contains(url.pathExtension.lowercased())
    }
}

enum WindowCommand: String, CaseIterable, Identifiable {
    case maximize
    case center
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maximize: return "Maximize Window"
        case .center: return "Center Window"
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    var subtitle: String {
        "Window management command"
    }

    var searchTerms: String {
        switch self {
        case .maximize: return "maximize max full screen fill window"
        case .center: return "center centre middle window"
        case .leftHalf: return "left half move resize window"
        case .rightHalf: return "right half move resize window"
        case .topHalf: return "top half upper move resize window"
        case .bottomHalf: return "bottom half lower move resize window"
        case .topLeft: return "top left upper left quarter move resize window"
        case .topRight: return "top right upper right quarter move resize window"
        case .bottomLeft: return "bottom left lower left quarter move resize window"
        case .bottomRight: return "bottom right lower right quarter move resize window"
        }
    }
}
