```When Editing
本文档作用: 面向开发者的发版记录; CHANGELOG.md 的超集, 1:1 镜像 + 技术变更子项
遵循 AGENTS.md 文档编写规范
- 每条主项 = CHANGELOG.md 对应条目 (原文), 下方缩进子项承载技术变更
- 子项 MAY 写路径 / 函数 / 机制; ≤ 1 行
```

# Changelog (developer, follow [CHANGELOG.md](./CHANGELOG.md))

## [0.4.2] - 2026-10-04

### Added

- 差异默认自动换行, 长行无需横向滚动; 标题栏取消「自动换行」恢复横向滚动, 选择全局记住
  - `DiffView` `@AppStorage("jj-git.diffWrap")` 默认 true; 换行时内容宽度 = 视口, 只纵向滚动, 行高随内容
  - `DiffLineView` 首行基线对齐行号; 实测 20 万行差异换行 / 不换行滚动卡顿无明显差异

## [0.4.1] - 2026-10-04

### Changed

- 跟随版本同步发布
  - `scripts/debug.sh`: `open -n` 多实例并存, 按产物路径退出本 worktree 实例, 输出 PID; 新增 `quit`
  - Debug: `JJGIT_CONFIG_DIR` (默认 `build/debug-config`, 首次复制 `~/.config/jj-git-debug`) + `JJGIT_DEBUG_TAG` (窗口标题 / 侧栏顶部)

## [0.4.0] - 2026-10-04

### Added

- 固定使用 Dracula 深色主题 (窗口 / 标题栏 / 强调色 / 差异 / 提交图配色)
  - `Theme` 色值; `NSApp.appearance = .darkAqua`; `AccentColor` 资源 + `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`; `SplitPaneView.dividerColor`
  - `ThemedDivider`: `overlay(..., ignoresSafeAreaEdges: [])`, 默认延伸安全区会盖住标题栏区域的标签栏
- 可在配置中自定义界面字体、等宽字体、界面字号与代码字号, 修改即时生效
  - `AppConfig.Appearance`; `Typography` (@Observable 单例 + 字体缓存, 缺字重回退常规); `Font.ui/mono/code`; `.themed()` 用于每个 `NSHostingView` 根
  - List 行不继承外层字体, 行内 `Text` 显式 `.font(.ui())`; 历史行高 / 差异行高随字号缩放
- 提交历史中不在当前分支上的提交淡化显示
  - `CommitGraphRow.merged`: 从 HEAD 沿父提交可达; opacity 0.4

## [0.3.6] - 2026-10-04

### Added

- 侧边栏分支 / 标签 / 远程 / 工作树分区: 点击标题折叠或展开, 标题显示数量; 默认展开, 状态记忆
  - `RepositoryLibrary.collapsedSections` (state.json, 空 = 全展开); `Workspace.toggleSection`; `RepositorySidebar.heading` 加折叠按钮

## [0.3.5] - 2026-10-04

### Changed

- 侧边栏工作树: 分支名移到目录名下一行, 淡色显示
  - `RepositorySidebar` 工作树行: 图标 + `VStack` (目录名 / 分支 11pt `.tertiary`), `firstTextBaseline` 对齐图标与目录名

## [0.3.4] - 2026-10-04

### Changed

- 窗口位置 / 尺寸与分栏尺寸改存 `state.json`, 不再写入系统偏好设置
  - `RepositoryLibrary.window` / `.splits`; `SplitPane` 去掉 `autosaveName`, 拖动结束 (`mouseDown` 返回) 写 `Workspace.setSplit`
  - `WindowFrameKeeper`: `setFrameAutosaveName("")` 关闭 SwiftUI 窗口自动保存, 移动 / 缩放停止 0.5 秒后写 `window`
  - `isRestorable = false` 会让下次启动不开窗口, 不使用

## [0.3.3] - 2026-10-04

### Changed

- 所有分割线均可拖动调整宽 / 高 (仓库列表 / 侧栏 / 文件列表 / 提交信息 / 提交历史 / 提交详情), 位置在切换标签、页面和重启后保留
  - `HSplitView` / `VSplitView` / 固定 `Divider` -> `SplitPane` (`NSSplitView` + `NSHostingView`, autosave `jj-git.*`); 原分栏首次布局撑满 maxWidth 导致只能缩小
  - `pinned` 栏窗口缩放保持尺寸 (`shouldAdjustSizeOfSubview`); 提交图列表拆为 `CommitGraphPanel` 持有选中状态

## [0.3.2] - 2026-10-04

### Fixed

