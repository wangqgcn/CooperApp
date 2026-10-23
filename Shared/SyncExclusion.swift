/// Finder 和 Office 生成的系统文件不传到存储桶。挂载和主程序上传文件夹时都用这条规则。
enum SyncExclusion {
    static func isExcluded(_ name: String) -> Bool {
        name == ".DS_Store" || name == ".localized" || name.hasPrefix("._") || name.hasPrefix("~$") || name == "Icon\r"
    }
}
