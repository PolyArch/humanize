# F2: gen-plan 的 Claude-Codex 辩论与收敛（净变更分析）

## 范围

本文分析 `feat/gen-plan-convergence` 相对 `origin/main` 的净变更，使用 merge-base 的三点差异范围：

- 差异范围：`origin/main...feat/gen-plan-convergence`（three-dot diff）
- 关注点：`gen-plan` 新增的辩论 + 收敛规划流程，以及其在 RLCR 循环中的任务路由落地
- 覆盖的必选子特性：下文 (a) 到 (e)

净变更文件（11 个）：

- `docs/f2-gen-plan-convergence-analysis.md`
- `docs/f2-gen-plan-convergence-analysis_zh.md`
- `commands/gen-plan.md`
- `prompt-template/plan/gen-plan-template.md`
- `commands/start-rlcr-loop.md`
- `scripts/validate-gen-plan-io.sh`
- `scripts/setup-rlcr-loop.sh`
- `hooks/loop-codex-stop-hook.sh`
- `tests/test-gen-plan.sh`
- `tests/test-task-tag-routing.sh`
- `tests/run-all-tests.sh`

## 高层结果

F2 将 `gen-plan` 从“单次生成计划”升级为“结构化、可追溯的规划流水线”，其核心特点是：

1. 先由 Codex 对草案进行批判性评审，识别风险与缺失需求。
2. 再由 Claude 生成第一版候选计划。
3. 进入有上限的 Claude <-> Codex 收敛循环，修正不合理点并解决分歧。
4. 输出最终计划时，强制包含辩论可追溯信息、收敛日志，以及可用于 RLCR 执行的任务路由标签（`coding` / `analyze`）。
5. 默认只输出英文；当通过配置显式开启时，额外生成 `_zh` 中文译本文件。

## 子特性分析（a）到（e）

### (a) Claude-Codex 辩论流程（在最终定稿前解决分歧）

行为：

- Claude 先产出候选计划，然后由第二次 Codex 评审计划的合理性，明确列出：同意点、不同意点、必须修改项、可选改进项、以及仍需用户决策的未解决项。
- Claude 必须针对必须修改项修订计划；无法消除的对立观点要么转为用户决策，要么以“未解决/延后”的形式显式记录，禁止无声决策。

定义/约束位置：

- `commands/gen-plan.md`
  - Phase 5 “Iterative Convergence Loop (Claude <-> Second Codex)”定义第二次 Codex 评审的输出格式（`AGREE`、`DISAGREE`、`REQUIRED_CHANGES`、`OPTIONAL_IMPROVEMENTS`、`UNRESOLVED`）以及 Claude 的修订职责。
  - Phase 6 “Resolve Unresolved Claude/Codex Disagreements”要求把 `needs_user_decision` 项明确抛给用户，而不是静默选择。
  - Phase 7 “Final Plan Generation”要求最终计划必须包含“辩论可追溯性”和“收敛日志”。
- `prompt-template/plan/gen-plan-template.md`
  - `## Claude-Codex Deliberation`（Agreements + Resolved Disagreements）。
  - `## Convergence Log`（按轮次记录）。
  - `## Pending User Decisions`（保留未解决的对立观点）。
- `tests/test-gen-plan.sh`
  - 验证命令文档与模板中，以上辩论/收敛/待决策结构的存在性约束。

净效果：

- 计划输出必须包含辩论记录（双方观点、采纳/拒绝及理由、仍待决策项），从而让计划质量可审计、关键选择可追踪。

### (b) Codex 先行规划 + 收敛循环（先批判，再综合；直到一致）

行为：

- 在 Claude 生成候选计划之前，先调用 Codex 做第一轮结构化评审，使 Claude 的候选计划从“风险/缺失需求地图”出发，而不是仅基于草案。
- 收敛循环采用交替模式：Codex 合理性评审 -> Claude 修订 -> 收敛评估，直到收敛或触发上限（见 (d)）。

定义/约束位置：

