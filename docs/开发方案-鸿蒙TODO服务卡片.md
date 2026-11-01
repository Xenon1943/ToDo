# HarmonyOS TODO 应用 + 服务卡片 · 开发方案（第一轮：调研与规划）

> 状态：**规划已落地为代码**（P0–P6 主体实现完成，`assembleHap` 构建通过，单测覆盖核心派生逻辑）。真机验证清单见 [README](../README.md)。
> 工程：`C:\Users\Xenon\DevEcoStudioProjects\ToDo`（DevEco Studio 26.0.0.851，SDK `HarmonyOS 26.0.0 / apiVersion 26`，`compatibleSdkVersion 6.1.1(24)`，Stage 模型，bundle `com.xenon.todo`）

---

## 0. 结论摘要（先看这 8 条）

1. **技术路线可行**，但"实时刷新"不是靠定时器，而是靠**事件驱动 + 提供方主动刷新**：卡片上的一切操作走 `postCardAction(message)` → `FormExtensionAbility.onFormEvent` → 写库 → `updateForm` 回推；应用内的操作走 `formProvider.reloadAllForms`（API 22+）。
2. **卡片里不能有输入框**：`TextInput`/`DatePicker`/`TimePicker`/`Scroll` 都没有卡片能力（本机 SDK `@form` 标记为 0，官方文档也全文无标注），所以"快速新建"只能是**一键创建占位任务**或**拉起应用轻编辑**，二者需你选（见 D1）；卡片列表只能用 `List`，不能用 `Scroll`。
3. **卡片列表滑动可行**：`List` 自 API 9 起支持 ArkTS 卡片，纵向滑动由组件内置手势提供；但**卡片内不支持左右滑动控件**（与桌面翻页手势冲突），所以卡片列表必须纵向。
4. **"我的一天"每日自动归类建议用"读取时派生"而不是"午夜定时任务"**：`workScheduler` 明确不精准（按活跃度 2h/4h/24h/48h 调度），而卡片定点刷新只在卡片可见时触发——都不能保证 0 点执行。派生方案零后台依赖、跨天必定正确（见 5.3）。
5. **提醒用代理提醒（`reminderAgentManager` 日历类型）**，但**一个应用最多 30 条有效提醒**——这是本项目最硬的约束，决定了"只给近 48 小时到期的任务排两条提醒"的预算策略（见 5.6、D3）。权限已核实为 normal + system_grant，**不需要 ACL**，但必须先拿到通知授权。
6. **卡片与主应用是两个进程**（共享同一文件沙箱），存储必须跨进程安全。官方只对 **GSKV 模式的 Preferences（API 18+）** 明确写了"支持多进程并发读写"；RDB 文档既没支持也没禁止，还特别提示"不同 Context 会产生多个数据库"——所以**选 GSKV，不选 RDB**（见 5.2）。默认 XML 模式的 Preferences 官方明确"不支持在多进程场景下使用"。
7. **FormExtensionAbility 回调结束后进程只再存活约 10 秒**，所以卡片里能做的只有"轻量读写 + 回推"，耗时的活必须交回主应用。
8. 官方能力边界已经查清（5 条刷新机制、配额、限制见第 3 节），**真正的风险集中在真机行为与产品取舍**，不在技术可行性（见第 7 节）。

---

## 1. 当前工程盘点

| 项目 | 现状 | 对本需求的影响 |
| --- | --- | --- |
| 工程模板 | DevEco 标准 Stage 工程，`entry` 单模块，`pages/Index.ets` 还是 Hello World | 需要新建：数据层、列表页、编辑面板、卡片页、FormExtensionAbility |
| SDK | `apiVersion 26`，target 26.0.0 / compatible 24 | 可用 `reloadForms`(22+)、GSKV Preferences(18+)、`multiScheduledUpdateTime`(18+)；**用到 22+/26 的接口要写 downlevel 兜底** |
| 设备类型 | `deviceTypes: ["phone"]` | 卡片尺寸只考虑手机：`2*2 / 2*4 / 4*4` |
| 依赖 | 仅 hypium / hamock | 不引第三方库，纯官方 Kit |
| 签名 | `signingConfigs: []`，未配置 | **真机/卡片验证的前置条件**：需在 DevEco 里自动签名（登录华为账号），否则卡片根本装不上（P0 第一步） |
| 构建 | 无 `hvigorw` 脚本；DevEco 自带 `tools/hvigor` + `tools/node` | 可用 IDE 构建，或用自带 hvigor 做命令行构建 |

现有 `module.json5` 里**没有** `extensionAbilities` 的 `form` 类型条目，`resources/base/profile/` 下也**没有** `form_config.json` —— 卡片是从零开始，不涉及改造。

---

## 2. 参考项目（GitHub / Gitee / 官方示例）

> 说明："已核实"= 我读过仓库文件树与配置文件原文；"仅描述"= 只依据仓库说明，尚未逐文件核对。

### 2.1 DuFehlst/AlwaysToDo-HarmonyOS ✅ 已核实（最贴近本需求）

- 链接：https://github.com/DuFehlst/AlwaysToDo-HarmonyOS （MIT，2026-09 创建，HarmonyOS NEXT 原生 TODO）
- 仓库事实（读自 `data.jsdelivr` 文件树 + `form_config.json` 原文）：
  - `entry/src/main/ets/common/{Models,Storage,Reminders,WidgetData,SyncEngine,ApiClient,Theme}.ets`
  - `entry/src/main/ets/formability/WidgetAbility.ets`（FormExtensionAbility）
  - `entry/src/main/ets/widget/pages/WidgetCard.ets`（约 9.9KB 的卡片页）
  - `resources/base/profile/form_config.json`：`isDynamic: true`、`scheduledUpdateTime: "10:30"`、`updateDuration: 1`、`defaultDimension: "2*2"`、`supportDimensions: ["1*2","2*2","2*4","4*4"]`
- **具体学什么**：
  1. **分层切分**：`Models`（数据结构）/`Storage`（持久化）/`Reminders`（代理提醒）/`WidgetData`（卡片数据快照）/`SyncEngine`（同步）——`WidgetData` 独立于 `Storage` 这一点很关键：卡片要的是"渲染快照"，不是全量数据模型。
  2. **卡片数据桥**：`WidgetData` + `WidgetAbility` 组合，说明它走的是"卡片进程读快照 → updateForm 推给卡片 UI"的官方链路。
  3. `form_config` 一次声明 4 个尺寸（含 `1*2` 小尺寸），可借鉴"小尺寸只显示计数、大尺寸显示列表"的分支渲染。
