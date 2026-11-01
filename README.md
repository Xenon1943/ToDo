# ToDo · HarmonyOS 待办 + 「我的一天」服务卡片

DevEco Studio 标准 Stage 工程（bundle `com.xenon.todo`，SDK HarmonyOS 26.0.0 / apiVersion 26，兼容 6.1.1(24)）。

开发方案与调研结论见 [docs/开发方案-鸿蒙TODO服务卡片.md](docs/开发方案-鸿蒙TODO服务卡片.md)。

---

## 已实现

| 需求 | 实现方式 |
| --- | --- |
| 任务字段：名称 / 截止日期 / 提醒日期 / 描述 | `TodoTask`（`dueAt`/`remindAt` 用 0 表示空），面板 `TaskEditorSheet` |
| 分类：我的一天 / 全部任务 | 分段切换；**不落库，读取时派生**（`MyDayService`） |
| 卡片显示我的一天 + 上下滑动 | `MyDayCard` 用 `List`（卡片内 `Scroll` 不可用，`List` 可用） |
| 卡片快速完成 | 勾选 → `postCardAction(message)` → `onFormEvent` → 写库 → `updateForm` 回推，带 `(id, ts)` 幂等去重 |
| 卡片快速新建（无截止日期） | 点 `＋` → `router` 拉起应用的新建页（卡片内没有 `TextInput`），保存/取消后**自动返回桌面** |
| 卡片点任务 → 任务详情 | 点任务标题 → `router(openTask)` → 应用打开该任务的详情面板 |
| 卡片点空白 → 我的一天 | 卡片容器 `onClick` → `router(openMyDay)`（子组件手势优先，不会与任务点击冲突） |
| 完成动画 | 应用内：`animateTo` + `ListItem.transition`（淡出 + 左移，后面的行上移）；卡片内不能用 `animateTo`/`setTimeout`，改用隐式动画 `.animation()` + 权威快照驱动删除 |
| 下拉刷新 | `Refresh` + 自定义指示器：下拉时箭头按位移旋转（0→180°），过阈值提示"松手刷新"，刷新中换成 `LoadingProgress`；刷新会强制重读存储（另一个进程可能改过）并顺带推一次卡片 |
| 分段切换 | 方向感过渡：「全部任务」在右 → 从右侧滑入；「我的一天」在左 → 从左侧滑入（`TransitionEffect.asymmetric`），切换期间临时关掉行级过渡避免"整页从左浮起" |
| 全屏 | `setWindowLayoutFullScreen(true)` + 背景层 `expandSafeArea(TOP/BOTTOM)` 铺到状态栏/导航栏下；**内容层不压状态栏**——`EntryAbility` 用 `getWindowAvoidArea(TYPE_SYSTEM)` 量出状态栏高度塞进 `AppStorage`，页面按 `px2vp(statusBarPx)` 让位，底部则延伸到底 |
| 长按拖拽排序 | 「我的一天」列表：长按成功 → 该行**浮起**（阴影 + 略透明，180ms 渐入，普通滑动不触发）→ 拖动时 `onItemDragMove` 实时换位，其他行在 `animateTo` 里**上下让路**（换位期间禁用行级过渡，避免整行往左甩）→ 松手才把 `order` 落库；拖到非法区域会还原 |
| UI | 页面用 `page_bg` 浅灰底，列表放进 18vp 圆角白卡（带轻阴影），标题/分段条与事项在视觉上分开；新建按钮用两条圆角矩形画「＋」，避免字体字形偏移 |
| 卡片实时更新 | 应用内变更：`getPublishedRunningFormInfos()` 拿 formId → 逐张 `updateForm` **直推**（失败才退回 `reloadAllForms`）；卡片内变更：卡片进程直接 `updateForm` |
| 截止当天自动进入我的一天 | 派生条件：`dueAt 落在今天` 且未被当天手动移出（`myDayHiddenOn`），零后台任务。**跨天不发生搬移**：昨天没做完的任务（手动加入的 / 已逾期的）今天自动顺延进"我的一天"，行上标「顺延」 |
| 智能提醒 | 代理提醒（日历型）：截止当天早上（默认 08:00，可设置）+ 截止前 10 分钟；单应用 30 条上限用预算 28 + 账本增量对账 |

## 目录结构