- `commands/gen-plan.md`
  - Phase 3 “Codex First-Pass Analysis”先执行 `scripts/ask-codex.sh`，并强制结构化输出（“CORE_RISKS”、“MISSING_REQUIREMENTS”、“TECHNICAL_GAPS”、“ALTERNATIVE_DIRECTIONS”、“QUESTIONS_FOR_USER”、“CANDIDATE_CRITERIA”）。
  - Phase 4：Claude 候选计划 v1 明确基于 “Codex Analysis v1”。
  - Phase 5：第二次 Codex 合理性评审 + Claude 修订构成收敛循环。
  - Phase 7：生成计划中必须包含 `## Codex Team Workflow`，并定义 Batch 1/2/3（三批次）工作模型。
- `prompt-template/plan/gen-plan-template.md`
  - `## Codex Team Workflow` 固化“三批次”下游执行约定。
- `tests/test-gen-plan.sh`
  - 检查 Phase 3 出现在 Phase 4 之前，从结构上约束“Codex-first”的顺序。
  - 检查收敛阶段及模板关键章节的存在性。

净效果：

- 规划流水线被固定为“Codex 先批判 -> Claude 综合成案 -> Codex 挑战 -> Claude 修订”，并要求记录收敛状态与过程产物。

### (c) 任务标签路由（coding/analyze）用于计划任务；并带入 RLCR 提示词

行为：

- 计划中的每个任务必须且只能选择一个路由标签：
  - `coding`：由 Claude 直接执行
  - `analyze`：必须通过 `/humanize:ask-codex` 执行分析，然后把结果整合回计划/工作流
- RLCR 工具链（目标追踪器 + 各轮提示词）被更新，使路由信息持续可见，并在后续轮次不断提醒。

定义/约束位置：

计划生成侧：

- `commands/gen-plan.md`
  - Phase 7 “Final Plan Generation”中的“Task Tag Requirement”要求每个任务必须标注 `coding` 或 `analyze`，且不允许其他值。
  - “Task Breakdown”表格定义中包含 Tag 列并描述路由含义。
- `prompt-template/plan/gen-plan-template.md`
  - `## Task Breakdown` 表格包含 Tag 列（`coding` / `analyze`），并明确 `analyze` 通过 `/humanize:ask-codex` 执行。

RLCR 执行侧：

- `scripts/setup-rlcr-loop.sh`
  - 写入目标追踪器（goal-tracker）时，在 “Active Tasks” 表中增加 `Tag` 与 `Owner` 列。
  - 在 `round-0-prompt.md` 中注入 `## Task Tag Routing (MUST FOLLOW)`，明确路由契约：
    - `coding`：Claude 直接执行
    - `analyze`：Claude 必须通过 `/humanize:ask-codex` 执行并整合结果
    - goal-tracker 中的 Tag/Owner 必须与实际执行保持一致
- `hooks/loop-codex-stop-hook.sh`
  - 新增 `append_task_tag_routing_note()` 并在生成后续轮次提示词时调用，确保在 Codex 反馈后仍保留路由提醒。
- `commands/start-rlcr-loop.md`
  - 将任务标签路由作为 RLCR 执行的一等规则进行说明，并与 goal-tracker 的 Tag/Owner 字段联动。

测试：

- `tests/test-task-tag-routing.sh`
  - 断言 `round-0-prompt.md` 包含路由章节标题（`## Task Tag Routing (MUST FOLLOW)`）。
  - 断言 `round-0-prompt.md` 提及 `/humanize:ask-codex`。
  - 断言 goal-tracker “Active Tasks” 表头包含 `Tag` / `Owner` 列。
  - 断言通过 stop hook 生成的后续提示词仍包含路由提醒章节。
- `tests/run-all-tests.sh`
  - 将 `test-task-tag-routing.sh` 纳入全量并行测试套件。

净效果：

- “任务由谁做/怎么做”从隐含约定升级为计划契约，并被 RLCR 工具链持续强化，减少多轮迭代中的执行歧义与路由漂移。

### (d) 收敛循环最多 3 轮（防止无限辩论）

行为：

- Claude <-> Codex 的收敛循环最多执行 3 轮。
- 若达到上限仍存在分歧，必须将对立观点显式转入用户决策或未解决项记录，禁止无限循环。

