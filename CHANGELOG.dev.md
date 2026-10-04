```When Editing
本文档作用: 面向开发者的发版记录; CHANGELOG.md 的超集, 1:1 镜像 + 技术变更子项
遵循 AGENTS.md 文档编写规范
- 每条主项 = CHANGELOG.md 对应条目 (原文), 下方缩进子项承载技术变更
- 子项 MAY 写路径 / 函数 / 机制; ≤ 1 行
```

# Changelog (developer, follow [CHANGELOG.md](./CHANGELOG.md))

## [0.2.1] - 2026-10-04

### Changed

- 去掉窗口标题栏: 仓库标签与窗口按钮同一行, 顶部少占一行; 空白处可拖动 / 双击缩放窗口
  - `.windowStyle(.hiddenTitleBar)`; `HSplitView` 两栏各自 `.ignoresSafeArea(.container, edges: .top)`; `WindowDragArea` (NSView `performDrag` + `AppleActionOnDoubleClick`)
- 左侧仓库栏可点击按钮或 ⌃⌘S 显示 / 隐藏, 重启后保持
  - `RepositoryLibrary.sidebarHidden` 存 `UserDefaults`; `CommandGroup(replacing: .sidebar)`; 按钮位置两种状态一致
- 工具栏更紧凑, 去掉无用的应用名称显示
  - 仓库工具栏 38 -> 32pt; 移除侧栏「仓库」标题行 (新建分组移入顶部条) 与空状态应用名

## [0.2.0] - 2026-10-04

### Added

- 仓库管理: 打开 / 扫描目录批量导入 / 可折叠分组 / 多标签页, 重启后恢复
  - `Workspace` + `RepositoryLibrary` 存 `UserDefaults`; 扫描跳过隐藏目录 / 符号链接 / node_modules; 打开失败的标签保留并在点击时重试
- 提交历史: 提交图 + 提交详情 + 文件差异; 右键新建分支 / 标签
  - `log --branches --remotes --tags HEAD --date-order` 默认 2000 条可加载更多; `CommitGraphRow` 轨道算法, 列宽上限 8 轨
- 本地变更: 按文件 / 文本块 / 行暂存、取消暂存与放弃; 加入 `.gitignore`; 提交、Amend 及一键推送
  - `TextDiff.patch` 生成补丁 -> `git apply [--cached]`; 处理无末尾换行 / CRLF / 特殊路径 / 多块偏移; 差异已变化则拒绝
- 分支 / 标签 / 远程管理, Fetch / Pull(rebase) / Push / 强制推送; Worktree 列表与切换
  - 强制推送与删除远端引用均用 `--force-with-lease`; Pull = `--rebase --autostash`; 远端分支检出优先切到已有本地分支
- 文件变化 1 秒内自动刷新; 快捷键; 在 iTerm / 编辑器中打开
  - FSEvents 监听工作目录 / Git 目录 / 共享目录 + 前台 5 秒兜底; Git 进程独立执行, 超时 / 取消终止; 启动读取登录 shell PATH 供 hooks 使用

## [0.1.0] - 2026-10-04

### Added

- 首个 macOS App: 启动显示 Hello World 窗口
  - Swift 6 + SwiftUI; 原生 Xcode 工程; macOS 14+; ad-hoc 签名
- 支持一条命令构建并安装本机 App, 验证启动后自动退出
  - scripts/install-local.sh: Release 构建 / 签名检查 / 安装 / 启动验证 / 退出
- 正式版与调试版使用独立名称, 共用 Git 图标; 调试版增加小型 D 标记
  - Debug 独立 PRODUCT_NAME / Bundle ID / AppIconDebug; 图标资源直接纳入工程