- **可直接借鉴**：目录分层、`WidgetData` 快照概念、`form_config` 多尺寸声明。
- **需适配**：它的 `updateDuration: 1`（30 分钟定时刷新）**不适合我们**——我们要秒级响应，定时刷新是兜底而不是主路径；它的卡片是否支持滑动/快速完成我没读到源码，不能假设。
- **要规避**：`scheduledUpdateTime` 与 `updateDuration` 同时非 0 时，**`updateDuration` 优先、定点刷新失效**（官方明确）——它两个都配了，等于定点刷新没生效。

### 2.2 youyeyejie/ZhiXing_ActHub ✅ 已核实（数据层与提醒服务的最佳参考）

- 链接：https://github.com/youyeyejie/ZhiXing_ActHub （HarmonyOS NEXT 日程/待办/专注一体化）
- 仓库事实：
  - `entry/src/main/ets/database/{AppDatabase,DatabaseConfig,UserDatabase}.ets` → 用 **`relationalStore`（RDB）** 做持久化
  - `entry/src/main/ets/models/{Todo,TodoCategory,BaseEntity,Plan,Idea}.ets`
  - `entry/src/main/ets/repositories/{BaseRepository,TodoRepository,TodoCategoryRepository,...}.ets`
  - `entry/src/main/ets/services/{CalendarReminderService,NotificationService,SyncManager,...}.ets`
  - `entry/src/main/ets/pages/todo/{index,TodoPageState}.ets` + `components/{TodoEditorContent,TodoCardLlist,CategoryFilter}.ets`
  - 用了 **V2 状态管理**（仓库自带 `arkui-notes/state/mvvm-v2.md`），页面状态放在 `*PageState.ets`
- **具体学什么**：
  1. **`BaseRepository` + 具体 Repository** 的仓储模式，`TodoRepository` 很薄（~1KB），说明业务都收敛在 `PageState`/Service 层。
  2. **`CalendarReminderService` + `NotificationService` 分离**：代理提醒的"排期/取消/对账"与"通知渠道/授权"分开管，避免 `publishReminder` 散落各处。
  3. **`TodoEditorContent`（23KB）+ `Index`（2.3KB）**：编辑表单抽成独立 Content 组件，用半模态（`ActionSheet`/`bindSheet`）复用到多个入口——这正是"卡片快速新建后进应用编辑"要复用的东西。
  4. **V2 装饰器（`@ObservedV2`/`@ComponentV2`）+ `PageState` 类**：比 V1 的 `@State` 更适合"一个任务被多处引用"的场景。
- **可直接借鉴**：RDB + Repository 分层、提醒服务拆分、"编辑表单组件化 + 半模态"。
- **需适配**：它的工程很大（计划/专注/闪记/白噪音/AI），**只挑 `todo` + `database` + `reminders` 三块**，别整体搬。
- **要规避**：它**没有服务卡片**——所以"卡片 ↔ 应用跨进程一致性"这块它完全不涉及，不能照抄它的数据访问姿势（同一进程内随便读）。**这正是本项目最难的部分**。

### 2.3 Explore-In-HMOS/how-to-build-ability-trigger-skills（提醒实现参考）

- 链接：https://github.com/Explore-In-HMOS/how-to-build-ability-trigger-skills
- 仓库说明：把 `reminderAgentManager`（闹钟/提醒）+ `WantAgent` 意图 + 延迟用药提醒串起来的 codelab（手表场景）。
- **具体学什么**：`ReminderRequest` → `wantAgent` → 点击通知跳回本应用并携带业务参数 的完整链路；以及"周期性提醒"的写法。我们的"到点提醒 + 点通知打开对应任务详情"就是这条链路。
- **需适配**：手表场景的提醒数少、不需要预算控制；我们要加"30 条上限"的排队与淘汰。
- **要规避**：文档明确"点击提醒通知跳转的应用必须是申请代理提醒的本应用"，别想着跳到系统日历。

### 2.4 官方示例 `openharmony/applications_app_samples` → `DocsSample/ApplicationModels/StageServiceWidgetCards`

- 链接：https://github.com/openharmony/applications_app_samples （目录 `code/DocsSample/ApplicationModels/StageServiceWidgetCards`，官方文档正文里所有卡片代码片段都来自这里）
- **具体学什么**：这是**"卡片一切能力的最小可运行样例集"**：定时刷新、下次刷新、定点刷新、`message` 事件刷新、图片更新、关闭卡片……每个子工程只做一件事，比任何第三方仓库都可靠。
- **可直接借鉴**：`EntryFormAbility` 的生命周期骨架、`form_config.json` 各字段的合法写法。
- **需适配**：示例是"每个能力一个独立卡片"，我们要合成"一个卡片 + 一套业务"。
- **要规避**：示例里大量 `hilog` 之外的简化（比如直接在 `onUpdateForm` 里造随机数），不能当生产代码。

### 2.5 openharmony/ability_form_fwk（卡片框架源码，排障用）

- 链接：https://github.com/openharmony/ability_form_fwk
- **具体学什么**：不是拿来抄代码，而是当"行为存疑时的最终裁判"——刷新配额、可见性、`onUpdateForm` 触发条件这些在文档里写得粗的地方，可以在这里确认（例如 fms 服务端如何计算 50 次配额）。
- **需规避**：它是系统侧实现，普通应用无法调用其中大部分内部能力（`formHost.requestForm` 仅系统应用）。

### 2.6 mhtcgr/ToDoList_For_Harmony（入门级 TODO，仅描述）

- 链接：https://github.com/mhtcgr/ToDoList_For_Harmony
- 仓库说明：ArkTS 实现的待办 App（登录注册 + 个人主页 + 待办 + 联网搜索，主要实现前端）。
- **具体学什么**：纯 ArkTS 列表页/表单页的写法、UI 组织方式，适合 P2 阶段抄"页面骨架"。
- **要规避**：偏"前端演示"，数据层很可能不走心；**不要借鉴它的存储与刷新**。

### 2.7 Gitee：wayxingwork/ToDoList（简易案例，仅描述）

- 链接：https://gitee.com/wayxingwork/ToDoList
- 仓库说明：基于 ArkTS 声明式范式与基础组件实现的简易待办案例。
- **用途**：只当"ArkTS 语法/组件"速查，价值有限；列出来是为了说明我筛过，但它**不含卡片、不含提醒**，不进入技术参考主线。

### 2.8 产品体验参考：Microsoft To Do（不开源）

