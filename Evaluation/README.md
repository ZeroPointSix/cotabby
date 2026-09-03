# Cotabby P0 离线评测环境

本目录把补全质量口径变成可版本化、可重复运行的测试入口。它不接入生产采集，也不改变 Focus、引擎路由或 `SuggestionCoordinator`。

## 最短命令

在仓库根目录执行：

```bash
swift scripts/eval/replay_eval.swift Evaluation/fixtures/replay-sample.jsonl build/eval/replay-report.json
```

命令会校验数据契约和场景覆盖，计算漏斗、ECCR、AR、机会成功率、覆盖率、stale、离线正确性及延迟，并把不含原文的聚合报告写入 `build/eval/replay-report.json`。退出码非 0 表示输入或覆盖要求不合格。

现有真实模型评测仍可按 upstream 方式运行：

```bash
xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' -only-testing:CotabbyTests/LlamaSuggestionEvalTests SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData
```

当前 `CotabbyTests/Fixtures/llama-eval-cases.json` 有 117 个种子案例；新 replay 层补充统一漏斗和线上可对齐指标，不替代 `LlamaEvalScoring.swift` 的模型质量测试。

## 两层环境

1. **确定性契约层（每个 PR）**：运行合成/脱敏 JSONL，验证 schema、漏斗守恒、必需场景和聚合算法；不下载模型，CI 可稳定复现。
2. **真实推理层（候选版本）**：固定 Apple Silicon 型号、macOS/Xcode、模型 SHA-256、prompt/config hash、seed 和单并发；Release 构建预热 5 次，每个 case 重复 3 次，报告中位数及尾延迟。

## Replay 集构造

MVP 目标为 1,000 个机会，按 session/document 的稳定哈希切分为 600 dev、200 validation、200 locked test。禁止同一 session 跨集合，测试集发布后只允许追加新版本，不原地改答案。

| 维度 | 最低配额 |
| --- | ---: |
| 邮件 | 150 |
| 聊天 | 150 |
| 文档 | 150 |
| 搜索框 | 100 |
| 代码 | 200 |
| 其他输入框 | 250 |
| CJK（正交标签） | 200，其中中文、日文各不少于 80 |
| 光标中间（正交标签） | 150 |
| 应抑制负样本（正交标签） | 150 |
| 多行上下文（正交标签） | 150 |

每条记录使用 `Evaluation/schema/replay-case.schema.json`。`surface` 是主场景；语言、光标位置、正负样本是正交维度。仓库只接收合成数据或完成审查的脱敏数据。

## 金标要求

- 先由标注者判断 `expectedAction = show | suppress`；若应展示，再给出自然续写 `referenceContinuation`。
- 至少 300 条由两人独立标注，冲突由第三人裁决；locked test 至少含 100 条双标样本。
- 展示/抑制判断 Cohen's kappa 应不低于 0.70。未达到时先修订标注指南，不使用该批数据做发布决策。
- 金标允许多个合理续写。v1 用首行精确匹配和最长正确前缀率；扩展同义答案时必须升级数据集版本并保留旧报告。
- 标注者不得看到候选引擎/版本，避免确认偏差。

## 采集与脱敏流程

1. 用户明确 opt-in 后，仅在本机隔离区生成候选事件；密码、安全输入、私密浏览、支付和系统认证字段直接拒绝采集。
2. 不持久化截图、剪贴板和 OCR 原始内容。先在本机替换邮箱、电话、姓名、域名、IP、UUID、API key/token、本地路径和组织名；同一 case 内占位符保持一致。
3. 人工复核只接触隔离环境。通过复核后输出 schema v1 JSONL，并重新计算字符数；未通过复核的原始候选最多保留 7 天后删除。
4. 用 session/document 的加盐稳定哈希分组切分，移除哈希盐；对 rare strings 做唯一性扫描，确保无法从 fixture 反推用户。
5. 提交前运行 evaluator；CI 报告只含计数、比例、分位数和原因桶，绝不回显 `precedingText`、`trailingText`、金标或预测文本。

## 与线上遥测对齐

| Replay 字段 | 线上事件/来源 | 漏斗用途 |
| --- | --- | --- |
| `id`, `sessionId` | opportunity/session ID（本地生成，上传前散列） | 聚类与去重 |
| `surface`, `language`, `caretMode` | Focus/输入上下文分类 | 切片 |
| `engine`, `model`, `configHash` | 引擎路由与运行配置 | 可复现性 |
| `eligible` | opportunity created | 分母 |
| `requested` | request started | 请求率 |
| `generated` | `SuggestionQualityMetricsStore.generated` | 生成率 |
| `shown` | `SuggestionQualityMetricsStore.shown` | 覆盖率/AR 分母 |
| `accepted` | `SuggestionQualityMetricsStore.accepted` | AR 分子 |
| `suggestedCharacters`, `acceptedCharacters` | 建议/接受时的 grapheme 计数 | 长度与部分接受 |
| `retainedAICharacters`, `retainedTotalAddedCharacters` | 接受后 30 秒或失焦快照 | ECCR |
| `suppressionReason` | `SuggestionQualityMetricsStore.suppression` | 后置门控原因 |
| `staleReason`, `superseded` | coordinator request lifecycle | stale/supersede |
| `latency.*` | monotonic trigger/request/show timestamps | p50/p95/max |

线上接入时要求事件守恒，且只上传枚举、计数、耗时和不可逆 ID；本 P0 不增加线上采集代码。

## 两周执行清单

| 时间 | 建议角色 | 交付与验收 |
| --- | --- | --- |
| D1-D2 | 质量负责人 + macOS 工程师 | 冻结 v1 schema/指标；sample evaluator 与 CI 全绿 |
| D2-D4 | 数据/隐私负责人 | 完成采集排除规则、脱敏规则与 30 条红队样本；零敏感字段漏出 |
| D3-D6 | 标注负责人 | 写标注指南，双标 100 条试集；kappa >= 0.70 |
| D5-D8 | 数据工程师 | 构建 1,000 条 v1 集并按哈希切分；配额、去重、schema 检查全过 |
| D7-D9 | macOS/ML 工程师 | 接现有 Llama eval adapter，固定模型与运行环境；重复运行差异可解释 |
| D9-D11 | 质量负责人 | 校对 offline/online 字段映射和守恒查询；报告无原文 |
| D11-D13 | 实验负责人 | 对当前 main 跑完整基线；产出总体、切片、尾延迟和原因桶 |
| D14 | Owner + 隐私评审 | 签署 baseline 与 locked test v1；未通过项建立独立后续任务 |

完成定义：从干净 checkout 用最短命令生成报告；CI 对破坏 schema、漏斗或场景覆盖的改动失败；基线报告包含 `QUALITY_STANDARD.md` 要求的全部字段。P1/P2 的预测策略修改必须在此基线之后另开 PR。
