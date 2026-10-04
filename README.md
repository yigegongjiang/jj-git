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

## 架构

- Swift 6 + SwiftUI (必要处 AppKit), 仅 macOS
- 原生 `jj-git.xcodeproj` + shared scheme `jj-git`; `xcodebuild` 编译 / 组装 `.app` / ad-hoc 签名
- macOS 14+; 无第三方依赖; Git 操作尚未实现