不需要代码，需要的是**信息架构**：左侧"我的一天/重要/计划中/已分配/任务"分组，任务项 = 圆形勾选框 + 标题 + （可选）到期日/提醒/重复/"我的一天"太阳图标，详情是右侧浮层面板。我们的字段（名称/截止/提醒/描述）与它的"标题/到期日/提醒我/添加备注"几乎一一对应，**直接照抄它的字段命名与交互位置**能省掉一轮设计。

### 2.9 冲突点：GitHub 做法 vs 官方文档

| 冲突点 | GitHub 常见做法 | 官方文档 | 结论 |
| --- | --- | --- | --- |
| 卡片刷新 | 靠 `updateDuration` 定时刷新"假装实时"（AlwaysToDo 配了 30 分钟） | 定时刷新有 50 次/天/卡片配额，且卡片不可见时不刷新 | **以官方为准**：事件驱动为主，定时只做兜底 |
| 数据存储 | 直接用 Preferences 存整个 JSON（大量 TODO demo） | XML Preferences 不支持多进程；卡片与应用是两进程 | **以官方为准**：RDB 或 GSKV Preferences |
| 双向通信 | 用 `AppStorage`/`EventHub` 想"通知卡片" | 卡片与应用独立进程，只能 `updateForm` 推 `LocalStorageProp` | **以官方为准**：`AppStorage` 在卡片侧无效 |
| 卡片滑动 | 用横向 `Swiper` 做"任务卡翻页" | 卡片内不支持左右滑动控件（手势冲突） | **以官方为准**：纵向 `List` |

---

## 3. 鸿蒙服务卡片关键限制（含依据）

> 依据来源：OpenHarmony 官方文档仓库（`openharmony/docs` master，对应 **API 26**）原文，我用 Gitee raw 直接读的原文；同时对照华为开发者官网对应页面链接。**官网 HarmonyOS 6.x 页面与 OpenHarmony master 可能有版本差，凡标 ⚠️ 的请在 DevEco 26 里实测确认。**

### 3.1 UI 能力

| 结论 | 依据 |
| --- | --- |
| 卡片用 ArkTS 声明式范式，支持**部分**组件/事件/动效/状态管理，接口文档里带"卡片能力"标记的才能用 | 《ArkTS卡片界面开发概述》 |
| `List`、`Swiper`、`Grid`、`Text`、`Button`、`Image`、`Divider`、`Checkbox`、`Stack`、`SymbolGlyph` 等**有**卡片标记（我用本机 SDK `ets/component/*.d.ts` 的 `@form` 标记逐个核对：List 49 处、Swiper 253 处、Checkbox 17 处、Divider 9 处） | 本机 SDK 声明（最权威，就是你要编译的那份） |
| **`TextInput` / `DatePicker` / `TimePicker` / `Scroll` 在卡片里都不支持** | ①本机 SDK：这几个文件里 `@form` 标记数为 **0**；②官方组件文档全文检索：接口/属性/事件**无任何**"卡片能力：…支持在 ArkTS 卡片中使用"标注（只有"原子化服务 API"标注） |
| 因此：卡片里**不能文本输入、不能弹日期/时间选择器、不能用 `Scroll`**（`List` 可以，这是最容易踩的坑）；日期选择必须回应用内 | 同上 |
| 卡片内**不支持左右滑动控件**（与桌面左右翻页手势冲突）；纵向 `List` 滑动由组件内置手势实现 | 《ArkTS卡片开发概述·约束与限制》 |
| `List` 的 `enableScrollInteraction` / `nestedScroll` / `friction` / `scrollSnapAlign` **无**卡片标记 → 卡片里不能关掉滑动手势、不能嵌套滚动 | 官方组件文档"卡片能力"标注 |
| 卡片**不能**用 `getContext()` 拿应用上下文（卡片渲染在系统 FRS 进程，同一提供方的所有卡片共享一个 ArkTS 虚拟机） | 《卡片实现原理》+《卡片数据交互》"不能使用 getContext 方法" |
| 卡片数据只能经 `LocalStorageProp` 接收，且**接收时会被转成 string** | 《ArkTS卡片页面刷新概述·卡片数据交互》 |
| 静态卡片（`isDynamic:false`）只支持 UI/布局，无通用事件、无自定义动效，交互只能用 `FormLink`；`postCardAction` 只对动态卡片有效 | 《ArkTS卡片配置》《卡片事件概述》《FormLink》 |
| 单次刷新数据 ≤ 10MB、图片 ≤ 20 张（API 20+；API 19- 为 5 张/2MB） | 《ArkTS卡片页面刷新概述·约束与限制》 |

### 3.2 数据刷新机制（5 条路径）

| 机制 | 触发者 | 关键参数 | 限制 |
| --- | --- | --- | --- |
| **提供方主动刷新** `formProvider.updateForm` | 应用/卡片进程 | 传 `FormBindingData` | 只能刷新自己的卡片；配合 `onFormEvent`/`onUpdateForm`/`onAddForm` 使用 |
| **批量主动刷新** `reloadForms` / `reloadAllForms` | **仅 UIAbility** | module/ability/formName | **API 22+**；只对**已加桌**的卡片生效，返回生效数量 |
| **定时刷新** `updateDuration` | 系统 | 单位 30 分钟，N=30N 分钟 | **每卡片每天 50 次**，0 点重置；首次刷新最多偏 30 分钟；**卡片不可见时不刷新** |
| **下次刷新** `setFormNextRefreshTime` | 应用 | 最短 **5 分钟** | 同上配额；不可见时只记录 |
| **定点刷新** `scheduledUpdateTime` / `multiScheduledUpdateTime` | 系统 | `"10:30"`；多定点最多 **24 个** | 需 `updateDuration: 0`；`multi` 生效则单定点失效；不可见时不触发 |
| **条件刷新** `conditionUpdate: ["network"]` | 系统 | 无网→有网 | API 26.0.0 起三方可用（此前仅系统应用） |
| 卡片使用方主动刷新 `formHost.requestForm` | 桌面 | — | **仅系统应用**，我们用不了 |
| 代理刷新（`dataProxyEnabled`） | 系统数据服务 | `formBindingData.proxies` | **仅系统应用**可做数据提供方，三方基本不可用 |

