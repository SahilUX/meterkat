import Foundation

enum SkillFile {
    static func data() throws -> Data {
        guard let url = Bundle.main.url(forResource: "SKILL", withExtension: "md") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