- 大文件差异打开更快 (20 万行 11 MB 差异约 1.5 秒 → 0.3 秒), 超长单行不再拖慢界面
  - `TextDiff.init` 去掉对整个 raw 的子串搜索 (占 ~400 ms); 解析 569 → 166 ms
  - `DiffLine.display` / `columns` 只处理前 1000 字符, 渲染耗时与行长无关
- 文件内容未变时轮询刷新不再重新解析差异
  - `RepositoryQuery.diff(reusing:)` 按字节比较原文, 相同则复用上次 `TextDiff`
- 修改过的符号链接也禁止按行暂存; 内容含 `Subproject commit` 的普通文件不再被误判为子模块
  - 符号链接看头部 `mode 120000` / `index … 120000`; 子模块 = 单块且全部行以 `Subproject commit ` 开头

## [0.3.1] - 2026-10-04

### Changed

- `state.json` 手写新增分组只需填写名称
  - `RepositoryGroup.init(from:)`: `id` / `collapsed` 缺省时生成 / 取 false; `sidebarHidden` / `collapsed` 改非可选 `Bool`

### Removed

- 不再从旧版本导入仓库列表
  - 删除 `Workspace.migrate` 与 `init(defaults:)`

## [0.3.0] - 2026-10-04

### Added

- 全部配置存放在 `~/.config/jj-git/`: `config.json` (设置) + `state.json` (仓库 / 分组 / 标签), 外部修改即时生效
  - `ConfigStore`: 目录 (Debug -> `jj-git-debug`) / 原子写 / 以默认值为底合并解码; `RepositoryMonitor(paths:)` 监听目录, 比对字节忽略自写
- ⌘, 打开配置文件; `config.default.json` 列出全部可配置项及默认值
  - `CommandGroup(replacing: .appSettings)` -> `Workspace.openConfig()`
- 可配置: 编辑器 / 终端顺序 / Git 路径与超时 / Pull 方式 / 历史条数 / 差异上下文行数 / 刷新间隔
  - `AppConfig` + `normalized()` 越界收敛; `AppConfig.current` 锁保护快照供 `GitProcess` 后台读取

### Changed

- 首次启动自动导入旧版仓库列表; 配置文件写错时保留原文件并提示, 沿用上次有效内容
  - `UserDefaults` `repository-library` 仅在 `state.json` 缺失时导入, 原键保留; 解析失败 `stateValid=false` 停写

## [0.2.7] - 2026-10-04

### Fixed

- 差异区长行可左右滚动, 行背景铺满; 超过 1000 字符的行截断显示 (暂存不受影响)
  - 根因: 二维 `ScrollView` 内 `LazyVStack` 宽度被压到视口宽度, 长行被裁剪
  - `TextDiff.maxColumns` 解析时算出全部行最大列数 (U+1100 起双宽, tab 展开 4 空格), `DiffView` 据此固定内容宽度
  - `DiffLine.display` 截断 `displayLimit` (1000) 字符; 补丁仍用完整 `raw`

## [0.2.6] - 2026-10-04

### Changed

- 侧栏「工作树」改为单行显示: 目录名在左, 分支在右
  - `RepositorySidebar` 工作树行 `VStack` -> `HStack`, 分支名 `.truncationMode(.middle)`, 目录名 `layoutPriority(1)`

## [0.2.5] - 2026-10-04

### Added

- 侧栏「本地变更」显示未暂存 (橙) / 已暂存 (绿) 文件数, 切到其他页面也能看到
  - `RepositorySidebar.changeCounts`: 按 `FileChange.unstaged` / `.staged` 计数, 0 不显示

## [0.2.4] - 2026-10-04

### Fixed

- 「文稿」访问权限不再在每次升级后重新询问 (允许一次即可)
  - ad-hoc → Apple Development 签名; 脚本可选参数 `[DEVELOPMENT_TEAM]`

## [0.2.3] - 2026-10-04

### Added

- 本地变更: 空格键暂存 / 取消暂存选中文件; 列表标题新增「暂存选中」「全部暂存」图标按钮 (已暂存列表为取消)
  - `ChangeList`: `.onKeyPress(.space)` + `SectionHeading` 内 `chevron.down(.2)` / `chevron.up(.2)` 按钮; 移除列表底部多选暂存按钮

## [0.2.2] - 2026-10-04

### Fixed

- 应用图标在 Dock / 访达中出现白边与颜色偏淡, 现与设计一致 (正式版与 Debug 版)
  - 原因: 非缓存; `AppIcon` PNG 自带圆角 + 10% 透明边, macOS 27 二次处理出现振铃 / 偏色; 改为满版不透明方图, 圆角与阴影由系统生成

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
