# Contributing to Open Island

Thank you for your interest in contributing to Open Island!

感谢你对 Open Island 项目的关注与贡献！

---

## Human Parts

*This section is written for humans.*

*这部分内容是给人类阅读的。*

We welcome all good ideas. If you have the will, you can turn any idea into code for this project and have it used by others.

我们欢迎一切好的想法，只要你有意愿，你可以把任何想法变成这个项目的代码，并被其他人使用。

All code in this project is produced by AI. You should not contribute human-written code either.

本项目所有代码均由 AI 产出，因此你也不应该贡献人类产出的代码。

### Getting Started / 如何开始

We've put effort into making it easy for AI to iterate on this project. To start contributing, paste the following into your code agent:

我们在让 AI 更好迭代这个项目上做了一些功夫。想要开始贡献，你需要在你的 code agent 中输入下面这段话：

```
帮我阅读这个项目的 CONTRIBUTING.md 并说明我应该如何迭代这个项目，
然后向我列出你已知的信息，例如发布构建/仓库架构/代码规范/在仓库中的PR规范等等。
```

### Report a Bug via Your Code Agent / 用你的代理上报 Bug

If you run into a problem, copy the prompt below into your code agent (Claude Code, Codex, etc.) and it will automatically collect environment info and create a well-structured issue for you.

如果你遇到了问题，把下面的 prompt 复制到你的代理（Claude Code、Codex 等）中，它会自动收集环境信息并帮你创建一个结构清晰的 issue。

<details>
<summary>Click to expand the prompt / 点击展开 prompt</summary>

```
I'm having an issue with Open Island (https://github.com/Octane0411/open-vibe-island).

Please help me file a GitHub issue. Do the following:

1. Collect my environment info:
   - Run `sw_vers` to get macOS version
   - Run `swift --version` to get Swift version
   - Check if Open Island is running: `ps aux | grep -i "open.island\|OpenIslandApp" | grep -v grep`
   - Get the app version: `defaults read ~/Applications/Open\ Island\ Dev.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "unknown"`
   - Check which terminal I'm using

2. Ask me to describe:
   - What I expected to happen
   - What actually happened
   - Steps to reproduce

3. Create the issue on GitHub using `gh issue create` with this format:
   - Title: concise summary
   - Body with sections: **Environment**, **Description**, **Steps to Reproduce**, **Expected vs Actual Behavior**
   - Add label "bug" if applicable

Repository: Octane0411/open-vibe-island
```

</details>

### Request a Feature via Your Code Agent / 用你的代理提交功能建议

Have an idea? Let your agent draft the proposal for you.

有新想法？让你的代理帮你起草提案。

<details>
<summary>Click to expand the prompt / 点击展开 prompt</summary>

```
I'd like to request a feature for Open Island (https://github.com/Octane0411/open-vibe-island).

Please help me file a GitHub issue. Do the following:

1. Ask me to describe:
   - What feature I want
   - Why it would be useful (what problem it solves)
   - Any ideas on how it should work

2. Create the issue on GitHub using `gh issue create` with this format:
   - Title: concise summary prefixed with "feat: "
   - Body with sections: **Feature Description**, **Motivation**, **Proposed Behavior**
   - Add label "enhancement" if applicable

Repository: Octane0411/open-vibe-island
```

</details>

---

## Agent Parts

*This section is written for agents.*

*这部分内容是给 agent 阅读的。*

### About the Project / 项目简介

Open Island is a native macOS companion app for AI coding agents. It sits in the notch/top-bar area and monitors local agent sessions, surfaces permission requests, answers questions, and provides "jump back" to the correct terminal context. Local-first, no server dependency.

Open Island 是一个原生 macOS 应用，作为 AI 编程代理的桌面伴侣。它驻留在刘海/顶栏区域，监控本地代理会话、展示权限请求、回答问题，并提供"跳转回"对应终端上下文的能力。完全本地运行，无需服务端。

**Supported agents / 支持的代理**: Codex, Claude Code

**Supported terminals / 支持的终端**: Terminal.app, Ghostty

### Prerequisites / 环境要求

- macOS 14+
- Swift 6.2+
- Xcode (for app target)

### Build & Test / 构建与测试

```bash
# Build the project / 构建项目
swift build

# Run tests / 运行测试
swift test

# Run the app / 运行应用
swift run OpenIslandApp

# Build hook binary (release) / 构建 Hook 可执行文件（Release）
swift build -c release --product OpenIslandHooks
```

You can also open `Package.swift` in Xcode to build and run the app target directly.

也可以在 Xcode 中打开 `Package.swift`，直接构建和运行应用。

### Where to Go Next / 进一步了解

- [`CLAUDE.md`](CLAUDE.md) — Architecture, conventions, branching rules, commit policy, and release workflow.
- [`docs/architecture.md`](docs/architecture.md) — System design and engineering decisions.
- [`docs/product.md`](docs/product.md) — Product scope and MVP boundary.
- [`docs/hooks.md`](docs/hooks.md) — Supported hook events, payload fields, and directive protocol.
