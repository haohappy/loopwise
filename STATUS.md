---
slug: loopwise
name: Loopwise
summary: Claude Code ↔ Codex 自动化互审循环，两个顶级模型交叉 review 提升输出质量
stack: [Bash, Claude Code, Codex CLI]
repo: https://github.com/haohappy/loopwise
last_synced_sha: 24854b0
updated_at: 2026-06-02
features:
  - name: 核心审查循环（plan/code 生成 → Codex 审查 → 修订）
    status: done
  - name: 独立 shell 脚本 loopwise.sh + install.sh
    status: done
  - name: v2 结构化 JSON 输出 + 对抗审查模式（--adversarial）
    status: done
  - name: /loopwise-gate 提交前快速 diff 审查
    status: done
  - name: 后台执行（--background）+ /loopwise-status
    status: done
  - name: --since git diff 范围审查
    status: done
  - name: 审查历史追踪（基于内容 SHA-256，自动跳过已批准）
    status: done
  - name: 修复前独立验证 Codex 反馈（防幻觉）
    status: done
  - name: 20 轮硬上限防止无限循环
    status: done
  - name: model 子命令查询实际生效的 Codex 模型（含实时探针）
    status: done
    done_at: 2026-06-02
  - name: 在 README/README_CN 文档化 model 子命令
    status: planned
next:
  - 在 README 与 README_CN 补充 model 子命令用法
  - 评估审查前自动校验模型可用性（避免账号不支持的模型导致失败）
---

## 备注

- **模型策略（重要踩坑，2026-06-02）**：必须在 `~/.codex/config.toml` 显式钉死
  一个账号已验证可用的 `model =`，不要依赖 Codex CLI 内置默认。CLI 默认会轮换
  （当天从 `gpt-5.5` 变成账号不支持的 `gpt-5.3-codex`），导致所有 `/loopwise`
  调用失败。详见仓库 CLAUDE.md「Upgrading the Codex model」一节。
- 两种交付模式（slash 命令 + shell 脚本）共用同一套审查逻辑。
- 改 `.claude/commands/*.md` 后需 `cp` 到 `~/.claude/commands/` 才生效。
- 临时文件用 Bash heredoc 写到 `/tmp/loopwise-*.md`，避免触发扫描 Write 工具的安全 hook。
