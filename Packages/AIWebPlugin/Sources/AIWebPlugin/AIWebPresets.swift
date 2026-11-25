import Foundation

public nonisolated enum AIWebPresets {
    public static let all: [AIWebApp] = [
        preset("chatgpt", name: "ChatGPT", url: "https://chatgpt.com", description: "OpenAI 官方对话、推理与多模态助手", category: .general, logoName: "chatgpt", isTemplate: true, isPinned: true),
        preset("claude", name: "Claude", url: "https://claude.ai", description: "Anthropic 出品，擅长长文本理解与编程协作", category: .general, logoName: "claude", isTemplate: false, isPinned: true),
        preset("gemini", name: "Gemini", url: "https://gemini.google.com", description: "Google 多模态 AI 助手，深度整合 Workspace", category: .general, logoName: "gemini", isTemplate: false, isPinned: true),
        preset("deepseek", name: "DeepSeek", url: "https://chat.deepseek.com", description: "深度求索出品，高性价比推理与代码模型", category: .general, logoName: "deepseek", isTemplate: false, isPinned: true),
        preset("doubao", name: "豆包", url: "https://www.doubao.com/chat/", description: "字节跳动 AI 助手，日常对话与写作效率高", category: .general, logoName: "doubao", isTemplate: false, isPinned: true),
        preset("kimi", name: "Kimi", url: "https://www.kimi.com", description: "月之暗面长文本与深度研究助手", category: .general, logoName: "kimi", isTemplate: false, isPinned: true),
        preset("qwen", name: "通义千问", url: "https://chat.qwen.ai", description: "阿里云通义大模型，支持代码、推理与多模态", category: .general, logoName: "qwen", isTemplate: false, isPinned: false),
        preset("yuanbao", name: "腾讯元宝", url: "https://yuanbao.tencent.com", description: "腾讯混元与微信生态融合的智能助手", category: .general, logoName: "yuanbao", isTemplate: false, isPinned: false),
        preset("chatglm", name: "智谱清言", url: "https://chatglm.cn", description: "智谱 AI 对话、文档分析与智能体平台", category: .general, logoName: "chatglm", isTemplate: false, isPinned: false),
        preset("perplexity", name: "Perplexity", url: "https://www.perplexity.ai", description: "带实时引用溯源的 AI 搜索引擎", category: .search, logoName: "perplexity", isTemplate: false, isPinned: false),
        preset("grok", name: "Grok", url: "https://grok.com", description: "xAI 出品，实时信息检索与深度推理", category: .general, logoName: "grok", isTemplate: true, isPinned: false),
        preset("notebooklm", name: "NotebookLM", url: "https://notebooklm.google.com", description: "Google 知识库笔记与音频播客生成工具", category: .search, logoName: "notebooklm", isTemplate: true, isPinned: false),
        preset("aistudio", name: "Google AI Studio", url: "https://aistudio.google.com", description: "Gemini 模型调试、提示词工程与 API 控制台", category: .coding, logoName: "aistudio", isTemplate: true, isPinned: false),
        preset("poe", name: "Poe", url: "https://poe.com", description: "Quora 出品，一站切换多家主流大模型", category: .general, logoName: "poe", isTemplate: false, isPinned: false),
        preset("copilot", name: "Microsoft Copilot", url: "https://copilot.microsoft.com", description: "微软 AI 助手，兼顾搜索、办公与创作", category: .general, logoName: "copilot", isTemplate: false, isPinned: false),
        preset("wenxin", name: "文心一言", url: "https://yiyan.baidu.com", description: "百度文心大模型对话与文档助手", category: .general, logoName: "wenxin", isTemplate: false, isPinned: false),
        preset("hailuo", name: "海螺 AI", url: "https://hailuoai.com", description: "MiniMax 出品，支持对话、语音与视频创作", category: .creative, logoName: "hailuo", isTemplate: false, isPinned: false),
        preset("coze", name: "扣子 Coze", url: "https://www.coze.cn", description: "新一代 AI 智能体与工作流搭建平台", category: .creative, logoName: "coze", isTemplate: true, isPinned: false),
        preset("spark", name: "讯飞星火", url: "https://xinghuo.xfyun.cn", description: "科大讯飞出品，擅长语音识别与中文写作", category: .general, logoName: "spark", isTemplate: false, isPinned: false),
        preset("mistral", name: "Mistral Le Chat", url: "https://chat.mistral.ai", description: "Mistral AI 官方高速对话与代码助手", category: .general, logoName: "mistral", isTemplate: false, isPinned: false),
    ]

    public static var bundledIconChoices: [(name: String, label: String, isTemplate: Bool)] {
        all.compactMap { app in
            guard case let .bundled(name, isTemplate) = app.logo else { return nil }
            return (name, app.name, isTemplate)
        }
    }

    public static func preset(for presetID: String) -> AIWebApp? {
        all.first { $0.presetID == presetID }
    }

    private static func preset(
        _ key: String,
        name: String,
        url: String,
        description: String,
        category: AICategory,
        logoName: String,
        isTemplate: Bool,
        isPinned: Bool
    ) -> AIWebApp {
        AIWebApp(
            id: "preset.\(key)",
            name: name,
            url: url,
            description: description,
            category: category,
            logo: .bundled(name: logoName, isTemplate: isTemplate),
            isPinned: isPinned,
            neverSuspend: false,
            isBuiltIn: true,
            presetID: key
        )
    }
}
