# ToDo · HarmonyOS 待办 + 「我的一天」服务卡片

一个用 ArkTS / ArkUI 写的 HarmonyOS 待办应用，带桌面服务卡片：卡片里可以直接勾选完成、快速新建，应用内的改动会立刻推到卡片上。

[![repo](https://img.shields.io/badge/GitHub-Xenon1943%2FToDo-0A59F7)](https://github.com/Xenon1943/ToDo)

- 工程：DevEco Studio 标准 Stage 工程，bundle `com.xenon.todo`
- SDK：HarmonyOS **26.0.0**（apiVersion 26），兼容 **6.1.1(24)**
- 规模：`entry/src/main/ets` 下 18 个 `.ets`、约 3565 行；单测 4 个 suite / 33 条用例
- 依赖：运行时零三方依赖（仅测试用 `@ohos/hypium`、`@ohos/hamock`）

设计文档：[开发方案与调研](docs/开发方案-鸿蒙TODO服务卡片.md) · [技术报告](docs/技术报告.md) · [ArkUI API 笔记](docs/API-笔记.md)

---

## 功能

### 主应用

| 能力 | 说明 |
| --- | --- |
| 双分类 | 「我的一天」/「全部任务」，点分段或**左右滑动**切换 |
| 任务字段 | 名称、截止日期、提醒日期、描述（后两者可为空） |
| 增删改 | 半模态面板新建/编辑；勾选完成；**左滑任务行**露出「我的一天 / 删除」 |
| 跨天顺延 | 昨天没做完的（手动加入的、已逾期的）今天仍出现在「我的一天」，行上标「顺延」 |
| 拖拽排序 | 「我的一天」里长按拖动换位，行内留淡色空位、其他行上下让路；顶部实时提示「第 x / y 位」，拖到最后显示「松手 → 放到最后」 |
| 下拉刷新 | 自定义指示器：下拉时箭头随位移旋转，过阈值提示「松手刷新」，刷新中转为转圈 |
| 动效 | 完成时行淡出左移、切页方向感滑动、长按按下即下凹、卡片内勾选淡出 |
| 全屏 | 背景铺满状态栏/导航栏，内容按安全区让位（不压状态栏） |
| 提示 | 通知未开启 / 本地存储不可用 都有顶部横幅 |

### 服务卡片

| 能力 | 说明 |
| --- | --- |
| 尺寸 | `2*2` / `2*4` / `4*4`，纵向滚动列表 |
| 快速完成 | 点圆圈 → `postCardAction(message)` → 卡片进程写库 → 回推新快照，带 `(id, ts)` 幂等去重 |
| 快速新建 | 点 `＋` → `router` 拉起应用新建页（卡片内没有输入框），保存/取消后**自动返回桌面** |
| 进详情 / 进应用 | 点任务标题进任务详情；点卡片空白进「我的一天」 |
| 实时刷新 | 应用内任何改动都会立刻推卡片，见下文「刷新架构」 |

### 智能提醒

代理提醒（日历型）：**截止当天早上（默认 08:00，可设置）+ 截止前 10 分钟**。单应用上限 30 条 → 预算 28 条 + 账本增量对账。

---

## 架构

```
┌─────────────────────────────┐        ┌──────────────────────────────┐
│ 主应用进程 (UIAbility)       │        │ 卡片提供方进程 (FormExtAbility)│
│  pages/Index.ets            │        │  TodoFormAbility.ets         │
│   ├ TaskRow                 │        │   └ onFormEvent → 写库 → 回推 │
│   └ TaskEditorSheet         │        │                              │
│  EntryAbility（全屏/安全区）  │        │  widget/pages/MyDayCard.ets  │
└──────────┬──────────────────┘        └───────────▲──────────────────┘
           │ 写                                    │ 推
           ▼                                      │
   ┌──────────────────────────────────────────────┴─────┐
   │ data/TaskStore.ets   GSKV Preferences（跨进程安全）  │
   │ data/TaskRepository.ets  写入 + notify(reason)      │
   └───────────────────────┬────────────────────────────┘
                           │ 事件
         ┌─────────────────┴─────────────────┐
         ▼                                   ▼
 service/MyDayService.ets            service/ReminderScheduler.ets
 （纯函数：scope/stats/items/move）    （代理提醒预算与对账）
         │
         ▼
 service/FormBridge.ets（快照 + 直推 updateForm + reloadAllForms 兜底）
```

**刷新架构（核心）**

```
任意写操作 → TaskRepository.notify(reason)
           → 页面监听器 → refresh(animate)
                 ├─ applyState(animate)      重算界面（animate 决定是否包 animateTo）
                 ├─ FormBridge.refreshAll()  ① 直推 updateForm ② 必走 reloadAllForms
                 └─ ReminderScheduler.sync() 提醒对账
```

`reason` 决定动画：`create / toggle / delete` 播；`update / order / external` 不播（编辑时行 key 会变，播了会像被删除）。

## 目录结构

```
entry/src/main/ets/
├── common/
│   ├── Models.ets          # TodoTask / 卡片快照 / 卡片消息 / 编辑草稿
│   ├── TimeUtil.ets        # 日期归一化、今天判定、格式化
│   ├── Motion.ets          # 动效基线：时长/曲线/过渡/阴影
│   ├── Logger.ets          # hilog 封装
│   └── AppConfig.ets       # bundle/ability/form 常量
├── data/
│   ├── TaskStore.ets       # GSKV Preferences（跨进程安全）+ 版本号缓存
│   ├── TaskRepository.ets  # 写入 + 变更事件（onChange/notify）+ order 分配
│   └── SettingsStore.ets   # 早上提醒时间等设置
├── service/
│   ├── MyDayService.ets    # 「我的一天」派生（纯函数，可单测）
│   ├── ReminderScheduler.ets # 代理提醒排期 / 预算 / 对账
│   └── FormBridge.ets      # 卡片快照 + 推送
├── entryability/EntryAbility.ets          # 全屏、安全区、冷/热启动参数
├── entryformability/TodoFormAbility.ets   # 卡片提供方
├── widget/pages/MyDayCard.ets             # 卡片 UI
└── pages/
    ├── Index.ets                          # 列表 / 切页 / 拖拽 / 下拉刷新
    └── components/{TaskRow,TaskEditorSheet}.ets

tools/gen_icon.py                          # 生成分层图标 + 预览图
entry/src/main/resources/base/profile/form_config.json
```

## 构建与测试

DevEco Studio 里直接 Build/Run；命令行（用 DevEco 自带的 hvigor + node）：

```bash
export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"
export NODE_PATH="C:/Program Files/Huawei/DevEco Studio/tools/hvigor"
node "$NODE_PATH/hvigor/bin/hvigor.js" assembleHap \
  --mode module -p product=default -p buildMode=debug --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`（装了签名配置时）/ `entry-default-unsigned.hap`。

单元测试（纯逻辑，不需要设备）：

```bash
node "$NODE_PATH/hvigor/bin/hvigor.js" test --mode module \
  -p module=entry@default -p product=default --no-daemon
# 覆盖率报告：entry/.test/default/outputs/test/reports/
```

> ⚠️ 这套本地单测**断言失败不会让 `hvigor test` 返回失败**（构建仍 SUCCESS，只在日志里出现 `AssertException`）。判据请用：
> `grep -c AssertException <日志>` == 0。

覆盖率（逻辑层）：`MyDayService` 93.1% / `TimeUtil` 71.2% / `Models` 51.0%，整模块 13.9%（UI 与系统 API 未纳入）。

### 签名配置（重要）

`build-profile.json5` 里的 `signingConfigs` 含 keystore 路径与口令，**不要提交到公开仓库**。
本仓库的版本是脱敏的（`"signingConfigs": []`）；本地通过

```bash
git update-index --skip-worktree build-profile.json5
```

把它标记为本地专属，签名配置不会被 `git add -A` 带上。换机器后重新生成一次即可：
`File > Project Structure > Signing Configs > Automatically generate signature`。

## 关键设计说明

1. **存储必须是 GSKV 模式的 Preferences**。卡片提供方与应用主进程是**两个进程**、共享同一沙箱；XML 模式官方明确"不支持多进程"，会损坏文件。`getAllSync()` + `meta:version` 做跨进程缓存失效，读写都返回拷贝。
2. **写入 → 刷新走事件，不靠"记得调"**。`TaskRepository` 每次落库都 `notify(reason)`，页面订阅后统一走 `refresh(animate)`。
3. **卡片数据只能推，不能拉**。走两条通道：`getPublishedRunningFormInfos()`（API 20+）拿 formId 逐张 `updateForm` 直推；**并且**再调一次 `reloadAllForms` 让 FMS 拉起卡片进程重读——两条都走才保证"改完就能看到"。
4. **「我的一天」不落库**，读取时派生（`MyDayService.inScope`，按优先级）：
   1. 今天被手动移出过 → 不出现；
   2. `myDayDate == 今天`（今天手动加入）→ 出现；
   3. `dueAt` 是今天 → 出现；
   4. `dueAt` 已逾期且没做完 → 出现（顺延）；
   5. `myDayDate` 是过去日期且没做完 → 出现（顺延）；
   6. 以上情况"今天完成"→ 仍计入当天 `total/done`，但不进列表。

   计数口径：`total` 含已完成、`items` 只放未完成（否则做完最后一个会显示 `1/0`）。
5. **提醒预算 28 条**（上限 30）。`ReminderScheduler` 用 `reminder:<taskId>` 账本记录签名与 id，签名（kind@时间@标题）不变就不重发，避免抖动与超限；进程内加了重入闸门。
6. **动效统一在 `common/Motion.ets`**：时长（FAST/NORMAL/REORDER）、曲线、行增删过渡（`asymmetric`：新增只淡入、删除才淡出+左移）、阴影。切页不用 `transition`——transition 会让新旧两页同时挂在树上，改成"新页先偏移、下一帧滑回 0"的位移动画。
7. **卡片（form 应用）里 `animateTo` / `getUIContext` / `setTimeout` 是编译期错误**。卡片只能用 `.animation()` 隐式动画，所以"勾选后淡出"是：标记 `leavingId` → 隐式动画淡出左移 → 发消息 → 新快照里没有它 → `onRawChanged` 清标记。
8. **手势分工**：任务行**左滑**＝操作菜单（`swipeAction.end`），行**右滑**与标题/分段/空白的左右滑＝切页（页面根节点 `PanGesture`）。子组件手势优先，行上左滑不会误触发切页。
9. **列表项排序用 `order` 字段**（不是数组位置）。老数据 `order=0` 回退按 `createdAt`；新建取 `max(order)+1000`；拖拽后对「我的一天」重编号（步长 1000），批量写入只 bump 一次版本号；排序**不改 `updatedAt`**。
10. **`ForEach` 的 key 必须带上影响行渲染的字段**（`${id}:${done?1:0}:${updatedAt}`）。曾为了拖拽动画简化成纯 `id`，结果取消勾选后行不重建、界面无反应。
11. **行内容不要用 `@Builder fn(task)` 按值传参渲染**，`@Builder` 按值传参不参与刷新；直接在 `ForEach` 里构造 `TaskRow({...})`。
12. **`@Builder` 里的按钮不会因参数未变而重绘**。「今天/明天」这类按钮直接写在 `build()` 里并挂 `.animation()`，颜色切换才即时且有过渡。
13. **`bindSheet` 内容不要按 `showEditor` 条件渲染**。关面板时抽掉内容会让收起动画卡成白屏；内容常驻，靠 `@Prop initDraft + draftVersion(@Watch)` 复位。
14. **表单主体用 `List` 不用 `Scroll`**（`Scroll` 内容不足一屏会垂直居中）；日期/时间选择器**纵向各占满宽**（并排时 `DatePicker` 会被挤成 0 宽）。
15. **全屏不等于压状态栏**：`setWindowLayoutFullScreen(true)` 后框架不会自动避让，需用 `getWindowAvoidArea(TYPE_SYSTEM)` 量出高度再给内容让位。

## 应用图标

分层图标（1024×1024 背景层 + 前景层，由桌面裁剪形状）：

| 资源 | 内容 |
| --- | --- |
| `background.png` | 高级蓝渐变（`#2F6BFF` → `#0B2FAE`，135°）+ 左上柔光 + 底部压暗 |
| `foreground.png` | 透明前景：白色圆头对号（按画布中心放大 1.18 倍）+ 22% 黑色轻投影 |
| `startIcon.png` | 启动页图标 152×152，圆角蓝底 + 对号 |

改色/改形状只需改脚本参数后重跑：

```bash
python tools/gen_icon.py    # 同时刷新 docs/icon-preview.png
```

![图标预览](docs/icon-preview.png)

## 调试

```bash
hdc shell hilog | grep TodoApp
```

| 关键字 | 关注点 |
| --- | --- |
| `[Repo]` | `store init ok, gskv=true` 必须出现（落到 XML 模式就没有跨进程安全） |
| `[Form]` | `onAddForm` / `onUpdateForm` / `onFormEvent` / `direct push n/m` / `reloadAllForms ok` |
| `[Reminder]` | 排期、预算裁剪、发布/取消、有效条数 |
| `[Ability]` | 全屏是否设成功、安全区高度、冷/热启动参数 |

## 真机验证清单

- [ ] 三种尺寸卡片可加桌，`List` 纵向滑动不与桌面手势冲突
- [ ] 应用内新建/编辑/勾选/删除 → 卡片 1 秒内变化（日志出现 `direct push` + `reloadAllForms`）
- [ ] **编辑保存**只原地更新，不播"删除"动画
- [ ] 任务行**左滑**出「我的一天 / 删除」；在**标题/分段条**上左右滑能双向切页
- [ ] 长按任务：按下即变深微缩；拖动时行内留淡色空位、其他行平滑让路；顶部提示「第 x / y 位」/「松手 → 放到最后」
- [ ] 卡片勾选 → 该行淡出消失；卡片 `＋` → 打开新建页，保存后自动回桌面且卡片已更新
- [ ] 卡片点任务进详情、点空白进「我的一天」
- [ ] 截止时间设为 12 分钟后 → 收到"截止前 10 分钟"提醒，点通知回到对应任务
- [ ] 拒绝通知权限后，应用顶部出现提示且不崩溃
- [ ] 杀进程后卡片数据仍在（跨进程读同一份存储）

## 已知限制

- 卡片内不能输入文本、不能选日期（`TextInput`/`DatePicker`/`TimePicker`/`Scroll` 均无卡片能力）。
- 卡片不可见时系统不触发定点刷新；跨天正确性依赖下次可见时的派生逻辑。
- 代理提醒上限 30 条：任务很多时只有最近的提醒会被排上（预算 28），界面暂无"超额"提示。
- 拖拽换位依赖 `List` 在拖拽会话中的布局补间；若某机型上仍"跳变"，下一步应改 `LazyForEach + IDataSource.onDataMove`（官方 codelab 做法）。
- 拖拽不会触发列表边缘自动滚动（`List` item 拖拽的官方限制）。
- 空列表时无法下拉刷新（`Refresh` 需要可滚动子组件）。
- 未做数据 schema 迁移，字段增删依赖 `TodoTask.fromJson` 的默认值兜底。
