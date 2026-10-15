import ToolKit

/// Add a tool here and it appears in the sidebar. That is the whole plugin API.
extension ToolRegistry {
    static let all = ToolRegistry([
        EnvDiffTool(),
        EnvExampleTool(),
        SecretScanTool(),
        RandomSecretTool(),
        PasswordGeneratorTool(),
        UUIDTool(),
        JWTDecoderTool(),
        Base64Tool(),
        URLEncodeTool(),
    ])
}