定义/约束位置：

- `commands/gen-plan.md`
  - Phase 5 “Loop Termination Rules”包含 “Maximum 3 rounds reached”。
  - 明确设置 `PLAN_CONVERGENCE_STATUS` 为 `converged` 或 `partially_converged`。
- `tests/test-gen-plan.sh`
  - 检查 `commands/gen-plan.md` 中存在 “Maximum 3 rounds reached” 终止规则。

净效果：

- 规划不会陷入无限往复；未能收敛的对立观点被强制显式化并进入待决策或未解决记录。

### (e) 默认英文输出 + 可选 `_zh` 译本输出

行为：

- `gen-plan` 默认只生成英文计划文件。
- 仅当显式启用时才生成中文译本伴随文件：
  - 配置：`.humanize/config.json` 中 `"chinese_plan": true`
  - 输出：在扩展名之前插入 `_zh`（例如 `plan.md` -> `plan_zh.md`）
- `_zh` 文件为英文计划的翻译阅读版本：标识符保持不变，且原始草案段落不再二次翻译。

定义/约束位置：

- `commands/gen-plan.md`
  - Phase 0.5 读取 `.humanize/config.json` 并解析 `chinese_plan`；若 JSON 格式错误仅警告并回退为禁用。
  - Phase 8 Step 4 定义 `_zh` 文件命名算法与内容约束（标识符不变；不新增信息；原始草案保持原样）。
  - 默认 `CHINESE_PLAN_ENABLED=false` 时不生成 `_zh` 文件。
- `prompt-template/plan/gen-plan-template.md`
  - `## Output File Convention` 与 “Chinese-Only Variant (`_zh` file)”章节描述相同启用与命名规则，并明确“缺失配置不是错误”。
- `tests/test-gen-plan.sh`
  - 对 `commands/gen-plan.md` 做“无 CJK/emoji”校验，保证默认规划指令集为英文，从而与“默认英文输出”的预期一致。

净效果：

- 主产物保持英文；需要中文阅读版本的团队可通过配置选择性开启 `_zh` 输出，同时保持标识符稳定、避免歧义。

## 按文件的净变更摘要（改了什么）

- `commands/gen-plan.md`
  - 新增多阶段规划流程：读取 `_zh` 配置、IO 校验、相关性检查、Codex-first 分析、Claude 候选计划、有限轮次收敛、显式分歧处理、以及最终计划结构约束。
  - 增加可选 `--auto-start-rlcr-if-converged` 行为与触发门槛。
- `prompt-template/plan/gen-plan-template.md`
  - 扩展计划模板：任务路由标签、三批次 Codex 工作流、辩论可追溯章节、收敛日志、待用户决策区、以及 `_zh` 输出约定。
- `commands/start-rlcr-loop.md`
  - 将任务标签路由作为 RLCR 的显式执行规则，并与 goal-tracker 约束联动。
- `scripts/validate-gen-plan-io.sh`
  - 通过 `CLAUDE_PLUGIN_ROOT`（并带脚本相对路径回退）定位模板文件；若缺失则以退出码 `7` 失败；并将模板复制到输出路径后追加原始草案内容。
- `scripts/setup-rlcr-loop.sh`
  - goal-tracker 的 “Active Tasks” 表新增 `Tag` 与 `Owner` 列。
  - 在 Round 0 提示词中注入强制路由章节。
- `hooks/loop-codex-stop-hook.sh`
  - 在后续轮次提示词中追加任务标签路由提醒，使路由指令跨轮次持续存在。
- `tests/test-gen-plan.sh`
  - 新增/强化：Codex-first 顺序、收敛阶段存在、3 轮上限、模板关键章节存在性，以及英文内容约束等验证。
- `tests/test-task-tag-routing.sh`
  - 新增：Round 0 提示词/goal-tracker/stop hook 的路由信息可见性与持久性测试。
- `tests/run-all-tests.sh`
  - 将新增测试脚本纳入并行测试总集。

## 按提交的分解表（F2 的 9 个 cherry-pick）

说明：

