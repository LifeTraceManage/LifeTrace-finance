# LifeTrace Finance 批量截图识别与对话记账实现方案

## 1. 目标

在现有 Android 智能截图记账能力上增量增加两项功能：

1. **截图识别支持一次选择多张图片**；
2. **新增文字 / 对话式记账**。

本次改造的核心原则是：**复用现有截图识别、账单解析、账单创建和待确认流程，不重新建设一套导入系统。**

特别说明：

- 不新增“批量导入账单”按钮；
- 仍使用现有截图识别入口；
- 现有图片选择器由单选改为多选；
- 选择 1 张图片时保持当前单张体验；
- 选择多张图片时自动进入内部队列调度；
- 多张图片不能一次性全部传给大模型；
- 原始账单截图仍只在 Android 本地处理并直接调用 Vision API，不上传到 LifeTrace Cloud。

---

## 2. 当前架构基础

现有智能截图记账链路为：

```text
图片 / 截图
    |
    v
AutoBillingService
    |
    v
AiBookkeeper.fromImage()
    |
    v
DefaultAiExtractionEngine
    |
    v
AiProviderFactory.vision()
    |
    v
Vision API
    |
    v
JsonResponseParser
    |
    v
BillInfo[]
    |
    v
BillCreationService
    |
    v
candidate / provisional transaction
    |
    v
现有待确认箱 + Outbox / Sync
```

本次开发应继续以这条链路作为单张图片识别的核心执行单元。

批量功能只负责在外层增加：

- 多图选择；
- 任务队列；
- 并发控制；
- 进度汇总；
- 单项失败重试；
- 多笔识别结果的统一确认。

---

## 3. 截图识别入口改造

### 3.1 不增加新入口

用户交互保持：

```text
点击现有「截图识别记账」
        |
        v
系统图片选择器
```

改造前：

```text
图片选择器 -> 只能选择 1 张
```

改造后：

```text
图片选择器 -> 支持选择 1 ~ N 张
```

不增加：

- “批量截图导入”按钮；
- 独立批量导入一级页面；
- 另一套图片识别 API。

### 3.2 单张与多张自动分流

```text
List<Uri>
   |
   +-- 0 张 --> return
   |
   +-- 1 张 --> 现有单张截图识别流程
   |
   +-- N 张 --> BatchImageRecognitionCoordinator
```

单张模式必须尽量保持现有行为不变，降低回归风险。

---

## 4. Android 多图选择

现有单张选择结果应改造成统一的 `List<Uri>` 输入。

推荐优先使用 Android Photo Picker 支持多选的能力，并保留当前系统版本兼容策略。

伪代码：

```kotlin
fun handleSelectedBillImages(uris: List<Uri>) {
    when {
        uris.isEmpty() -> return
        uris.size == 1 -> recognizeSingleBill(uris.first())
        else -> recognizeMultipleBills(uris)
    }
}
```

要求：

- 不因为增加多选而破坏原单图识别；
- 用户只选一张时不显示额外的批量任务 UI；
- 用户选多张后自动进入多图识别状态页；
- 对系统选择器的最大选择数量设置合理上限，第一版建议允许 30～50 张；
- 超出上限时在进入识别前给出明确提示。

---

## 5. 多图片识别队列

### 5.1 不一次上传全部图片

用户一次选择 20 张截图时，不执行：

```text
20 张截图 -> 1 个 Vision 请求
```

而执行：

```text
20 张截图
    |
    v
Android 本地任务队列
    |
    +-- image 01 -> 现有单图识别链路
    +-- image 02 -> 现有单图识别链路
    +-- image 03 -> 现有单图识别链路
    +-- ...
```

每张图片继续使用现有：

```text
AiBookkeeper.fromImage()
        -> DefaultAiExtractionEngine
        -> Vision API
        -> JsonResponseParser
        -> BillInfo[]
```

因此本次不要求修改 Vision Prompt 的核心职责，也不要求模型理解整个批次。

### 5.2 并发控制

第一版推荐 Android 客户端控制队列，并发数：

```text
concurrency = 2
```

最多可配置为 3，但默认建议 2，原因：

- 避免短时间内大量 Vision API 请求；
- 降低模型 Provider 限流风险；
- 降低 Android 端内存峰值；
- 避免同时 Base64 编码大量图片；
- 单任务失败时更容易隔离和重试。

可使用：

- Kotlin Coroutine；
- `Semaphore`；
- 固定大小 worker pool；

实现一个轻量 `BatchImageRecognitionCoordinator`。

### 5.3 推荐职责

```text
BatchImageRecognitionCoordinator
    |
    +-- 接收 List<Uri>
    +-- 创建 BatchRecognitionItem
    +-- 控制最大并发
    +-- 调用现有单图识别能力
    +-- 汇总每张图片状态
    +-- 支持失败项重试
    +-- 支持取消尚未开始的任务
```