```
entry/src/main/ets/
├── common/
│   ├── Models.ets          # TodoTask / 卡片快照 / 卡片消息 / 编辑草稿
│   ├── TimeUtil.ets        # 日期归一化、今天判定、格式化
│   ├── Logger.ets          # hilog 封装（过滤关键字见下）
│   └── AppConfig.ets       # bundle/ability/form 名称等常量
├── data/
│   ├── TaskStore.ets       # GSKV Preferences 存储（跨进程安全）+ 版本号缓存
│   ├── TaskRepository.ets  # 业务读写入口
│   └── SettingsStore.ets   # 早上提醒时间等设置
├── service/
│   ├── MyDayService.ets    # "我的一天"派生 + 卡片快照（纯函数）
│   ├── ReminderScheduler.ets # 代理提醒排期/预算/对账
│   └── FormBridge.ets      # 卡片快照构建 + reloadAllForms/updateForm
├── entryability/EntryAbility.ets        # 冷/热启动参数（卡片 router、提醒 uri）
├── entryformability/TodoFormAbility.ets # 卡片提供方（onAddForm/onUpdateForm/onFormEvent）
├── widget/pages/MyDayCard.ets           # 卡片 UI（2*2 / 2*4 / 4*4）
└── pages/
    ├── Index.ets                        # 双 Tab 列表 + 新建按钮 + 设置
    └── components/{TaskRow,TaskEditorSheet}.ets
entry/src/main/resources/base/profile/form_config.json
```

## 构建

DevEco Studio 里直接 Build 即可；命令行（用 DevEco 自带的 hvigor + node）：

```bash
export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"
export NODE_PATH="C:/Program Files/Huawei/DevEco Studio/tools/hvigor"
node "C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/bin/hvigor.js" \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`（未签名，装机需在 DevEco 里配置自动签名）。

单元测试（纯逻辑，无需设备）：

```bash
node ".../hvigor/bin/hvigor.js" test --mode module -p module=entry@default -p product=default --no-daemon
# 覆盖率报告：entry/.test/default/outputs/test/reports/
```

## 关键设计说明

1. **存储必须是 GSKV 模式的 Preferences**。卡片提供方与应用主进程是**两个进程**、共享同一沙箱；XML 模式官方明确"不支持多进程"，会损坏文件。`getAllSync()` + `meta:version` 版本号做跨进程缓存失效。
2. **卡片数据只能推，不能拉**。卡片 UI 通过 `@LocalStorageProp('myday')` 接收一段 JSON 字符串（框架会转成 string），进度/条目全部由快照渲染。
   - 推送走"直推"优先：`formProvider.getPublishedRunningFormInfos()`（API 20+）拿到已加桌的 `formId`，逐张 `updateForm`；只有枚举失败或有卡片推失败时，才退回 `reloadAllForms`（那条链路要经 FMS 拉起卡片进程，体感明显更慢）。
3. **"我的一天"不落库**。跨天由派生规则算出来，避免依赖不精准的 `workScheduler` 或"卡片可见才触发"的定点刷新。当前规则（`MyDayService.inScope`，按优先级）：
   1. 今天被手动移出过（`myDayHiddenOn == today`）→ 不出现；
   2. `myDayDate == today`（今天手动加入）→ 出现；
   3. `dueAt` 是今天 → 出现；
   4. `dueAt` 已逾期且没做完 → 出现（顺延）；
   5. `myDayDate` 是以前的日期且没做完 → 出现（顺延）；
   6. 以上情况若"今天完成"，仍计入今天的 `total/done`（只是不进列表）。

   计数口径：`total` 含已完成、`items` 只放未完成，避免做完最后一个任务显示成 `1/0`。
4. **提醒预算 28 条**。`ReminderScheduler` 用 `reminder:<taskId>` 账本记录签名与 id，只有签名变化才重发，避免抖动与超限。
5. **表单主体用 `List` 不用 `Scroll`**。`Scroll` 的子组件在内容不足一屏时会被垂直居中（实机上表现为"标题输入框跑到面板中部"），`List` 始终从顶部排布且能滚动。
6. **卡片里的点击不要用"背景层 + `hitTestBehavior(Transparent)`"**。`Transparent` 不阻塞兄弟节点，会让"点任务"同时触发"点空白"。正确做法是容器 `onClick`，子组件（任务行、勾选、`＋`）自己的手势优先，不会冒泡。
7. **卡片（form 应用）里 `animateTo` / `getUIContext` / `setTimeout` 一律编译报错**。卡片只有 `.animation()`（隐式属性动画）可用，所以"勾选后淡出"是这么做的：标记 `leavingId` → `.animation()` 让该行淡出左移 → 消息发出去 → 服务端回推的新快照里已经没有它 → `onRawChanged` 清标记。删除动作由权威数据驱动，不靠定时器。
8. **列表项排序用 `order` 字段**（不是数组位置）。老数据 `order=0` 时回退按 `createdAt`，新建任务取 `max(order)+1000`，拖拽后对「我的一天」里的任务重编号（步长 1000），批量写入只 bump 一次版本号。排序**不改 `updatedAt`**——排序不是内容变更。
9. **`ForEach` 的 key 必须带上会影响行渲染的字段**（`${id}:${done?1:0}:${updatedAt}`）。踩过的坑：为了拖拽动画把 key 简化成纯 `id` 之后，在「全部任务」里取消勾选，数据变了但行不重建，界面看起来没反应；纯 `id` 的 key 只在 item 被增删时生效。
10. 同理，行内容**不要**通过 `@Builder fn(task)` 按值传参渲染——`@Builder` 按值传参不参与刷新，改回在 `ForEach` 里直接构造 `TaskRow({...})` 最稳。
11. **写入 → 刷新走事件，不靠"记得调"**。`TaskRepository` 每次落库都会 `notify(reason)`，页面在 `aboutToAppear` 注册监听、`aboutToDisappear` 注销，统一走 `refresh(animate)` 管线（重算界面 → 推卡片 → 对账提醒）。`reason` 决定要不要播动画：只有 `create / toggle / delete` 播，`update / order / external` 不播。
12. **`@Builder` 里的按钮不会因为参数没变而重绘**。「今天/明天」这类按钮直接写在 `build()` 里，并在 Text 上挂 `.animation()`，颜色切换才有过渡且即时生效。
13. **`bindSheet` 的内容不要按 `showEditor` 条件渲染**。关面板时把内容抽掉，收起动画会因为内容消失卡成一片白、甚至不退出；面板内容始终挂载，靠 `@Prop initDraft + draftVersion(@Watch)` 复位状态。
14. **动效参数统一在 `common/Motion.ets`**：时长（FAST/NORMAL/REORDER）、曲线、行增删过渡（`asymmetric`：新增只淡入、删除才淡出+左移）、切页滑动、浮起/预览阴影。卡片（form 应用）只用其中的常量，动画靠 `.animation()` 隐式播放。

