```When Editing
本文档作用: 面向开发者的发版记录; CHANGELOG.md 的超集, 1:1 镜像 + 技术变更子项
遵循 AGENTS.md 文档编写规范
- 每条主项 = CHANGELOG.md 对应条目 (原文), 下方缩进子项承载技术变更
- 子项 MAY 写路径 / 函数 / 机制; ≤ 1 行
```

# Changelog (developer, follow [CHANGELOG.md](./CHANGELOG.md))

## [0.1.0] - 2026-10-04

### Added

- 首个 macOS App: 启动显示 Hello World 窗口
  - Swift 6 + SwiftUI; 原生 Xcode 工程; macOS 14+; ad-hoc 签名
- 支持一条命令构建并安装本机 App, 验证启动后自动退出
  - scripts/install-local.sh: Release 构建 / 签名检查 / 安装 / 启动验证 / 退出
- 正式版与调试版使用独立名称, 共用 Git 图标; 调试版增加小型 D 标记
  - Debug 独立 PRODUCT_NAME / Bundle ID / AppIconDebug; 图标资源直接纳入工程
