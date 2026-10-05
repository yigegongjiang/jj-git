```When Editing
本文档作用: 面向开发者的发版记录; CHANGELOG.md 的超集, 1:1 镜像 + 技术变更子项
遵循 AGENTS.md 文档编写规范
- 每条主项 = CHANGELOG.md 对应条目 (原文), 下方缩进子项承载技术变更
- 子项 MAY 写路径 / 函数 / 机制; ≤ 1 行
```

# Changelog (developer, follow [CHANGELOG.md](./CHANGELOG.md))

## [0.4.44] - 2026-10-05

### Fixed

- 全部差异 / 大文件差异读取完成后立即显示，不再因长行换行计算长时间空白
  - `DiffTableCoordinator` 换行行高: 首屏同步实测, 其余 `estimatedHeight` 占位 + 8ms 分片补算, 首个可见行锚定防跳动

## [0.4.43] - 2026-10-05

### Changed

- 「未暂存 / 已暂存 / 变更文件」标题旁显示全部差异图标，悬停高亮；正在显示全部差异时标题高亮
  - `SectionHeading` 新增 `titleActive`; `OverviewTitle` = `rectangle.stack` 图标 + `onHover` 底色, 激活用 `Theme.accent` + `.fill` 图标

## [0.4.42] - 2026-10-05

### Changed

- 选中文件后只显示该文件的差异；全部差异仅在首次进入或点击「未暂存 / 已暂存 / 变更文件」标题时显示
  - `RepositorySession.diffOverview` 区分模式; `refreshChangesDiff` 单文件模式只刷新选中文件, 文件移出列表时回到全部差异; 删除 `diffScrollID` / 滚动定位
  - 全部差异读取失败回退单文件时保留当前选中文件; 历史全部差异不选中文件, `showCommitOverview` 绑定「变更文件」标题
- 空格暂存 / 取消暂存选中文件后，自动选中并预览下一项（末尾时选中上一项）
  - `ChangeList.transfer` 在 `perform` 后设置 `selection`, 仅当选中项全部被转移时跳转

## [0.4.41] - 2026-10-05

### Changed

- 显示 / 隐藏侧边栏快捷键改为 ⇧⌘S
  - `WorkspaceCommands` 侧栏菜单项 `.keyboardShortcut("s", modifiers: [.command, .shift])`; 提示 / 快捷键列表同步

## [0.4.40] - 2026-10-05

### Changed

- 打开或切换到仓库时，若没有本地变更，自动显示「提交历史」
  - `RepositorySession.activate()` 置 `sectionAutoPending`; 首次 `refreshSnapshot()` 后 `changes` 为空且 `graph` 非空 -> `changeSection(.history)`; 手动切换即取消

## [0.4.39] - 2026-10-05

### Changed

- 跟随版本同步发布
  - `.github/workflows/release.yml`: 构建 / 校验 / 打包 / 发布逻辑内联为 steps; 删除 `scripts/package.sh` + `scripts/publish-release.sh`

## [0.4.38] - 2026-10-05

### Added

- GitHub Release 提供 macOS 安装包（Apple Silicon + Intel 通用，未公证，安装说明见发布页）
  - `.github/workflows/release.yml`: tag push -> `scripts/publish-release.sh` 校验 tag = 版本且在 master 上 -> `scripts/package.sh` 构建 universal ad-hoc zip -> `gh release create`

## [0.4.37] - 2026-10-05

### Fixed

- 「性能」面板的 CPU 读数不再计入点击按钮时激活应用引发的刷新与重绘，反映面板打开前的实际占用
  - `PerformanceView.settle()`: 等 `refreshing` 结束 + 连续 2 个 100ms 片段 < 5%（上限 3 秒）再开 1 秒 CPU 窗口

## [0.4.36] - 2026-10-05

### Added

- App 菜单支持安装 `jj-git` 命令，终端执行 `jj-git [path]` 打开仓库；默认当前目录，复用已运行的应用
  - `CLIIntegration` 顺序处理打开事件；`~/.local/bin/jj-git` 链接到 App 内启动脚本，恢复标签仅执行一次

## [0.4.35] - 2026-10-05

### Added

- 侧栏仓库与分组支持拖拽排序、插入位置提示和跨组移动；右键上移 / 下移，排序菜单恢复名称顺序，重启保留调整
  - `SidebarDragDrop` 私有拖拽载荷 + 窗口令牌校验；`Workspace+Library` 按数组排序，`sidebarOrderCustomized` 缺失默认 false

## [0.4.34] - 2026-10-05

### Fixed