**关于 `updateForm` 的两个"文档没写"**（工程上要按保守假设处理）：
- **调用频率**：文档**没有**任何频率/配额说明（配额只存在于被动刷新侧的"50 次/天/卡片"）。→ 但不能假设"无限"，实现上要合并高频刷新（同一帧多次变更只推一次）。
- **卡片不可见时的行为**：文档只对定时/定点刷新写了"不可见时仅记录、可见时统一刷新"，`updateForm` 未描述。→ 实现上要保证 `onAddForm` 永远返回最新快照，不依赖"推送时卡片正好可见"。
- 错误码：`16501001` 卡片不存在、`16501003` 无权操作该卡片 → 都要 catch 并当作"该卡片已删除"处理（批量刷新时跳过，不影响其它卡片）。

### 3.3 卡片 ↔ 应用通信

| 方向 | 手段 | 说明 |
| --- | --- | --- |
| 卡片 → 应用（拉前台某页） | `postCardAction({action:'router', bundleName, moduleName, abilityName, uri?, params})` | 只能跳自己应用；只能在点击事件里触发 |
| 卡片 → 应用（后台拉起） | `postCardAction({action:'call', ...})` | 要求 UIAbility 为 `singleton`、`params.method` 为 string、需 `ohos.permission.KEEP_BACKGROUND_RUNNING` |
| 卡片 → 应用（发消息，**本项目主力**） | `postCardAction({action:'message', params})` | 拉起 `FormExtensionAbility.onFormEvent(formId, message)`，**message 是 string**（自己 `JSON.stringify`） |
| 应用 → 卡片 | **只有** `updateForm(formId, formBindingData)`（或 `reloadForms*` 间接触发 `onUpdateForm`） | 独立进程，不能共享内存、不能用 EventHub/AppStorage |

### 3.4 提醒机制选型

| 方案 | 精度 | 应用被杀后 | 结论 |
| --- | --- | --- | --- |
| **代理提醒** `reminderAgentManager`（日历型） | 到点触发（系统代理） | ✅ 仍然提醒 | **选它**。约束：单应用≤30 条有效提醒；类型仅 倒计时/日历/闹钟；需 `ohos.permission.PUBLISH_AGENT_REMINDER` + 通知授权；点击通知只能跳本应用 |
| `workScheduler` 延迟任务 | ❌ 不精准（按活跃度 2h/4h/24h/48h、内存/温度/充电条件调度） | ✅ | 不用来做"早上 8 点" |
| `backgroundTaskManager` 长时任务 | 需常驻前台/特定类型 | — | 不适合，且卡片进程不能引用 |
| 应用内定时器 / `setTimeout` | 精确 | ❌ 退到后台就被冻结 | 只能做 UI 刷新 |

### 3.5 进程模型（决定架构的两条）

1. **卡片提供方进程（FormExtensionAbility）与应用主进程是两个进程**，内存隔离、**共享同一文件沙箱**。
2. **`FormExtensionAbility` 生命周期调度完成后只再存活约 10 秒**，之后进程退出、不能常驻 → 卡片里只做轻量读写。

### 3.6 存储的多进程约束

| 存储 | 多进程 | 依据 |
| --- | --- | --- |
| Preferences（默认 **XML** 模式） | ❌ "无法保证进程并发安全，会有文件损坏和数据丢失的风险，不支持在多进程场景下使用" | 《通过用户首选项实现数据持久化·约束限制》 |
| Preferences（**GSKV** 模式，API 18+） | ✅ "数据以二进制形式存储…**支持多进程并发读写**"，写即落盘；需 `isStorageTypeSupported(StorageType.GSKV)` 探测，且**选定后不能切换** | 同上 |
| `relationalStore`（RDB / SQLite） | ⚠️ **文档既没写"支持多进程"也没写"不支持"**（约束只写了"同一时间只能一个写操作"、4 读连接 + 1 写连接）；更关键的是文档明确"数据库与 Context 有关，**不同的应用上下文会产生多个数据库**"（举例：每个 UIAbility 各有上下文） | 《关系型数据库》约束限制 + 说明；⚠️ UIAbility 与 FormExtensionAbility 两个 Context 是否指向同一 db 文件，文档**未保证** |

> 补充：`dataShare` 是**跨应用**共享机制，两份实现指南都是 `-sys`（系统应用），官方**没有**推荐用它在"同应用 UIAbility 进程 ↔ FormExtensionAbility 进程"之间做变更通知。官方文档里**唯一明确**的"主进程 → 卡片进程"通道是 `formProvider.reloadForms/reloadAllForms`（原文："在应用主进程通过本接口通知 FormExtension 进程进行批量更新"）；反向只有被动的 `onUpdateForm`/`onFormEvent` 回调。

---

## 4. 需要你确认的产品决策（先看这节）

| # | 决策点 | 选项 | 我的建议 |
| --- | --- | --- | --- |
| **D1** | 卡片上"快速新建"的具体行为（卡片里**没有输入框**） | A. 一键生成"新任务"（无截止、进我的一天），应用内再改名<br>B. 点击拉起应用 → 打开新建半模态（预填我的一天/无截止）<br>C. 混合：短按一键建，长按/角标进应用 | **C**，但先做 A（最少交互、最像"快速"） |
| **D2** | "早上提醒"的默认时间 | 固定 08:00 / 用户可设 / 跟随系统闹钟 | **08:00，且设置页可改**（存 Preferences） |
| **D3** | 30 条提醒上限的取舍策略 | A. 只给**近 48h 到期**的任务排提醒（约 14 个任务 × 2 条）<br>B. 全部任务，超限后只保留"截止前 10 分钟"一条<br>C. 让用户手动挑"要提醒的任务" | **A + B 兜底**：优先近 48h 双提醒，剩余预算给远期任务只排"截止前 10 分钟"，超出则按到期时间排队并提示 |
| **D4** | "我的一天"跨天语义 | A. 每天清空（MS To Do 行为），未完成任务留在"全部任务"<br>B. 未完成的任务顺延到新的一天 | **已改为 B**（实机反馈：没做完的第二天要还在） |
| **D5** | 手动把任务加进"我的一天"后，跨天是否保留 | 只在当天 / 保留直到完成 | **保留直到完成**（与 D4=B 一致） |
| **D6** | 卡片尺寸与显示条数 | 2*2（3 条）/ 2*4（6 条）/ 4*4（10 条） | 三个都支持，按尺寸自适应条数 |
| **D7** | 是否需要"重复任务"（每天/每周） | 要 / 不要（V1 砍掉） | **V1 不做**，代理提醒本身支持 `daysOfWeek`，V2 再加 |
| **D8** | 提醒日期为空但截止日期非空时，是否仍提醒 | 是（按 D2 默认规则）/ 否（用户没设就不提醒） | **是**：需求写的是"有截止日期的任务…当天早上提醒一次，截止前 10 分钟再提醒一次" |