- `5156a05` 与 `002308a` 为回滚对（净效果为 0）。
- 开发过程中部分提交触及版本文件（`.claude-plugin/plugin.json`、`.claude-plugin/marketplace.json`、`README.md`），但该分支在净变更范围内不包含版本改动（见“版本策略说明”）。

| SHA | 主题 | 该提交记录的改动文件 |
|---|---|---|
| c283a92 | feat: add claude-codex debate flow to gen-plan | `.claude-plugin/marketplace.json`<br>`.claude-plugin/plugin.json`<br>`README.md`<br>`commands/gen-plan.md`<br>`prompt-template/plan/gen-plan-template.md`<br>`tests/test-gen-plan.sh` |
| 9c0eef7 | feat: make gen-plan codex-first with convergence loop | `.claude-plugin/marketplace.json`<br>`.claude-plugin/plugin.json`<br>`README.md`<br>`commands/gen-plan.md`<br>`prompt-template/plan/gen-plan-template.md`<br>`tests/test-gen-plan.sh` |
| 5156a05 | Add plan-type routing for Claude vs Codex execution | `README.md`<br>`commands/start-rlcr-loop.md`<br>`hooks/lib/loop-common.sh`<br>`hooks/loop-codex-stop-hook.sh`<br>`scripts/setup-rlcr-loop.sh`<br>`tests/run-all-tests.sh`<br>`tests/test-plan-type-routing.sh` |
| 002308a | Revert "Add plan-type routing for Claude vs Codex execution" | `README.md`<br>`commands/start-rlcr-loop.md`<br>`hooks/lib/loop-common.sh`<br>`hooks/loop-codex-stop-hook.sh`<br>`scripts/setup-rlcr-loop.sh`<br>`tests/run-all-tests.sh`<br>`tests/test-plan-type-routing.sh` |
| 8ba3a57 | Implement task-tag routing for coding/analyze execution | `README.md`<br>`commands/gen-plan.md`<br>`commands/start-rlcr-loop.md`<br>`hooks/loop-codex-stop-hook.sh`<br>`prompt-template/plan/gen-plan-template.md`<br>`scripts/setup-rlcr-loop.sh`<br>`tests/run-all-tests.sh`<br>`tests/test-gen-plan.sh`<br>`tests/test-task-tag-routing.sh` |
| 437567b | Enhance gen-plan with ultrathink and converged auto-start | `README.md`<br>`commands/gen-plan.md`<br>`prompt-template/plan/gen-plan-template.md`<br>`scripts/validate-gen-plan-io.sh`<br>`tests/test-gen-plan.sh` |
| 3c8caf5 | feat: cap gen-plan convergence loop to 3 rounds | `.claude-plugin/marketplace.json`<br>`.claude-plugin/plugin.json`<br>`README.md`<br>`commands/gen-plan.md`<br>`tests/test-gen-plan.sh` |
| 4a57429 | feat: add _zh bilingual file output option to gen-plan pipeline (task8) | `commands/gen-plan.md`<br>`prompt-template/plan/gen-plan-template.md` |
| 821f225 | fix: switch gen-plan default to English-only with optional _zh variant via config | `.claude-plugin/marketplace.json`<br>`.claude-plugin/plugin.json`<br>`README.md`<br>`commands/gen-plan.md`<br>`prompt-template/plan/gen-plan-template.md`<br>`tests/test-gen-plan.sh` |

## 版本策略说明（延后对齐）

根据任务上下文中引用的 runbook 策略（4.5），版本号对齐由上游维护者决定，本分支特意不在净变更中携带版本 bump。

在当前仓库快照中：

- 净变更范围 `origin/main...feat/gen-plan-convergence` 不包含任何版本文件的改动。
- 版本文件保持在 merge-base 的值（`.claude-plugin/plugin.json` 与 `.claude-plugin/marketplace.json` 为 1.12.1），尽管开发过程中的部分提交曾触及这些文件。

## `_zh` 输出说明

当 `.humanize/config.json` 中设置 `"chinese_plan": true` 时，支持额外生成 `_zh` 中文译本文件；默认情况下只输出英文主文件，不生成 `_zh` 文件。