- 修复仓库颜色仅作用于文本的问题，文件夹图标同步显示所选颜色
  - `LibraryView.repositoryIcon` 独立绘制图标，叠加透明 `Menu` 点击区域，避免原生菜单 label 覆盖图标颜色

## [0.4.33] - 2026-10-05

### Added

- 仓库侧栏支持 7 种颜色标记，点击文件夹图标或右键设置，重启后保留；可恢复默认颜色
  - `SavedRepository.color` 写入 `state.json`；`LibraryView` 复用颜色菜单，`Workspace+Library.swift` 保存列表操作，缺失 / 未知颜色使用默认

## [0.4.32] - 2026-10-05

### Added

- `⌘⇧P` 检索侧栏全部仓库，支持名称 / 路径筛选、方向键选择与回车打开；保留 `⌘P` 最近仓库
  - `RepositoryPickerView` 复用检索交互；`sidebarRepositories` 按名称排序、包含当前仓库、不限制数量；单一 sheet 状态区分 recent / all

### Changed

- Pull 快捷键改为 `⌘⌥P`

## [0.4.31] - 2026-10-05

### Changed

- 项目介绍突出响应速度、简洁稳定与轻量运行，并增加提交历史和本地变更界面展示
  - `README.md` 聚焦产品展示；`docs/screenshots/` 保存演示界面，操作与架构说明迁至 `docs/reference.md`

## [0.4.30] - 2026-10-05

### Added

- 弹窗支持点击背景区域取消，保留 Esc 取消；取消时不会触发背景操作
  - `SheetBackgroundDismiss` 统一 sheet / confirmationDialog 取消；限定所属窗口、保护嵌套弹窗、拦截点击并随呈现释放监听

## [0.4.29] - 2026-10-05

### Changed

- 配置支持注释，全部配置项附中文说明、单位和范围；界面保存设置保留自定义注释
  - `config.jsonc` / `config.default.jsonc`；去除注释后 Foundation JSON 解码（支持尾逗号），按 token 定位变更值，保留注释 / 未知键，状态仍为 JSON

## [0.4.28] - 2026-10-05

### Added

- 提交历史「显示列」增加「精简时间」开关，将 `2026-10-01 12:34` 显示为 `261001.1234`；时间列随内容缩窄，重启后保留选择
  - `history.compactTime` 默认 false；缓存本地时区 POSIX / Gregorian `yyMMdd.HHmm` formatter，复用配置保存与 `fixedSize` 布局，悬停保留完整时间

## [0.4.27] - 2026-10-05

### Changed

- 提交历史使用 Dracula 深浅交替行背景，便于区分提交；选中行保留高亮
  - `HistoryView` 按行序号交替使用 `Theme.window` 与 35% `Theme.titleBar` 叠色；选中行清除自定义背景，保持提交 SHA 身份

## [0.4.26] - 2026-10-05

### Added

- 提交历史增加「显示列」菜单，独立切换分支 / 标签、作者、时间和 SHA，重启后保留
  - `AppConfig.History` 新增 `showReferences/showAuthor/showTime/showHash`；`Workspace.setHistoryColumn` 写入 `config.json` 并同步运行时配置

### Changed

- 提交标题统一首列对齐，分支 / 标签移到第二列；窄窗口将作者、时间和 SHA 放到下一行
  - `HistoryView` 固定引用列 190 pt，`ViewThatFits` 切换单行 / 双行布局；标题起点一致

### Fixed

- 历史时间完整显示为本地时区的 `yyyy-MM-dd HH:mm`，不再截断
  - 缓存 POSIX `DateFormatter`、Gregorian calendar、本地时区；时间与 SHA 使用等宽字体 + `fixedSize`，悬停显示完整信息

## [0.4.25] - 2026-10-05

### Changed

- 提交历史的分支 / 标签独立显示并自动折行，长名称完整展示；仅标签溢出的提交行增高
  - `HistoryView`：`CommitRefLayout` 按 190 pt 排列标签，长名称内部换行；图轨道覆盖整行，按实际高度绘制
- 标签移除 `tag:` 前缀，以绿色区分标签、紫色区分分支
  - `HistoryView`：按 `tag: ` 判断引用类型，展示时去除前缀，悬停保留完整引用信息

## [0.4.24] - 2026-10-05

### Fixed

- 仓库位于频繁写入的目录（如主目录）时，后台持续刷新导致 CPU 居高：变更合并为每秒最多刷新一次
  - `RepositoryMonitor` FSEvents latency 0.2 → 1.0 秒；主目录仓库实测 30 秒内 Git 命令 2430 → 351，App CPU 29% → 7% (Debug)