---

## 5. 技术方案

### 5.1 数据模型

```ts
// 任务：一个实体，视图靠派生
interface TodoTask {
  id: string;              // uuid
  title: string;           // 名称（必填，≤200 字）
  dueAt: number | null;    // 截止日期（ms 时间戳），可为空
  remindAt: number | null; // 提醒日期（ms），可为空
  note: string;            // 具体描述，可为空
  done: boolean;
  doneAt: number | null;
  createdAt: number;
  updatedAt: number;
  myDayDate: string | null;   // 'YYYY-MM-DD'：手动加入"我的一天"的日期
  myDayHiddenOn: string | null; // 'YYYY-MM-DD'：用户当天把"自动归类进来的"移出去的标记
  reminderIds: number[];      // 已发布的代理提醒 id（1~2 条）
}
```

分类**不落库**，全部派生：

| 视图 | 谓词 |
| --- | --- |
| 我的一天 | `done = 0 AND ( myDayDate = today OR ( dueAt 落在今天 AND myDayHiddenOn != today ) )` |
| 全部任务 | 全部（默认未完成在前，按 dueAt/createdAt 排序） |
| 计划中（可选） | `dueAt != null AND done = 0` |
| 已完成（可选） | `done = 1` |

> 为什么分类不落库：需求里"截止当天自动进入我的一天"如果落库，就必须有人在 0 点执行写操作；派生法则**永远正确**，也让"用户手动移出"只需一个 `myDayHiddenOn` 标记。MS To Do 的"我的一天"也是这个心智（每天重新开始）。

### 5.2 存储与访问

**结论：用 GSKV 模式的 Preferences（每任务一个 key），仓储接口留好换实现的口子。**

| 维度 | GSKV Preferences（选它） | relationalStore（不选） |
| --- | --- | --- |
| 多进程 | ✅ 官方明确"支持多进程并发读写"、写即落盘 | ⚠️ 官方既未背书也未禁止；且"不同 Context 会产生多个数据库"，**恰恰击中我们两个进程两个 Context 的场景** |
| 查询能力 | `getAll()` 全量读出后内存过滤（本项目 <1000 条，无压力） | SQL 谓词更强 |
| 并发写冲突 | 不同 key 不冲突；同 key 由单条任务归属单一所有者（卡片只改被点的那一条） | 同一时间只允许一个写操作，跨进程排队不可控 |
| 复杂度 | 极低（无建表/迁移） | 建表、版本迁移、事务 |

落地要点：
- 库名 `todo_store`，`storageType: preferences.StorageType.GSKV`；启动时 `isStorageTypeSupported(GSKV)` 探测，**不支持则回退 XML 并在文档里注明"仅单进程安全"的降级风险**（这种情况只能靠"卡片不做写操作、写操作一律 router 回应用"来规避）。
- **一旦选定 GSKV 就不能切回 XML**（官方限制），所以 P0 实验要在全新安装前提下做。
- key 设计：`task:<id>` → 任务 JSON；`meta:version` → 数据版本号（每次写自增，便于调试与快照版本校验）；`setting:*` → 设置项。
- 写入串行化：进程内用一个 Promise 队列，避免"读-改-写"交错。
- 跨进程**没有**变更通知（`on('change')` 只在本进程触发），这必须靠 5.4 的刷新链路传播。

### 5.3 "我的一天"每日自动归类

**方案：读取时派生 + 卡片定点刷新兜底展示。零后台任务。**

1. 取数时统一调用 `MyDayService.today()`：先按 5.1 谓词计算（纯内存/SQL），不写库。
   - **顺延规则（实机迭代后加入）**：昨天没做完的任务（`myDayDate` 在过去 / 已逾期）今天继续出现在"我的一天"，行上标「顺延」；今天做完后仍计入当天 `total/done`，次日自然消失。用户当天手动移出（`myDayHiddenOn`）优先级最高。
2. 卡片侧：`form_config.json` 配 `updateEnabled: true`、`updateDuration: 0`、`scheduledUpdateTime: "00:05"`、`multiScheduledUpdateTime: "08:00,12:00,18:00"` —— 跨天/中午/傍晚各刷一次，保证"0 点后第一次看到卡片就是新的一天"（注意：**卡片不可见时不触发**，可见时系统补刷）。
3. 应用侧：`EntryAbility.onForeground()` + 页面 `onPageShow` 重新取数，天然跨天正确。
   - `onForeground` 的触发时机官方明确（"切换至前台时且 UI 可见之前"，每次从后台回来都会走），**但同页要求回调内只做轻量操作** → 实现上必须是"发起一次异步重载"，不能同步查库/解析。
4. **不使用** `workScheduler`（不精准，见 3.4），**不使用** `setFormNextRefreshTime` 做日切（有 5 分钟下限且占用 50 次配额）。
5. 兜底：`form_config` 的定点刷新只是"视觉及时性"；即使一次都没触发，用户下次看卡片/开应用时派生逻辑仍会算出正确结果。

> **说明**：官方文档**没有**"每日视图/每天 0 点切换数据"的推荐做法（我查过了，not found）。这个方案是"卡片定点刷新（官方唯一准点机制，且只对卡片、只在可见时）+ 读取时派生 + `onForeground` 重载"三者的组合，属于文档允许但未被官方写成"推荐"的用法——这是本项目里**最需要真机验证的假设之一**（见 V7）。

> 这就是"自动归类"的完整实现：**没有写操作，所以不存在"漏跑一次定时任务"的 bug**。

### 5.4 卡片刷新架构

**核心原则：数据只有一个真相源（沙箱存储），刷新永远由"改变数据的那一方"主动发起。**

```
┌────────────────────────┐        写          ┌──────────────────────┐
│  主应用进程 (UIAbility) │ ────────────────▶ │  沙箱存储 (GSKV)      │
│  列表页 / 编辑面板      │ ◀──────────────── │  单一真相源           │
└───────────┬────────────┘        读          └──────────▲───────────┘
            │ formProvider.reloadAllForms()              │ 读
            ▼                                            │
┌────────────────────────┐    onUpdateForm     ┌─────────┴────────────┐
│  卡片框架 (FMS, 系统)   │ ──────────────────▶ │ FormExtensionAbility │
│  桌面上的卡片实例        │ ◀────────────────── │ (卡片提供方进程)      │
└───────────┬────────────┘   updateForm(数据)   └─────────▲────────────┘
            │ LocalStorageProp                            │ onFormEvent
            ▼                                             │ (message)
      卡片 UI (WidgetCard.ets) ──── postCardAction ────────┘
```

