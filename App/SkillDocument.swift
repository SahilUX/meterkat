import SwiftUI
import UniformTypeIdentifiers

struct SkillDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "md") ?? .plainText] }

    init() {}

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try SkillFile.data())
    }
}
