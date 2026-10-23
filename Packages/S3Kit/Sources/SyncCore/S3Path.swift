/// S3 key 的路径约定：根目录 = ""；文件夹 = 以 "/" 结尾的前缀；其余是文件。
public enum S3Path {
    public static func isFolder(_ key: String) -> Bool {
        key.isEmpty || key.hasSuffix("/")
    }

    /// "a/b/c.txt" → "a/b/"，"a/" → ""，"x" → ""
    public static func parent(of key: String) -> String {
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[...slash])
    }

    /// "a/b/c.txt" → "c.txt"，"a/b/" → "b"
    public static func name(of key: String) -> String {
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}