它不负责：

- 解析 AI JSON；
- 匹配账户或分类；
- 创建正式交易；
- Cloud Sync。

这些职责继续由现有组件承担。

---

## 6. 批量任务模型

建议仅增加 Android UI / application 层任务模型，不修改现有 durable finance transaction schema。

```kotlin
data class BatchRecognitionItem(
    val id: String,
    val uri: Uri,
    val status: BatchRecognitionStatus,
    val bills: List<BillInfo> = emptyList(),
    val error: String? = null,
)
```

状态：

```kotlin
enum class BatchRecognitionStatus {
    WAITING,
    PROCESSING,
    SUCCESS,
    FAILED,
    CANCELLED,
}
```

批次汇总状态可由 item 动态计算，不必第一版新增 Room 表。

如果后续需要 App 被杀死以后继续恢复整个批次，再考虑持久化队列。

---

## 7. 多图识别 UI

### 7.1 单张模式

选择 1 张图片时：

- 完全沿用现有 loading；
- 沿用现有识别结果；
- 沿用现有待确认流程。

### 7.2 多张模式

选择 N 张后进入多图识别状态页，例如：

```text
正在识别账单                 8 / 12

✓ 微信支付                    ¥35.00
✓ 滴滴出行                    ¥18.50
✓ 美团外卖                    ¥24.80
● IMG_008                     正在识别
○ IMG_009                     等待识别
⚠ IMG_010                     识别失败  [重试]
○ IMG_011                     等待识别
○ IMG_012                     等待识别

[取消剩余任务]          [查看已识别账单]
```

要求：

- 每完成一张立即更新结果；
- 不等待全部任务完成才显示成功项；
- 单项失败不阻断剩余任务；
- 失败项可单独重试；
- 成功项可以进入现有待确认/编辑流程；
- 支持最终一次确认多笔已成功识别的账单。

### 7.3 一张截图多笔交易

现有 `AiBookkeeper.fromImage()` 已允许一张截图返回 `BillInfo[]`。

因此批量处理的关系是：

```text
N 张图片
    -> N 个图片任务
    -> 每个任务返回 0 ~ M 个 BillInfo
    -> 最终汇总为 List<BillInfo>
```

不能错误假设“一张图片一定对应一笔账单”。

---

## 8. 与现有去重能力的关系

现有 `ProcessedImageStore` 已使用图片 SHA-256 防止同一截图重复调用 AI。

批量流程必须继续复用该能力。

因此：

```text
Batch Queue
    |
    v
AutoBillingService
    |
    v
ProcessedImageStore / SHA-256
    |
    +-- 已处理 -> 不重复调用 AI
    +-- 未处理 -> 正常识别
```

批量 Coordinator 不再实现第二套图片 Hash 数据库。

同时继续沿用现有：

- externalTransactionId 去重；
- 通知 candidate 对账；
- candidate / provisional 待确认策略。

---

## 9. App 生命周期策略

第一版以低改造成本为目标。

### 第一阶段

队列运行于 Android App 当前进程：

- 页面切换时通过 ViewModel / application scope 保持；
- 屏幕旋转等配置变化不能丢失队列；
- 用户主动取消时停止未执行任务；
- App 进程被系统杀死后，第一版可以不保证自动恢复整个批次。

### 后续升级条件

出现以下需求时再迁移到持久化任务：

- 一次经常处理几十到上百张；
- App 退出后仍必须继续识别；
- 需要断点续传；
- 需要跨设备查看识别进度。

届时优先考虑 Android WorkManager，而不是把原始图片上传到 Cloud 排队。

原始账单截图仍应保持 Android 本地处理边界。

---

# 10. 文字 / 对话记账

## 10.1 目标

增加自然语言记账能力，例如：

```text
用户：中午麦当劳吃了 35 块
```

识别：

```text
支出
麦当劳
餐饮
¥35.00
今天
```

然后复用现有账单确认与创建流程。

文字记账不应重新建设一套 Transaction Service。

---

## 11. 统一 AiBookkeeper 能力

现有：

```kotlin
AiBookkeeper.fromImage(...)
```

建议扩展：

```kotlin
AiBookkeeper.fromText(...)
```

形成：

```text
Image
  |
  v
AiBookkeeper.fromImage()
  |
  +---------------------+
                        |
Text                    v
  |                  BillInfo[]
  v                     |
AiBookkeeper.fromText() |
  |                     |
  +---------------------+
                        v
               BillCreationService
                        |
                        v
               candidate/provisional
```

这样图片与文字只在“AI 输入解析层”不同，后面的账单创建链路保持一致。