**三条刷新路径（全部要打点日志，便于验证）**

| 路径 | 触发 | 具体动作 | 时延目标 |
| --- | --- | --- | --- |
| P-A 卡片内操作 | 点击勾选 / "+" | `postCardAction(message)` → `onFormEvent` 解析 JSON → 写存储 → **先 `updateForm(formId, 新快照)`** | < 300ms |
| P-B 应用内操作 | 新建/编辑/完成/删除 | 写存储 → `getPublishedRunningFormInfos()` 取已加桌 formId → 逐张 `updateForm` 直推；失败才退回 `reloadAllForms` | < 1s |
| P-C 兜底 | 跨天 / 应用回前台 | 定点刷新 `onUpdateForm`；应用 `onForeground` 重读 | 分钟级 |

**卡片数据快照（`WidgetData`）**

```ts
interface MyDaySnapshot {
  v: 1;                 // 版本号，卡片侧做兼容
  date: string;         // 'YYYY-MM-DD'
  total: number;        // 我的一天任务总数
  done: number;         // 已完成数
  items: Array<{ id: string; t: string; due: number | null; od: boolean }>; // 最多 12 条
  updatedAt: number;
}
```
- 卡片侧 `@LocalStorageProp('myday') raw: string = '{}'` → `aboutToAppear`/`onChange` 里 `JSON.parse`，**必须 try/catch**（数据可能被截断/为空）。
- 只推"渲染需要的字段"，不推全量任务（省 IPC、省内存，也避开刷新数据大小限制）。
- 每条 item 加 `v` 版本校验：卡片发现 `v` 不匹配就显示"请升级应用"而不是崩溃。

**主应用侧的数据一致性（难点）**

卡片进程写了数据，主应用**不会**收到任何回调（无跨进程事件）。方案：

1. **必做**：`onForeground` / `onPageShow` 重新读存储（覆盖"用户从卡片进应用"的场景，占 95%）。
2. **可选增强（P4）**：`dataShare` 观察者（`createDataShareHelper` + `on('dataChange')`）。**但官方并未推荐用它做同应用跨进程通知**（它的定位是跨应用共享，实现指南都标 `-sys`），加 `DataShareExtensionAbility` 的成本不低、收益不确定 → **V1 明确不做**，改为在卡片上放"查看全部"入口把用户导回应用。

### 5.5 快速完成 / 快速新建的交互路径

**快速完成**（卡片上每个任务的圆圈）
```
点击圆圈 ──▶ 本地先置灰（乐观更新，@State 改本地副本）
        └─▶ postCardAction(this, { action:'message', params:{ op:'toggle', id:'xxx', ts: Date.now() } })
              └─▶ onFormEvent 解析 ──▶ 读任务 ──▶ done = !done ──▶ 保存 ──▶ updateForm(新快照)
                    （幂等：以 ts 与当前 updatedAt 比较，过期消息直接丢弃）
```
- 必须**幂等 + 去重**：卡片可能连点、`updateForm` 可能乱序 → 用 `(id, ts)` 做最后写入优先。

**快速新建**（D1 最终采用 **B**，实机验证后由 A 改为 B）

| 方案 | 链路 | 优点 | 缺点 |
| --- | --- | --- | --- |
| A 一键建占位 | `message{op:'quickAdd'}` → 建 `{title:'新任务', dueAt:null, myDayDate:today}` → `updateForm` | 1 次点击、卡片立刻多一行 | 标题要进应用改 |
| **B 拉起轻编辑（现采用）** | `router` 带 `params.action='quickAdd'` → 应用打开新建面板（预填我的一天、无截止）→ 保存后 `terminateSelf()` **自动返回桌面** | 一次输完，卡片同步更新 | 打断桌面操作 |
| C 混合 | 短按 A + 右上角"编辑"入口进 B | 兼顾 | 实现量 +30% |

> 实机反馈：A 的"生成空任务再进应用改名"体验割裂，改为 B。`terminateSelf()` 只在"由卡片拉起"的流程里触发（`returnAfterSave` 标记），用户自己打开应用时不受影响。

- 注意 `router` 事件的 `params` 会作为 `Want.parameters` 进入 `EntryAbility.onCreate/onNewWant`，要处理**冷启动**与**热启动**两条分支（`onNewWant` 容易漏）。
- 卡片里 `TextInput` 不可用已确认，因此方案 A/B 之外没有第三条路。

### 5.6 代理提醒方案

**提醒条目模型**

```ts
interface ReminderPlan {
  taskId: string;
  kind: 'morning' | 'due10';   // 早上 / 截止前10分钟
  triggerAt: number;
  reminderId?: number;         // publishReminder 返回值
}
```

**排期规则（对应 D8/D3）**

| 任务情况 | 排几条 |
| --- | --- |
| 有截止日 + 无提醒日 | 2 条：`dueAt` 当天 08:00（D2）、`dueAt - 10min` |
| 有截止日 + 有提醒日 | 2 条：`remindAt`、`dueAt - 10min`（重复时间则合并为 1 条） |
| 无截止日 + 有提醒日 | 1 条：`remindAt` |
| 无截止日 + 无提醒日 | 不排（不占用 30 条预算） |

**预算与对账（`ReminderScheduler`）**

```
预算 = 28（留 2 条余量给系统/其他模块）
每次任务变更 / 每天 00:05 / 应用启动：
  1. valid = await reminderAgentManager.getValidReminders()   // 以系统为准对账
  2. 目标集 = 未完成 且 触发时间 > now 的 plan，按 triggerAt 升序
  3. 淘汰策略：先砍远期任务的 'morning'，再砍远期任务的 'due10'
  4. diff 后 cancelReminder(多余) + publishReminder(缺失)
  5. 每条 publish 成功立刻把 reminderId 回写到任务上（失败不影响主流程）
```

**其它要点**
- 权限：`ohos.permission.PUBLISH_AGENT_REMINDER` —— 已核实为 **normal 级别 + system_grant 系统授权，API 7 起**，列在官方"开放权限（面向所有应用开放）"清单里，**三方应用只需在 `module.json5` 声明，不需要 ACL**。但仍必须 `notificationManager.requestEnableNotification()` 拿到通知授权，否则代理提醒不可用；用户拒绝 → 卡片/应用内显示"提醒已关闭"的显式状态，而不是静默失败。
- `wantAgent` 指向 `EntryAbility`，`parameters: { taskId }`；`EntryAbility.onCreate/onNewWant` 解析后跳任务详情。
- `notificationId` 用 `taskId` 派生，保证同任务覆盖不重复弹。
- 提醒触发后 `getValidReminders` 里会消失（用户点 CLOSE 即过期），所以**不需要**在触发时清理，靠对账即可。

