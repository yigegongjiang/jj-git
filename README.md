```When Editing
本文档作用: 工程总览 (价值主张 / 使用 / 架构 / 结构); MUST NOT 写发布流程 (→ workflow.md) / LLM 约束 (→ AGENTS.md)
遵循 AGENTS.md 文档编写规范
- 章节按需增删, 只留项目真有的; 首行一行价值主张, MUST NOT 带 LLM 提示
- 短并列项用表格; 可执行步骤 fenced + `#` 注释同行
- NEVER 写「开发」段 (VibeCoding 不向人类解释 dev 命令)
```

# jj-git

Swift 实现的 macOS Git GUI 客户端, 按个人习惯定制; 简单 + 高效 + 易用.

## 核心要求（MUST）

- 简洁实用高效率：个人自用，仅有核心高频操作功能；界面清晰、布局紧凑，最大限度利用屏幕空间，减少间距与留白；实用优先，美观不作为目标。
- 稳定性：长期运行稳定，避免崩溃、资源泄漏及随运行时间增长的性能劣化。
- 快速同步：文件变化后尽快更新界面的 Git 变更状态；可接受延迟 1–2 秒，MUST NOT 达到 10 秒或分钟级。
- Worktree：支持 Git Worktree，各 Worktree 的状态展示与操作准确。
- App 性能：启动、界面交互及按钮响应快速；耗时操作 MUST NOT 阻塞 UI 或造成长时间等待。
- 不要过度设计

## 使用

安装位置: `/Applications/jj-git.app`;

- 仓库: 打开 ⌘O / 扫描导入 ⇧⌘O / 分组 (折叠, 右键移动) / 多标签 ⌘W ⌘⌥←→ ⌃⇥; 标签页重启恢复
- 窗口: 无标题栏, 标签与窗口按钮同一行 (空白处拖动 / 双击缩放); 侧栏显示 / 隐藏 ⌃⌘S; 分割线均可拖动调整, 位置记忆
- 历史 ⌘1: 提交图 + 详情 + 文件差异; 右键复制 SHA / 新建分支 / 新建标签
- 差异: 默认自动换行, 标题「自动换行」取消后横向滚动 (全局记忆); 单行超 1000 字符截断显示
- 本地变更 ⌘2: 双击 / 回车 / 空格暂存·取消; 标题按钮暂存选中 / 全部; 按块 / 按行 (⇧点击连选) 暂存·取消·放弃; 加入 `.gitignore`
- 提交: ⌘↩ 提交 / ⌘⌥↩ 提交并推送; Amend (推送时 force-with-lease)
- 分支 / 标签 / 远程: 侧栏 + 按钮 (新建分支 ⌘B) 与右键菜单; 标签默认附注并推送; 分区标题点击折叠 (默认展开, 记忆)
- 同步: Fetch ⇧⌘F / Pull (默认 rebase + autostash) ⇧⌘P / Push ⇧⌘U / 强制推送
- 工具: 终端 ⇧⌘T (默认 iTerm 优先) / 编辑器 ⇧⌘E / 刷新 ⌘R
- 配置: ⌘, 打开 `~/.config/jj-git/config.json`; 外部修改即时生效
- 外观: 固定 Dracula 深色主题; 界面 / 等宽字体与字号由 `config.json` `appearance` 设定; 差异行距 `appearance.diffLineSpacing` (自然行高外额外 pt, 默认 2, 0–20)
- 首次启动: macOS 询问「文稿」访问权限, 允许后才能读取其中的仓库

## 架构

- Swift 6 + SwiftUI (必要处 AppKit), 仅 macOS 14+; 无第三方依赖
- 主题: `Theme` (Dracula 色值) + `Typography` (字体缓存, 随配置热加载); 每个 `NSHostingView` 根 (分栏 / 弹窗) 调 `.themed()`, 环境值不跨宿主
- 原生 `jj-git.xcodeproj` + shared scheme `jj-git`; `xcodebuild` 编译 / 组装 `.app` / 签名 (默认 ad-hoc, 传 Team 用 Apple Development)
- Git: 调用 Git CLI (`/opt/homebrew/bin/git` 优先), 每次独立进程, 不经 shell; 超时 / 取消终止进程; 输出上限 16 MiB
- 刷新: FSEvents 监听工作目录 + Git 目录 + 共享 Git 目录 (worktree); App 前台时兜底轮询 (默认 5 秒); 回到前台刷新
- 环境: 启动时读取登录 shell 的 PATH, 供 Git hooks 使用 node / bun 等工具
- 按行暂存: 基于当前差异生成补丁 `git apply --cached`; 差异已变化则拒绝执行
- 持久化: `~/.config/jj-git/` (Debug: `.app` 同级 `debug-config/`, 每份构建独立) JSON; FSEvents 监听目录热加载; 解析失败沿用上次内容且停写
  - `config.json`: 设置 (字体 / 差异行距 / 编辑器 / 终端 / Git 路径·超时·输出上限 / Pull 方式 / 历史条数 / 差异上下文 / 轮询间隔); 缺失键取默认, 越界收敛
  - `state.json`: 仓库列表 / 分组 / 标签页 / 侧栏 / 窗口位置 (`window`) / 分栏尺寸 (`splits`) / 侧栏折叠分区 (`collapsedSections`); 外部修改同步开关标签
  - `config.default.json`: 全部键默认值, 启动时刷新, 仅供查阅
- MUST NOT 主动使用 `UserDefaults`: 窗口 / 分栏的 AppKit 自动保存已关闭, 改写 `state.json`

## 结构

<!-- prettier-ignore -->
| 目录 | 职责 |
| --- | --- |
| `Sources/jj-git/Commands` | Git 进程执行 / 只读查询 / 写操作 |
| `Sources/jj-git/Models` | 状态 / 引用 / 差异与补丁 / 提交图 / 仓库库模型 |
| `Sources/jj-git/Native` | FSEvents 监听 / 登录 shell 环境 |
| `Sources/jj-git/ViewModels` | `Workspace` (仓库库 + 标签) / `RepositorySession` (单仓库状态与操作) |
| `Sources/jj-git/Views` | 主窗口各区域 / 弹窗 / 菜单快捷键 |
