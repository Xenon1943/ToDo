# ArkUI API 笔记（本工程实际踩坑后核对）

目的：把"我猜的"变成"文档/SDK 里写着的"。每条都标了出处，改代码前先看这里，别再凭印象。

- 本地 SDK：`<DevEco>/sdk/default/openharmony/ets/component/*.d.ts`（**与当前编译版本完全一致，优先级最高**）
- 官方文档：OpenHarmony `docs` 仓库（`raw.giteeusercontent.com/openharmony/docs/raw/master/zh-cn/application-dev/...`）

---

## 1. ListItem.swipeAction（滑动菜单）

来源：`reference/apis-arkui/arkui-ts/ts-container-listitem.md` + `component/list_item.d.ts`

| 字段 | 方向语义（List 垂直布局时） |
| --- | --- |
| `start` | ListItem **向右**划动 → 显示 item **左边**的组件 |
| `end` | ListItem **向左**划动 → 显示 item **右边**的组件 |
| `edgeEffect` | `Spring`（可继续拉、回弹）/ `None`（不超过菜单宽度，配 `actionAreaDistance`+`onAction` 可做长滑删除） |
| `onOffsetChange`<sup>11+</sup> | `(offset: number) => void`，位置变化即触发，**单位 vp** |

`SwipeActionItem` 额外能力：`actionAreaDistance`（默认 56vp）、`onAction`、`onEnterActionArea`/`onExitActionArea`、`onStateChange(SwipeActionState)`。

`SwipeActionState`：`COLLAPSED(0)` / `EXPANDED(1)` / `ACTIONING(2)`。

**API 21+** 有 `ListItemSwipeActionManager.expand(node, direction)` / `collapse(node)` / `ListScroller.closeAllSwipeActions()`，可程序化开关菜单。

**约定**：`start`/`end` 的 `@builder` **顶层必须是单个组件**（`Row()` 包住即可），`if/else`、`ForEach` 必须保证只产出一个组件，否则行为未定义。

> 对本工程的意义：我们用的是 `end`（左滑出「我的一天/删除」）——与"左滑=菜单"的预期一致；`onOffsetChange` 可以用来判断用户是往哪个方向滑（正负号），这是后续做"行上右滑切页"的可行抓手。

## 2. Refresh（下拉刷新）

来源：`component/refresh.d.ts`

- `RefreshStatus`：`Inactive`(未下拉) / `Drag`(未过阈值) / `OverDrag`(过阈值未松手) / `Refresh`(刷新中) / `Done`(刷新完成、回弹)。
- `onOffsetChange(callback: (offset: number) => void)`：下拉位移，单位 vp。
- `RefreshOptions.builder?: CustomBuilder`：自定义指示器；`promptText`/`refreshingText` 只是文案。
- `refreshing` 支持 `$$` 双向绑定。

> 本工程：自定义指示器用 `builder` + `onOffsetChange` 做箭头旋转，`onStateChange` 判 `Refresh` 态切 `LoadingProgress`，与文档一致。

## 3. 过渡与动画

| 结论 | 出处 |
| --- | --- |
| `.transition(TransitionEffect)` 的动画参数挂在 effect 上（`.animation()`），**不依赖外层 `animateTo`** | `TransitionEffect` 声明 + 实测 |
| transition 期间**离开的节点仍留在树上**直到动画结束 —— 这就是"切页时两页同时可见"的根因 | 实测（本项目 `89a61ca`） |
| `TransitionEffect.asymmetric(appear, disappear)` 可分别定义进出场；`TransitionEffect.IDENTITY` 表示不做过渡 | `common.d.ts` |
| **form（卡片）应用禁用** `animateTo` / `getUIContext()` / `setTimeout`，编译期报错；只能用 `.animation()` 隐式动画 | 编译错误信息（本项目多次撞到） |
| `.animation()` 作用于"它之前的属性"，不影响布局位置变化 | API 文档 |

> 本工程：行增删用 `asymmetric(淡入, 淡出+左移)`；切页**不用 transition**（会两页并存），改成 `translate + opacity + .animation()` 的单页位移动画。

## 4. 列表复用

| 结论 | 出处 |
| --- | --- |
| `ForEach` 的 keyGenerator 返回相同 key 时**复用已有子组件，且不会重新执行 itemGenerator** → 靠外层重算 props 更新界面是无效的 | 《ForEach 渲染控制》 |
| `@Builder` **按值传参**时，参数没变就不会重跑 builder → 内部依赖外部状态的条件渲染不会刷新 | 《@Builder 装饰器》 |
| 需要"内容变了就重建行"时，把内容字段放进 key（本工程 `${id}:${done}:${updatedAt}`） | 本项目实测 |

> 本工程踩过的两个坑：分段按钮、今天/明天按钮都因此不刷新；最终都改成**直接写在 `build()` 里**。

## 5. 窗口与安全区

| 结论 | 出处 |
| --- | --- |
| `setWindowLayoutFullScreen(true)` 后**框架不会自动把页面内容让开状态栏/导航栏**，需要自己处理 | `@ohos.window` + 本项目实测（内容压到状态栏） |
| 取安全区：`window.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)`，返回 `topRect/bottomRect`（px） | `@ohos.window.d.ts` |
| 组件级扩展：`.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, ...])` | `common.d.ts` |
| `px2vp` 全局函数已废弃，用 `this.getUIContext().px2vp()` | 编译告警 |

> 本工程：背景层 `expandSafeArea(TOP+BOTTOM)`，内容层按 `statusBarPx` 让位、只向下延伸。

## 6. 卡片（Form Kit）

| 结论 | 出处 |
| --- | --- |
| 卡片可用组件：`List`/`Swiper`/`Grid`/`Checkbox`/`Text`/`Image` 等；**`Scroll`/`TextInput`/`DatePicker`/`TimePicker` 不可用** | SDK `.d.ts` 的 `@form` 标记 + 《ArkTS卡片支持的页面能力》 |
| 数据只能经 `LocalStorageProp` 下发，且会被转成 string | 《ArkTS卡片页面刷新概述》 |
| 定时刷新配额 50 次/天/卡片；`setFormNextRefreshTime` 最短 5 分钟；定点刷新最多 24 个时间点 | 《ArkTS卡片被动刷新》 |
| 代理刷新（`dataProxyEnabled`）仅系统应用 | 同上 |
| `getPublishedRunningFormInfos()`（API 20+）可拿到已加桌卡片的 `formId` | `formProvider.d.ts` |

---

## 待验证（有设备后第一件事）

1. 行上**右滑**时，`swipeAction.onOffsetChange` 是否收到非零 offset（若收到，可据此可靠地做"右滑切页"）。
2. 加了 `.parallelGesture(PanGesture(Horizontal))` 的 List，右滑是否真的能到父级处理器（若不能，需改为自绘菜单）。