---

## 12. 文本 AI Prompt

新增独立文本记账 Prompt，例如：

```text
PromptBuilder.billGuardForText()
```

职责：

- 判断用户是否正在表达真实财务交易；
- 提取金额；
- 提取收入 / 支出 / 转账 / 退款 / 手续费类型；
- 提取商户；
- 提取分类 hint；
- 提取日期和时间表达；
- 提取账户 hint；
- 支持一句话包含多笔账单；
- 返回和图片解析兼容的 JSON 结构。

例如：

```text
今天早饭 8 块，中午麦当劳 32，晚上打车 18.5
```

应允许返回：

```text
BillInfo[3]
```

确定性字段不要交给模型自由生成，例如：

- 当前用户；
- 当前系统时间；
- 默认币种；
- durable account/category ID。

这些仍由本地逻辑处理。

---

## 13. 对话式记账 UI

文字记账建议直接使用聊天形式，而不是一个“输入一句话 -> 弹出表单”的孤立页面。

示例：

```text
用户：中午麦当劳吃了 35 块

AI：识别到一笔支出
    麦当劳 · 餐饮 · ¥35.00 · 今天

    [确认记账] [修改]
```

继续输入：

```text
用户：其实是昨天
```

AI 应修改当前待确认账单：

```text
麦当劳 · 餐饮 · ¥35.00 · 昨天
```

再例如：

```text
用户：金额改成 28
```

结果：

```text
麦当劳 · 餐饮 · ¥28.00 · 昨天
```

---

## 14. 第一版对话上下文

第一版无需实现完整 Finance Agent。

只需要维护一个轻量会话状态：

```kotlin
data class AccountingConversationState(
    val currentBills: List<BillInfo>,
    val messages: List<ChatMessage>,
)
```

支持两类主要指令：

```text
CREATE
UPDATE_CURRENT
```

行为：

### CREATE

```text
用户：晚上打车回家 18.5
```

创建新的 `BillInfo` 草稿。

### UPDATE_CURRENT

```text
用户：其实是昨天
用户：金额改成 20
用户：分类改成交通
用户：是支付宝付的
```

将：

```text
当前 BillInfo + 用户新消息
```

交给文本解析模型，返回修改后的 `BillInfo`。

确认入账后清除当前草稿上下文。

---

## 15. 对话与 durable transaction 的边界

聊天消息本身不是财务事实来源。

正确流程：

```text
Conversation Message
        |
        v
AI 解析 / 修改 BillInfo
        |
        v
用户确认
        |
        v
BillCreationService
        |
        v
finance.transaction
```

不要：

```text
用户发一句话
    -> LLM 直接写 Room transaction
```

所有 durable entity 的创建必须继续经过 `BillCreationService` 和已有领域规则。

---

## 16. AI Provider 策略

### 图片

继续使用现有：

```text
AiProviderFactory.vision()
```

### 文本

建议在现有 AI Provider 配置基础上增加文本模型能力，例如：

```text
AiProviderFactory.text()
```

如果当前 OpenAI-compatible Provider 同一模型同时支持文本，也可以先复用同一 Base URL 和 API Key。

API Key 继续：

- 保存在 Android Keystore；
- 不进入 Room；
- 不进入 Outbox；
- 不同步 LifeTrace Cloud。

---

## 17. 错误处理

### 多图识别

| 场景 | 处理 |
|---|---|
| 单图 Vision 请求失败 | 标记该 item FAILED，继续其他任务 |
| Provider 限流 | 延迟后重试，不能让所有任务同时重试 |
| 图片不是账单 | 沿用现有空 `BillInfo[]` 行为 |
| 图片已处理 | 沿用 ProcessedImageStore 去重 |
| 用户取消 | 取消 WAITING，已完成结果保留 |
| 网络断开 | 当前请求失败/等待重试，不创建错误交易 |

### 文字记账

| 场景 | 处理 |
|---|---|
| 没有金额 | 不猜测金额，提示用户补充或手动编辑 |
| 表达不是记账 | 不创建 BillInfo |
| 日期模糊 | 可使用当前日期作为上下文，但保留用户确认 |
| AI JSON 无法解析 | 使用现有 Parser 容错边界，最终失败则提示重试 |
| 用户连续修改 | 始终基于当前草稿更新，不重复创建新账单 |

---

## 18. 推荐代码结构

建议在不破坏现有目录的前提下增加：

```text
android / smart bill capture

ai/
├── AiBookkeeper.kt
├── DefaultAiExtractionEngine.kt
├── PromptBuilder.kt
├── JsonResponseParser.kt
└── AiProviderFactory.kt

现有 automation/
├── AutoBillingService.kt
├── BillCreationService.kt
└── ProcessedImageStore.kt

新增 batch/
├── BatchImageRecognitionCoordinator.kt
├── BatchRecognitionItem.kt
└── BatchRecognitionViewModel.kt

新增 conversation/
├── AccountingConversationViewModel.kt
├── AccountingConversationState.kt
└── AccountingChatScreen.kt
```

