```When Editing
本文档作用: 面向使用者的发版记录; 只写用户感受得到的变化, MUST NOT 写技术细节 (→ CHANGELOG.dev.md)
遵循 AGENTS.md 文档编写规范
- 写: 新功能 / 行为修复 / 体验 / 安全 / 命令迁移
- MUST NOT 写: 文件路径 / 函数名 / 组件名 / 依赖包名 / 重构细节
- 单条 ≤ 2 行, 单版本 ≤ 5 条; 段落: Added / Changed / Fixed / Removed / Security
- 无用户可感知变化 → 占位: `跟随版本同步发布`
```

# Changelog

[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) + [SemVer](https://semver.org/).

## [0.2.0] - 2026-10-04

### Added

- 仓库管理: 打开 / 扫描目录批量导入 / 可折叠分组 / 多标签页, 重启后恢复
- 提交历史: 提交图 + 提交详情 + 文件差异; 右键新建分支 / 标签
- 本地变更: 按文件 / 文本块 / 行暂存、取消暂存与放弃; 加入 `.gitignore`; 提交、Amend 及一键推送
- 分支 / 标签 / 远程管理, Fetch / Pull(rebase) / Push / 强制推送; Worktree 列表与切换
- 文件变化 1 秒内自动刷新; 快捷键; 在 iTerm / 编辑器中打开

## [0.1.0] - 2026-10-04

### Added

- 首个 macOS App: 启动显示 Hello World 窗口
- 支持一条命令构建并安装本机 App, 验证启动后自动退出
- 正式版与调试版使用独立名称, 共用 Git 图标; 调试版增加小型 D 标记