### 5.7 目录结构规划

```
entry/src/main/ets/
├── common/
│   ├── Models.ets            // TodoTask / ReminderPlan / MyDaySnapshot
│   ├── TimeUtil.ets          // 日期归一化、today()、dueAt 是否今天
│   └── Logger.ets            // hilog 封装（统一 domain/tag，便于过滤刷新链路）
├── data/
│   ├── TaskRepository.ets    // 接口 + 单例
│   ├── PreferenceTaskStore.ets  // GSKV（P0 定案后再决定是否保留 RDB 实现）
│   └── SettingsStore.ets     // 早上提醒时间等设置
├── service/
│   ├── MyDayService.ets      // 5.3 派生逻辑（纯函数，可单测）
│   ├── ReminderScheduler.ets // 5.6
│   └── FormBridge.ets        // 快照构建 + 刷新触发（reloadAllForms 封装/降级）
├── entryability/EntryAbility.ets
├── entryformability/TodoFormAbility.ets   // onAddForm/onUpdateForm/onFormEvent
├── widget/pages/MyDayCard.ets             // 卡片 UI
└── pages/
    ├── Index.ets                          // 我的一天 / 全部任务 双 Tab
    ├── components/TaskRow.ets
    └── components/TaskEditorSheet.ets     // 新建/编辑半模态（名称/截止/提醒/描述）
entry/src/main/resources/base/profile/form_config.json
```

---

## 6. 分阶段开发计划

| 阶段 | 内容 | 可验证产出（验收口径） | 预估 |
| --- | --- | --- | --- |
| **P0 打通链路（先做实验，别先做功能）** | 签名配置；最小卡片（`List` + 勾选 + "+"）；`message` 事件；`updateForm` 回推；**GSKV 跨进程读写实验**（卡片写、应用读，反之亦然）；`TextInput`/`Scroll` 不可用的反向确认 | 真机：桌面加卡片 → 点"+"卡片立刻多一行 → 杀掉应用再点仍生效；应用进程读得到卡片进程写的数据；日志里能看到 `onFormEvent`/`onUpdateForm` | 0.5–1 天 |
| **P1 数据层** | Models / TimeUtil / Repository（GSKV）+ `MyDayService` 派生逻辑 + 设置存储 | 单元测试（`entry/src/test`）：今天的边界、跨天、手动移出、逾期判定全部通过 | 1 天 |
| **P2 主应用 UI** | 双 Tab 列表（我的一天/全部任务）、任务行、新建/编辑半模态（4 字段 + 校验）、完成/删除、空态 | 手动回归：能建/改/删/完成；字段可空；重启应用数据仍在 | 2 天 |
| **P3 服务卡片** | `form_config.json`（3 尺寸、定点刷新）、`MyDayCard`（滑动列表、勾选、+、空态、深浅色）、`TodoFormAbility`（onAddForm/onUpdateForm + 快照构建） | 桌面加三种尺寸卡片；上下滑动流畅；深浅色正确；卡片进程被杀后重启仍显示正确数据 | 1.5 天 |
| **P4 刷新闭环** | 卡片 → 应用（`reloadAllForms`）、应用 → 卡片、回前台重载、幂等/乱序防护、全链路日志埋点 | 时序验证：应用内完成 → 1s 内卡片变化；卡片勾选 → 进应用即已勾选；连续快速点击不出错 | 1 天 |
| **P5 代理提醒** | `ReminderScheduler`（排期/淘汰/对账）、权限与通知授权引导、点通知跳任务详情、设置页改早上时间 | 把截止时间设为 12 分钟后：收到"截止前 10 分钟"提醒；点通知打开对应任务；有效提醒数 ≤ 30 | 1.5 天 |
| **P6 打磨与验收** | 异常兜底（存储失败/权限拒绝/快照损坏）、无障碍与文案、性能（卡片刷新耗时）、真机回归清单、README | 回归清单全绿；`hilog` 抽样无 ERROR；卡片刷新 p90 < 300ms | 1 天 |

**总预估 8–9 个工作日**（单人）。P0 是**门禁**：如果 P0 里任何一个能力在真机上不成立（例如卡片 `List` 滑动被桌面吃掉、GSKV 多进程不可用），方案要回退调整，所以先把 P0 做过再谈排期。

---

## 7. 风险清单

| # | 风险 | 影响 | 缓解 |
| --- | --- | --- | --- |
| R1 | **30 条代理提醒上限** | 任务多了提醒被静默丢弃 | 预算 28 + 淘汰策略 + 对账；超额时应用内显式提示"仅近 48 小时任务会提醒" |
| R2 | **卡片不可见时不刷新** | 用户切回桌面看到旧数据 | 所有"数据变更"都主动 `updateForm`，不依赖定时；`onAddForm` 永远返回最新快照 |
| R3 | **跨进程一致性** | 卡片改了数据，应用界面不更新 | 应用 `onForeground`/`onPageShow` 必重读；P4 才考虑 dataShare 观察者 |
| R4 | **存储多进程安全** | 数据损坏/丢失（XML Preferences 明确会损坏；RDB 跨进程未背书） | 只用 GSKV；P0 做双进程读写压测；进程内写入串行化；GSKV 不可用时降级为"卡片只读、写操作回应用" |
| R5 | **卡片 UI 能力受限**（无 TextInput、无左右滑动、动效有限） | 交互设计与手机 App 不一致 | 已确认限制并据此设计（D1）；不追求卡片内富交互 |
| R6 | **`FormExtensionAbility` 只活 ~10 秒** | 卡片里做重活会被杀，数据写一半 | 卡片路径只做单条读改；大批量（如"全部完成"）走 `router` 回应用做 |
| R7 | **`reloadAllForms` 是 API 22+**，兼容版本是 24 / target 26 | 低版本设备无此接口 | `canIUse('SystemCapability...')`/try-catch 降级；本项目最低 24，实际可用 |
| R8 | **通知权限被拒** | 提醒完全不生效 | 首启引导 + 设置页状态显示 + 卡片角标提示 |
| R9 | **无法在模拟器/预览器验证卡片真实性**（卡片、代理提醒都要真机/至少模拟器 20+） | 迭代慢 | 提前确认真机可用；P0 就在真机上做 |
| R10 | **官方文档版本差**（我看的是 OpenHarmony master ≈ API 26，官网 HarmonyOS 6.x 页面可能滞后/超前） | 按文档写完发现 API 不存在 | 以本机 SDK 的 `.d.ts` 为准（已用 `@form` 标记核对组件能力）；P0 逐条实测 |