- 「性能」面板读数不再包含面板自身的开销，与未打开面板时一致
  - `ContentView` 弹窗前采样内存传入 `PerformanceView`；CPU 窗口延后 0.5 秒避开弹窗动画，结果在窗口结束后一次性写入界面

## [0.4.23] - 2026-10-05

### Changed

- 差异区改用原生列表渲染：快速滚动、超大差异（数十万行）时保持流畅
  - `DiffTableView`（`NSViewRepresentable` + `NSTableView`）替代 SwiftUI `List`；行高按宽度预算查表，仅换行的超长 / 非 ASCII 行用同一 cell 实测
  - `DiffTableCells`：行底色 / 勾选框 / 行号直接绘制，正文 `NSTextField` 可选中；手动 frame，无 Auto Layout；`Theme.ns*` 纯 sRGB 颜色
- 窗口未激活时，点击差异行勾选框直接生效
  - `DiffLineCell.acceptsFirstMouse` 返回 true

## [0.4.22] - 2026-10-04

### Changed

- 「性能」面板改为显示启动以来本应用与 Git 命令的累计 CPU 时间，替代几乎总为 0 的 Git 瞬时占用
  - `PerformanceView` 直接展示 `ProcessSample.cpuSeconds` / `childCPUSeconds`；`cpuPercent` 去掉子进程分支
- 「性能」面板改为居中弹窗 (Esc 关闭)，打开时内存读数不再被弹出动画抬高
  - popover 弹出时 footprint 瞬时 +130 MB (约 1.5 秒，与内容无关)，sheet 无此现象；`ContentView` 改 `.sheet`

## [0.4.21] - 2026-10-04

### Added

- 顶部「重启应用」右侧新增「性能」面板：查看 CPU、内存 (含峰值) 与各标签内存估算；点击时测量一次，不在后台持续采样
  - `ProcessSample`：`proc_pid_rusage(RUSAGE_INFO_V4)` 取 `ri_phys_footprint` / 峰值 / 常驻，`getrusage(SELF/CHILDREN)` 两次采样差值算 CPU，`proc_pidinfo` 取线程数
  - `SessionSnapshot.usage()`：主线程拷贝 session 数据，`Task.detached` 估算字符串字节 + 元素 stride；单文件差异与总览共享时不重复计
  - `PerformanceView` popover：`.task(id:)` 打开 / 重新测量时执行一次，关闭即取消

## [0.4.20] - 2026-10-04

### Fixed

- 本地变更「全部差异」上下滚动卡顿：文件多 / 差异大时滚动保持顺畅
  - `DiffView`：文件头 / 块头 / 行扁平化进单个 `List`（`NSTableView` 复用行），行数组按差异内容缓存；替代嵌套 `LazyVStack`
  - `SplitPane.sizeThatFits` 直接返回提议尺寸，消除滚动时整棵子树的 `fittingSize` Auto Layout 测量

## [0.4.19] - 2026-10-04

### Added

- 新增 `⌘P` 最近仓库列表：按使用频率与时间排序，默认 15 条 (`tabs.recentCount` 可调)；输入筛选，↑↓ 选择，回车打开
  - `SavedRepository.usage/usedAt` 指数衰减热度 (半衰期 3 天)，`Workspace.select` 切换时 +1；`recentRepositories` 排除当前 / 失效仓库，未使用的按标签 / 列表顺序补足；`RecentRepositoriesView` sheet

## [0.4.18] - 2026-10-04

### Added

- 新增可搜索的快捷键查看面板：顶部键盘按钮 / Help 菜单 / `⇧⌘/` 打开
  - `KeyboardShortcutsView` 静态目录 + `Workspace.showingKeyboardShortcuts` 驱动 `ContentView` sheet；`CommandGroup(replacing: .help)`

## [0.4.17] - 2026-10-04

### Added

- 未挂载标签用灰紫色文字标记，悬停提示点击重新加载
  - `RepositoryTabs` 按 session 是否存在切换 `Theme.badge` / `Theme.foreground` 与悬停说明

## [0.4.16] - 2026-10-04

### Added

- 未激活标签默认 3 分钟后释放内存，保留位置，点击重新加载；等待进行中的 Git 操作完成；保留时间可配置，提交信息草稿随释放清除
  - `tabs.idleUnloadSeconds` 默认 180，范围 1–86400 秒；切回取消释放；释放取消读取任务并移除 session；关闭当前标签时重建相邻已释放标签

## [0.4.15] - 2026-10-04

### Fixed

