# Cotabby 补全质量评价标准 v1

状态：P0 基线。适用于离线 replay、灰度实验和线上遥测。任何改变 Focus、引擎路由或 `SuggestionCoordinator` 的实验，都必须使用同一口径。

## 1. 主指标：有效补全字符率（ECCR）

```text
ECCR = sum(retained_ai_characters) / sum(retained_total_added_characters)
```

- `retained_ai_characters`：用户接受的 AI 字符中，在接受后 30 秒或输入框失焦时仍保留的字符数；部分删除只计剩余部分。
- `retained_total_added_characters`：同一观察窗口内最终保留的人工输入字符与 AI 字符之和。
- 字符按 Unicode extended grapheme cluster（Swift `Character`）计数；空白、换行和标点均计入。
- 分母为 0 的机会不进入 ECCR 分母，但仍进入漏斗、覆盖率和抑制原因统计。

ECCR 衡量 AI 实际替用户留下了多少文字，是成功率的唯一主指标。离线数据无法观察 30 秒留存时，必须把 `retained_*` 标为模拟/金标值，不能冒充线上 ECCR。

## 2. 副指标与漏斗守恒

| 指标 | 公式 / 口径 | 用途 |
| --- | --- | --- |
| 接受率 AR | `accepted / shown` | 已展示建议的吸引力 |
| 机会成功率 | `opportunities_with_retained_ai / eligible` | 每次可补全机会的真实成功概率 |
| 覆盖率 | `shown / eligible` | 系统是否因过度抑制而“刷高” AR |
| 请求率 | `requested / eligible` | Focus / 前置门控影响 |
| 生成率 | `generated / requested` | 引擎可用性与空结果 |
| 展示转化率 | `shown / generated` | 协调器、去重、stale 和后置门控影响 |
| stale 率 | `stale_dropped / generated` | 生成完成时上下文已失效 |
| supersede 率 | `superseded / requested` | 新输入替代旧请求的比例 |
| 错误展示率 | `shown_when_gold_suppress / gold_suppress` | 不应展示时打扰用户 |
| 正样本覆盖率 | `shown_when_gold_show / gold_show` | 应展示时是否给出建议 |
| 首行精确匹配 | 预测与金标首行完全相同 / 有金标正样本 | 离线正确性 |
| 最长正确前缀率 | `LCP(prediction, gold) / characters(gold)` 的均值 | 接受部分补全的潜力 |
| 延迟 | trigger→首个可见建议、trigger→最终建议、引擎生成的 p50/p95/max | 交互等待成本 |

漏斗事件必须满足：`eligible >= requested >= generated >= shown >= accepted`。每个未展示的已生成结果必须有 `suppression_reason` 或 `stale_reason`，并按 `surface / language / caret_mode / engine / model / config_hash` 切片。

## 3. 禁止只优化 AR

不得以 AR 单独上涨宣布成功。减少展示量可以机械地提高 AR，却可能降低 ECCR、机会成功率和覆盖率。出现以下任一情况，实验判失败：

- AR 上升但 ECCR 下降；
- 机会成功率或覆盖率绝对下降超过 2 个百分点；
- stale 率或错误展示率绝对上升超过 1 个百分点；
- p95 首次可见延迟恶化超过 `max(10%, 50 ms)`。

## 4. 默认实验门槛

- 离线：完整运行锁定测试集，不允许按结果删样本；报告总体及全部必需切片。
- 线上：每组至少 1,000 个 eligible 机会、200 个 shown 机会并覆盖至少 7 天。
- 宣称提升：ECCR 相对提升至少 5%，按 session 聚类 bootstrap 的 95% 置信区间下界大于 0。
- 多版本比较必须固定 replay 集版本、模型文件 SHA-256、系统提示、采样参数、硬件和并发度。

门槛的机器可读版本见 `Evaluation/gates-v1.json`。样本不足时可做方向性读数，但必须标注“未达到决策门槛”。

## 5. 每次实验必报字段

1. 实验 ID、开始/结束时间、候选与基线 commit、数据集版本和配置哈希。
2. OS/Xcode、机器芯片与内存、引擎、模型名与模型 SHA-256、温度/seed/并发度。
3. eligible/requested/generated/shown/accepted/stale/superseded 全漏斗计数及守恒检查。
4. ECCR、AR、机会成功率、覆盖率、请求率、生成率、展示转化率、错误展示率。
5. trigger→首个可见、trigger→最终、引擎生成的 p50/p95/max。
6. suppression/stale 原因分布，以及邮件、聊天、文档、搜索、代码、CJK、光标中间切片。
7. 相对/绝对差异、95% 置信区间、样本量和是否通过全部 guardrail。

线上字段目前应在 `SuggestionQualityMetricsStore.swift` 的 generated/shown/accepted/suppression 基础上补齐；本 P0 只定义契约并提供离线脚手架，不修改业务遥测。