---

## 8. 待核实项（不影响方向，影响细节）

| # | 待核实 | 现状 | 计划 |
| --- | --- | --- | --- |
| V1 | ~~`PUBLISH_AGENT_REMINDER` 的权限级别/是否需 ACL~~ | ✅ **已核实：normal + system_grant，无需 ACL** | 只需声明权限 + 请求通知授权 |
| V2 | RDB 跨进程读写是否可靠 | 文档既未支持也未禁止，且"不同 Context 会产生多个数据库" | **已据此改用 GSKV**；RDB 只作为"数据量变大后"的未来选项 |
| V3 | 卡片内 `List` 纵向滑动在 2*2 小尺寸下的实际手感（是否与桌面上下滑动手势冲突） | 文档说 List 支持卡片、卡片内不支持左右滑动；纵向未明说冲突 | P0 真机实测；若冲突 → 卡片改为"3 条 + 查看更多"分页 |
| V4 | `TextInput`/`DatePicker`/`TimePicker`/`Scroll` 在卡片中不可用 | ✅ **已双重确认**（SDK `@form` 标记为 0 + 官方文档全文无"卡片能力"标注） | P0 用一个最小卡片做一次反向确认即可（防 SDK 与运行时不一致） |
| V5 | 官网 HarmonyOS 6.x 文档与 OpenHarmony master 的差异 | 已知存在版本差（例：`conditionUpdate` 在 master 标 API 26 生效） | 编码时以本机 SDK `.d.ts` + 真机为准 |
| V6 | 卡片刷新单次数据 10MB 限制对我们是否有影响 | 快照很小（< 10KB），无影响 | — |
| V7 | "定点刷新 + 读取时派生"能否满足"次日 0 点后卡片立即是新一天" | 定点刷新只在卡片可见时触发（官方明确） | P0/P3 实测：0 点后第一眼看到卡片时数据是否正确；不行则加"卡片可见时 onSizeChanged/onAddForm 兜底" |
| V8 | `updateForm` 是否有未写进文档的频率限制 | 文档未写 | 实现上合并同帧刷新；P4 埋点观察有没有被系统丢掉的推送 |

---

## 9. 官方文档索引（我实际读过的原文）

| 主题 | 官网 | 原文（OpenHarmony docs master） |
| --- | --- | --- |
| 卡片页面刷新概述（数据交互/约束） | [链接](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-v5/arkts-ui-widget-interaction-overview-V5) | `zh-cn/application-dev/form/arkts-ui-widget-interaction-overview.md` |
| 卡片主动刷新（updateForm / reloadForms） | [链接](https://developer.huawei.com/consumer/cn/doc/harmonyOS-references/js-apis-app-form-formprovider) | `form/arkts-ui-widget-active-refresh.md` |
| 卡片被动刷新（定时/定点/条件 + 50 次配额） | [链接](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-v5/arkts-ui-widget-passive-refresh-V5) | `form/arkts-ui-widget-passive-refresh.md` |
| 卡片事件（router/message/call） | [链接](https://developer.huawei.com/consumer/cn/doc/harmonyOS-references/js-apis-postcardaction) | `form/arkts-ui-widget-event-overview.md` |
| 卡片配置（form_config 字段） | [链接](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-v5/arkts-ui-widget-configuration-V5) | `form/arkts-ui-widget-configuration.md` |
| 卡片进程模型 / 生命周期 | — | `form/arkts-ui-widget-process.md`、`form/arkts-ui-widget-lifecycle.md` |
| 卡片界面能力 | — | `form/arkts-ui-widget-page-overview.md`、`form/arkts-form-overview.md` |
| 代理提醒 | [链接](https://developer.huawei.com/consumer/cn/doc/harmonyOS-references/js-apis-reminderagentmanager) | `task-management/agent-powered-reminder.md` |
| 延迟任务（workScheduler，不精准） | — | `task-management/work-scheduler.md` |
| 用户首选项（XML/GSKV 多进程差异） | — | `database/data-persistence-by-preferences.md` |

> 说明：华为官网文档页是 JS 渲染的，抓取正文失败，因此正文读的是 OpenHarmony 官方仓库的 Markdown 源码（同一份内容的上游），并附官网页面链接供你核对。**凡两者可能不一致的地方，以本机 SDK 声明和真机行为为准。**

---

## 10. 下一步

请确认第 4 节的 D1–D8（尤其是 **D1 快速新建方式**、**D3 提醒预算策略**、**D4 我的一天跨天语义**），以及是否接受"P0 先做真机能力实验、再按结果微调方案"的节奏。确认后我按 P0 → P6 开始编码，每个阶段结束给你可验证的产出。

---

## 11. 实施状态（自底向上已落地）

实际采取的决策（未确认项按建议值实现，均可改）：D1=A（卡片一键建占位任务）、D2=08:00 可设置、D3=预算 28 + 按触发时间裁剪、D4/D5=每天清空、D6=三种尺寸、D7 不做重复任务、D8=有截止日即提醒。

| 层 | 文件 | 状态 |
| --- | --- | --- |
| 底层数据 | `common/{Models,TimeUtil,Logger,AppConfig}.ets`、`data/{TaskStore,TaskRepository,SettingsStore}.ets` | ✅ 编译通过，纯逻辑有单测 |
| 派生逻辑 | `service/MyDayService.ets` | ✅ 单测行覆盖 92.7% |
| 系统调用 | `service/{ReminderScheduler,FormBridge}.ets`；`module.json5` 权限与 form 扩展 | ✅ 编译通过；真机行为待验 |
| 卡片 | `form_config.json`、`entryformability/TodoFormAbility.ets`、`widget/pages/MyDayCard.ets` | ✅ 编译通过；滑动/刷新待真机验 |
| 应用 UI | `pages/Index.ets`、`pages/components/{TaskRow,TaskEditorSheet}.ets` | ✅ 编译通过 |
| 验证 | `assembleHap` 成功产出 `entry-default-unsigned.hap`；`hvigor test` 跑通本地单测（MyDayService 92.7% / TimeUtil 71% / Models 51%） | ✅ |