- 本地变更默认展示未暂存全部差异；点击已暂存 / 未暂存标题或列表空白切换分区
  - `DiffTarget.changes` 按分区预处理；`selectChanges` 重试全量预览，原生列表空白识别与文件行隔离，预处理期间文件选择保留批次

## [0.4.14] - 2026-10-04

### Added

- 单按 Tab 在「提交历史」/「本地变更」间切换; 提交信息与弹窗输入框内 Tab 行为不变
  - `SectionTabKey` 本地 keyDown 监听: 仅主窗口无 sheet / 焦点非可编辑 `NSTextView` / 无修饰键时生效

## [0.4.13] - 2026-10-04

### Changed

- 安装完成后自动打开应用并保持运行
  - `scripts/install-local.sh` 前台启动，验证成功后取消退出清理；启动失败仍退出应用

## [0.4.12] - 2026-10-04

### Changed

- 顶部提醒统一图标、间距与按钮布局，保留错误关闭和失效仓库批量清理
  - `WarningBanner<Content, Actions>` 通过 `ViewBuilder` 组合内容与操作，统一所有提醒样式；移除 `ErrorBanner` / `MissingRepositoriesBanner`

## [0.4.11] - 2026-10-04

### Added

- 顶部与应用菜单增加「重启应用」，重启后读取新配置并恢复仓库标签
  - 按当前产物路径重启，保留 Debug 标识；操作 / 扫描 / 打开仓库 / 提交草稿期间禁用

### Changed

- 移除配置与状态文件热加载，外部修改需重启应用生效
  - 删除配置监听、状态同步与字体缓存失效逻辑；选择编辑器保存时读取磁盘配置，避免覆盖待生效修改

## [0.4.10] - 2026-10-04

### Fixed

- 失效仓库汇总展示，支持逐项或全部移除；检查包含未打开的仓库，无需反复重启
  - `Workspace.checkMissingRepositories` 后台检查保存仓库与标签，启动 / 前台 / 状态热加载触发；清理前复查已恢复路径

## [0.4.9] - 2026-10-04

### Added

- 全文件差异预处理超时可在配置中调整, 默认 1 秒, 修改即时生效
  - `diff.previewTimeoutMilliseconds` 默认 1000, 范围 100–30000 ms; 两类差异共用, 下一次预处理读取新值

## [0.4.8] - 2026-10-04

### Added

- 路径不存在的仓库打开失败时，可在提示旁一键从列表移除并关闭标签
  - `Workspace.open` 仅明确的路径不存在显示清理按钮；复用 `remove` 持久化，权限 / Git 错误保留记录

## [0.4.7] - 2026-10-04

### Added

- 本地变更与提交历史默认连续展示全部文件差异; 点击文件跳转, 1 秒预处理超时回退首文件
  - `RepositoryQuery.allDiffs`: 统一读取 / 解析预算 + 取消 Git; 累计输出上限, `LazyVStack` 按需绘制; 行选择按文件与暂存状态隔离

## [0.4.6] - 2026-10-04

### Fixed

- 命令记录写入不再触发仓库刷新; 失败信息中的 URL 凭据同样脱敏
  - `RepositoryMonitor(location:)` 同样忽略 `GitCommandLog.directory` (Debug `debug-config/logs` 位于工程工作区内); 错误列走 `redact`

## [0.4.5] - 2026-10-04

### Added

- 按仓库记录每条 Git 命令及耗时, 便于事后回溯与性能排查; 可在配置中关闭
  - `GitCommandLog`: `GitProcess.run` 统一记录 -> `logs/<目录名>-<哈希>.log` (TSV, 串行队列异步追加, 超 `commandLog.maxFileMiB` 轮转 `.log.1`); `RepositoryMonitor` 新增 `ignoring`, 配置监听忽略 `logs/`

## [0.4.4] - 2026-10-04

### Changed

- 差异行高更紧凑, 一屏显示更多行; 行距可在 `config.json` `appearance.diffLineSpacing` 调整, 即时生效
  - `Typography.diffLineHeight` = 代码字体 ascender - descender + leading 取整 + `diffLineSpacing` (默认 2, 0–20); 取代 `editorFontSize × 1.75` 与换行模式固定 3pt 内边距
  - 实测 12pt: 行距 17pt (原 21pt); 换行 / 不换行 / 带勾选行一致; 改配置热加载生效

## [0.4.3] - 2026-10-04

### Changed

- 跟随版本同步发布
  - Debug 数据目录改为 `.app` 同级 `debug-config/` (不再用 `~/.config/jj-git-debug` / `JJGIT_CONFIG_DIR`); `debug.sh` 首次启动打开 `jj-git-test-project`

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