## 应用图标

分层图标（HarmonyOS 规范：1024×1024 背景层 + 前景层，由桌面裁剪形状）：

| 资源 | 内容 |
| --- | --- |
| `AppScope/resources/base/media/background.png` | 高级蓝渐变（`#2F6BFF` → `#0B2FAE`，135°），左上柔光 + 底部微暗做纵深 |
| `AppScope/resources/base/media/foreground.png` | 透明前景：白色圆头对号（按画布中心放大 1.18 倍），下方 22% 黑色轻投影（偏移 8px、模糊 14px） |
| `entry/src/main/resources/base/media/{background,foreground}.png` | 同上（ability 图标用的是 entry 侧这份） |
| `entry/src/main/resources/base/media/startIcon.png` | 启动页图标，152×152 圆角蓝底 + 对号（从 608px 渲染后降采样） |

图标由脚本生成，改色/改形状只需改参数后重跑：

```bash
python tools/gen_icon.py    # 同时输出 docs/icon-preview.png 预览图
```

![图标预览](docs/icon-preview.png)

## 调试要点

`hilog` 过滤关键字（`hdc shell hilog | grep TodoApp`）：

- `[Repo]`：存储初始化/重载/写入（`store init ok, gskv=true` 必须出现，否则落在 XML 模式，跨进程不安全）
- `[Form]`：卡片生命周期与刷新（`onAddForm` / `onUpdateForm` / `onFormEvent` / `updateForm ok` / `direct push 2/2`）
- `[Reminder]`：排期、预算裁剪、发布/取消、有效条数
- `[Ability]`：冷启动/热启动参数

## 需要在真机上确认的清单（P0 门禁项）

- [ ] 桌面添加 2*2 / 2*4 / 4*4 卡片，`List` 能纵向滑动且不与桌面手势冲突
- [ ] 勾选任务：应用内行淡出左移、后面的行上移；卡片内该行淡出后消失
- [ ] 长按拖动「我的一天」里的任务可换位，回到桌面卡片顺序一致（重启后仍保持）
- [ ] 卡片上勾选 → 卡片立即刷新；进入应用后该任务已是完成态
- [ ] 卡片上 `＋` → 直接打开应用的新建页（不是生成空任务），保存后自动回到桌面且卡片已更新
- [ ] 卡片上点任务标题 → 打开该任务详情；点卡片空白 → 打开「我的一天」
- [ ] 新建面板里标题输入框在最上方，日期选择器展开后表单可滚动
- [ ] 应用内新建/完成 → 卡片 1 秒内变化（`reloadAllForms` 是否生效）
- [ ] 杀进程后卡片数据仍在（跨进程读同一份存储）
- [ ] 截止时间设为 12 分钟后 → 收到"截止前 10 分钟"提醒，点通知回到对应任务
- [ ] 通知权限被拒绝时，应用顶部出现"提醒未开启"提示且不崩溃

## 已知限制

- 卡片内不能输入文本、不能选日期（`TextInput`/`DatePicker`/`TimePicker`/`Scroll` 均无卡片能力），所以「快速新建」只能一键建占位任务。
- 卡片不可见时系统不会触发定点刷新；跨天正确性依赖应用/卡片下次可见时的派生逻辑。
- 提醒上限 30 条：任务很多时只有最近的提醒会被排上（预算 28），界面暂无"超额提示"文案。
- 未做数据迁移（schema 版本），字段变更需自行处理。