实际目录应以当前代码仓现有 package 结构为准，不为了本方案强制大规模移动已有文件。

---

## 19. 开发阶段拆分

### Phase 1：图片选择器多选

- 将现有单图选择扩展为 `List<Uri>`；
- 保持 1 张图片的旧流程；
- 验证 Android Photo Picker 多选；
- 设置合理选择上限。

### Phase 2：多图队列

- 实现 `BatchImageRecognitionCoordinator`；
- 默认并发 2；
- 每张继续调用现有单图识别链路；
- 单任务失败隔离；
- 支持取消和失败重试。

### Phase 3：多图 UI

- 显示总任务数、完成数、失败数；
- 显示每张图片状态；
- 成功项实时展示；
- 汇总 `BillInfo[]`；
- 复用待确认箱。

### Phase 4：文字记账

- 增加 `AiBookkeeper.fromText()`；
- 增加 Text Prompt；
- 输出兼容 `BillInfo[]`；
- 复用 `BillCreationService`。

### Phase 5：对话 UI

- 增加聊天界面；
- 保存当前待确认 BillInfo；
- 支持 CREATE；
- 支持 UPDATE_CURRENT；
- 支持确认入账和清空上下文。

### Phase 6：测试与回归

- 原单图截图识别回归；
- 多图 2 张、10 张、30 张；
- 网络异常；
- Provider 限流；
- 单项失败；
- 失败重试；
- 用户取消；
- 一张截图多笔账；
- 一句话多笔账；
- 对话连续修改；
- 重复确认保护。

---

## 20. 验收标准

### 截图多选

- [ ] 点击现有截图识别入口即可一次选择多张图片；
- [ ] 不存在额外“批量导入”按钮；
- [ ] 只选择一张图片时保持原有体验；
- [ ] 多图不会在一个请求内一次发送给 Vision 模型；
- [ ] 默认最多同时识别 2 张；
- [ ] 单项失败不阻断整个队列；
- [ ] 支持单项重试；
- [ ] 支持查看整体识别进度；
- [ ] 识别结果继续使用现有 `BillInfo[]`；
- [ ] 最终继续使用现有 `BillCreationService` 和待确认箱；
- [ ] 原始图片不上传 LifeTrace Cloud。

### 文字 / 对话记账

- [ ] 可以输入“中午麦当劳吃了35”生成待确认账单；
- [ ] 可以输入一句话生成多笔账单；
- [ ] 可以用“其实是昨天”“金额改成28”等话术修改当前账单；
- [ ] 文本识别输出与现有 `BillInfo` 兼容；
- [ ] durable transaction 仍经过现有账单创建服务；
- [ ] AI API Key 继续只保存在 Android 本地安全存储；
- [ ] 文字记账失败不会产生错误交易。

---

## 21. 最终调用关系

```text
                           ┌─────────────────────┐
                           │ 现有截图识别入口     │
                           └──────────┬──────────┘
                                      |
                                      v
                              系统图片选择器
                              支持 List<Uri>
                                      |
                    ┌─────────────────┴─────────────────┐
                    |                                   |
                  1 张                                N 张
                    |                                   |
                    v                                   v
             现有单图流程                 BatchImageRecognitionCoordinator
                    |                           concurrency = 2
                    |                                   |
                    └─────────────────┬─────────────────┘
                                      |
                                      v
                             AiBookkeeper.fromImage()
                                      |
                                      v
                                  BillInfo[]
                                      ^
                                      |
                            AiBookkeeper.fromText()
                                      ^
                                      |
                              对话式文字记账 UI
                                      |
                                      v
                               当前账单草稿上下文
                                      |
                                      v
                              BillCreationService
                                      |
                                      v
                          candidate / provisional
                                      |
                                      v
                                现有待确认箱
                                      |
                                      v
                              Outbox / Cloud Sync
```

## 22. 结论

本次功能应定义为对现有智能记账能力的**输入扩展与调度扩展**：

- 图片侧：从单选升级为多选，通过 Android 本地队列逐张复用现有 Vision 识别能力；
- 文字侧：增加 `fromText()` 和聊天交互，但继续输出现有 `BillInfo` 并复用账单创建流程；
- 不新增批量导入按钮；
- 不一次把所有图片发给模型；
- 不把原始截图上传 Cloud；
- 不重写现有截图识别核心。

这样可以在保持当前架构稳定的前提下，以最小回归风险完成批量截图和对话记账两个需求。