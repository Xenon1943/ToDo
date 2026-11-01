import { common } from '@kit.AbilityKit';
import { TodoTask, TaskDraft } from '../common/Models';
import { TimeUtil } from '../common/TimeUtil';
import { Motion } from '../common/Motion';
import { Logger } from '../common/Logger';
import { TaskRepository, TaskChangeListener, TaskChangeReason } from '../data/TaskRepository';
import { TaskStore } from '../data/TaskStore';
import { SettingsStore } from '../data/SettingsStore';
import { MyDayService, MyDayStats } from '../service/MyDayService';
import { FormBridge } from '../service/FormBridge';
import { ReminderScheduler } from '../service/ReminderScheduler';
import { TaskRow } from './components/TaskRow';
import { TaskEditorSheet } from './components/TaskEditorSheet';

interface LaunchPayload {
  action?: string;
  taskId?: string;
}

@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  @State myDayTasks: TodoTask[] = [];
  @State allTasks: TodoTask[] = [];
  @State doneToday: number = 0;
  /** 我的一天的任务总数（含已完成），和 doneToday 一起显示成 done/total */
  @State myDayTotal: number = 0;
  @State showEditor: boolean = false;
  @State draft: TaskDraft = TaskDraft.empty();
  @State showSettings: boolean = false;
  @State morningHour: number = 8;
  @State morningMinute: number = 0;
  @State remindEnabled: boolean = true;
  @State ready: boolean = false;
  /** 由卡片「＋」拉起的新建流程：保存/取消后自动返回桌面 */
  @State returnAfterSave: boolean = false;
  /** 拖拽预览里显示的标题 */
  @State dragTitle: string = '';
  /** 当前被拖起的任务在列表里的下标（-1 表示没有在拖） */
  @State dragFrom: number = -1;
  /** 当前被拖起的任务 id：**靠 id 而不是 index 做视觉**，
   *  否则换位后每行的 index 都变，ForEach 会重建行，位移就变成"闪现" */
  @State draggingId: string = '';
  /** 拖动过程中是否改过顺序（决定松手时是否要落库） */
  private dragDirty: boolean = false;
  /** 拖动开始前的顺序，用于"拖到非法位置取消"时还原 */
  private dragOrigin: TodoTask[] = [];
  /** 编辑类变更期间抑制行级"删除过渡"（key 变化会走删一个建一个，播动画像被删掉） */
  @State rowAnimSuppressed: boolean = false;
  /** 每次打开编辑面板自增，用来把面板内部状态复位成当前 draft */
  @State draftVersion: number = 0;
  /** 正在做分段切换：期间禁用行级过渡，只播页面级滑动 */
  @State tabSwitching: boolean = false;
  /** 切页位移：新页先被放到 ±64vp，再滑回 0（同一时刻树上只有一页） */
  @State tabOffset: number = 0;
  /** 切页动画开关：置位前一帧用 0 时长，避免"跳位"也被动画化 */
  @State tabAnimEnabled: boolean = false;
  /** 切页令牌：连续切换时以最后一次为准 */
  private tabToken: number = 0;
  /** 下拉刷新：是否在刷新中、当前下拉位移、Refresh 组件状态 */
  @State refreshing: boolean = false;
  @State pullOffset: number = 0;
  @State refreshStatus: RefreshStatus = RefreshStatus.Inactive;
  /** 仓储变更监听（aboutToAppear 注册、aboutToDisappear 注销） */
  private repoListener: TaskChangeListener | null = null;
  /** 最近一次刷新管线，供"卡片拉起 → 自动返回桌面"等待落地 */
  private lastRefresh: Promise<void> | null = null;
  /** 是否正在执行"卡片流程结束后退出应用" */
  private leavingFromCard: boolean = false;
  /** 跨天检测：应用长时间开着时，过 0 点要重算"我的一天" */
  private dayWatcher: number = -1;
  private lastDayKey: string = '';

  // 回前台 / 卡片带参数拉起：都用 AppStorage 传递信号
  @StorageLink('foregroundTick') @Watch('onForegroundTick') foregroundTick: number = 0;
  /** 状态栏高度（px，由 EntryAbility 量出来塞进 AppStorage）：全屏后内容要主动避开 */
  @StorageProp('statusBarPx') statusBarPx: number = 0;
  @StorageLink('launchAction') @Watch('onLaunchAction') launchAction: string = '';

  aboutToAppear(): void {
    this.initRepo();
    this.reload();
    this.askNotificationOnce();
    this.consumeLaunchAction();
    this.lastDayKey = TimeUtil.todayKey();
    this.dayWatcher = setInterval(() => {
      this.checkDayRollover();
    }, 30000);

    // 数据一旦落库就会回调，UI 不用再手动刷新
    this.repoListener = (reason: TaskChangeReason): void => {
      this.onRepoChange(reason);
    };
    TaskRepository.get().onChange(this.repoListener);
  }

  aboutToDisappear(): void {
    if (this.dayWatcher !== -1) {
      clearInterval(this.dayWatcher);
      this.dayWatcher = -1;
    }
    if (this.repoListener !== null) {
      TaskRepository.get().offChange(this.repoListener);
      this.repoListener = null;
    }
  }

  /** 应用一直开着跨过 0 点时，界面要自动切到新的一天 */
  private checkDayRollover(): void {
    const today = TimeUtil.todayKey();
    if (today === this.lastDayKey) {
      return;
    }
    this.lastDayKey = today;
    Logger.info(`[UI] day rolled over to ${today}`);
    // 跨天后「我的一天」内容变了：界面 + 卡片 + 提醒一起对齐
    this.lastRefresh = this.refresh(false);
    this.lastRefresh.catch((e: Object) => {
      Logger.error(`[UI] rollover refresh failed: ${JSON.stringify(e)}`);
    });
  }

  onPageShow(): void {
    // 从卡片勾选/新建后回到应用，这里保证看到的是最新数据
    this.reload();
  }

  onForegroundTick(): void {
    this.reload();
  }

  onLaunchAction(): void {
    this.consumeLaunchAction();
  }

  /**
   * 头部副标题。拖拽时变成进度提示：
   * 拖到最后一位时明确告诉用户"松手 → 放到最后"，这就是"触底提示"。
   */
  private headerSubtitle(): string {
    if (this.draggingId.length > 0) {
      const total = this.myDayTasks.length;
      const atEnd = this.dragFrom >= total - 1;
      return atEnd ? '松手 → 放到最后' : `拖动中 · 第 ${this.dragFrom + 1} / ${total} 位`;
    }
    return this.currentTab === 0
      ? `${TimeUtil.todayKey()} · 已完成 ${this.doneToday}/${this.myDayTotal}`
      : `共 ${this.allTasks.length} 个任务`;
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private initRepo(): void {
    try {
      TaskRepository.get().init(this.ctx());
      this.ready = TaskRepository.get().isReady();
    } catch (e) {
      Logger.error(`[UI] initRepo failed: ${JSON.stringify(e)}`);
      this.ready = false;
    }
  }

  private reload(): void {
    this.applyState(false);
  }

  /**
   * 重算并应用界面状态。
   * animate=true 时把赋值包进 animateTo，配合 ListItem 的 transition 做出
   * "任务淡出/飞出、后面的任务跟上"的效果。
   */
  private applyState(animate: boolean): void {
    // 非动画刷新（编辑/排序/回前台/下拉刷新）里，行 key 变化会走"删一个建一个"，
    // 不抑制的话会误播"删除"过渡（表现为编辑完像被删了）
    if (!animate) {
      this.rowAnimSuppressed = true;
      setTimeout(() => {
        this.rowAnimSuppressed = false;
      }, 160);
    }
    if (!TaskRepository.get().isReady()) {
      this.initRepo();
    }
    if (!TaskRepository.get().isReady()) {
      return;
    }
    this.ready = TaskRepository.get().isReady();
    const all = TaskRepository.get().listAll();
    const now = Date.now();
    const today = TimeUtil.todayKey();
    const myDay = MyDayService.myDayTasks(all, today, now);
    const stats: MyDayStats = MyDayService.myDayStats(all, today, now);
    const morningHour = SettingsStore.morningHour();
    const morningMinute = SettingsStore.morningMinute();
    const remindEnabled = SettingsStore.remindEnabled();

    const apply = () => {
      this.allTasks = all;
      this.myDayTasks = myDay;
      this.doneToday = stats.done;
      this.myDayTotal = stats.total;
      this.morningHour = morningHour;
      this.morningMinute = morningMinute;
      this.remindEnabled = remindEnabled;
      // 数据重算时顺带清掉拖拽态，避免拖到列表外没收到 onItemDrop 时留下"空位"
      this.dragFrom = -1;
      this.draggingId = '';
    };
    if (!animate) {
      apply();
      return;
    }
    this.getUIContext().animateTo(Motion.params(Motion.NORMAL), apply);
  }

  /**
   * 统一的刷新管线：重算界面 → 推卡片 → 对账提醒。
   * 由仓储的变更事件驱动，调用方不用再记着"改完要刷新"。
   */
  private async refresh(animate: boolean): Promise<void> {
    this.applyState(animate);
    try {
      await FormBridge.refreshAll(this.ctx());
    } catch (e) {
      Logger.error(`[UI] refreshAll failed: ${JSON.stringify(e)}`);
    }
    try {
      await ReminderScheduler.sync(this.ctx(), TaskRepository.get().listAll());
      await ReminderScheduler.logValidCount();
    } catch (e) {
      Logger.error(`[UI] reminder sync failed: ${JSON.stringify(e)}`);
    }
  }

  /** 仓储每次落库后回调：决定要不要播动画，并记住这次刷新的 Promise 供"自动返回"等待 */
  private onRepoChange(reason: TaskChangeReason): void {
    // 只有"行真正增删"才播动画：
    // update（改名/改期）如果用内容敏感 key 会走"删一个建一个"，播动画会像被删掉，所以不播；
    // order（拖拽落库）与 external（外部触发）同样不播。
    const animate = reason === 'create' || reason === 'toggle' || reason === 'delete';
    this.lastRefresh = this.refresh(animate);
    this.lastRefresh.catch((e: Object) => {
      Logger.error(`[UI] refresh after ${reason} failed: ${JSON.stringify(e)}`);
    });
  }

  /** 等待最近一次刷新落地（没有则在下一个微任务后返回） */
  private async waitLastRefresh(): Promise<void> {
    if (this.lastRefresh !== null) {
      await this.lastRefresh;
    }
  }

  /** 从卡片进来的新建/查看流程结束后，回到桌面 */
  private finishFromCard(saved: boolean): void {
    if (!this.returnAfterSave) {
      return;
    }
    this.returnAfterSave = false;
    this.leavingFromCard = true;
    if (saved) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '已添加到「我的一天」', duration: 1200 });
      } catch (e) {
        Logger.warn(`[UI] toast failed: ${JSON.stringify(e)}`);
      }
    }
    this.waitLastRefresh().then(() => {
      // 留一点时间让卡片刷新和 toast 落地，再退出应用回到桌面
      setTimeout(() => {
        if (!this.leavingFromCard) {
          // 已被别的流程接管，不再退出
          return;
        }
        this.leavingFromCard = false;
        try {
          this.ctx().terminateSelf();
          Logger.info('[UI] terminateSelf after card quickAdd');
        } catch (e) {
          Logger.error(`[UI] terminateSelf failed: ${JSON.stringify(e)}`);
        }
      }, 400);
    }).catch((e: Object) => {
      Logger.error(`[UI] finishFromCard failed: ${JSON.stringify(e)}`);
    });
  }

  private askNotificationOnce(): void {
    if (SettingsStore.notifyAsked()) {
      return;
    }
    SettingsStore.setNotifyAsked();
    ReminderScheduler.ensureNotificationPermission(this.ctx()).then((ok: boolean) => {
      this.remindEnabled = ok;
      if (ok) {
        this.lastRefresh = this.refresh(false);
      }
    }).catch((e: Object) => {
      Logger.error(`[UI] askNotification failed: ${JSON.stringify(e)}`);
    });
  }

  private consumeLaunchAction(): void {
    const raw = AppStorage.get<string>('launchAction');
    if (raw === undefined || raw === null || raw.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>('launchAction', '');
    let payload: LaunchPayload | null = null;
    try {
      payload = JSON.parse(raw) as LaunchPayload;
    } catch (e) {
      return;
    }
    if (payload === null || payload === undefined) {
      return;
    }
    const action = payload.action;
    if (action === 'quickAdd') {
      // 卡片「＋」→ 直接进新建页，保存/取消后自动返回桌面
      this.returnAfterSave = true;
      this.draft = TaskDraft.empty();
      this.openSheetDeferred();
    } else if (action === 'openTask' && typeof payload.taskId === 'string') {
      const task = TaskRepository.get().getById(payload.taskId);
      if (task === null) {
        Logger.warn(`[UI] card openTask miss id=${payload.taskId}`);
        return;
      }
      this.draft = TaskDraft.fromTask(task);
      this.openSheetDeferred();
    } else if (action === 'openMyDay') {
      this.currentTab = 0;
    }
  }

  /** 冷启动时页面首帧还没挂载完，直接开半模态可能不生效，延后一拍 */
  private openSheetDeferred(): void {
    setTimeout(() => {
      this.showEditor = true;
    }, 120);
  }

  private openNew(): void {
    this.draft = TaskDraft.empty();
    this.draftVersion++;
    this.showEditor = true;
  }

  private openTask(id: string): void {
    const task = TaskRepository.get().getById(id);
    if (task === null) {
      Logger.warn(`[UI] openTask miss id=${id}`);
      return;
    }
    this.draft = TaskDraft.fromTask(task);
    this.draftVersion++;
    this.showEditor = true;
  }

  private toggle(id: string): void {
    const task = TaskRepository.get().getById(id);
    if (task === null) {
      return;
    }
    // 落库后由 onRepoChange 统一刷新，这里不再手动调
    TaskRepository.get().setDone(id, !task.done);
  }

  private save(d: TaskDraft): void {
    const repo = TaskRepository.get();
    if (d.isNew) {
      repo.create(d.title, d.dueAt, d.remindAt, d.note, d.intoMyDay);
    } else {
      const task = repo.getById(d.id);
      if (task === null) {
        this.showEditor = false;
        return;
      }
      task.title = d.title;
      task.dueAt = d.dueAt;
      task.remindAt = d.remindAt;
      task.note = d.note;
      if (d.intoMyDay && task.myDayDate.length === 0) {
        task.myDayDate = TimeUtil.todayKey();
      }
      repo.update(task);
    }
    this.showEditor = false;
    if (this.returnAfterSave) {
      // 卡片拉起的流程：等刷新落地 → toast → 回桌面
      this.finishFromCard(true);
    }
  }

  private remove(id: string): void {
    TaskRepository.get().remove(id);
  }

  private toggleMyDay(id: string): void {
    const repo = TaskRepository.get();
    const task = repo.getById(id);
    if (task === null) {
      return;
    }
    const now = Date.now();
    const today = TimeUtil.todayKey();
    if (MyDayService.isInMyDay(task, today, now)) {
      repo.removeFromMyDay(id);
    } else {
      repo.addToMyDay(id);
    }
  }

  private applyMorning(): void {
    SettingsStore.setMorning(this.morningHour, this.morningMinute);
    this.showSettings = false;
    ReminderScheduler.reset().then(() => {
      this.lastRefresh = this.refresh(false);
    }).catch((e: Object) => {
      Logger.error(`[UI] reset reminder failed: ${JSON.stringify(e)}`);
    });
  }

  /**
  /** 切换分段：期间让行级过渡让位，避免"整页从左边浮起"的怪异感 */
  private switchTab(index: number): void {
    if (index === this.currentTab) {
      return;
    }
    const dir = index > this.currentTab ? 1 : -1;
    this.tabSwitching = true;

    // ① 无动画地把新页放到起始偏移（此时旧页已经从树上移除，绝不会同时出现两页）
    this.tabAnimEnabled = false;
    this.tabOffset = dir * 64;
    this.currentTab = index;

    // ② 下一帧滑回原位；用令牌保证连续切换时只有最后一次生效
    const token = ++this.tabToken;
    setTimeout(() => {
      if (token !== this.tabToken) {
        return;
      }
      this.tabAnimEnabled = true;
      this.tabOffset = 0;
    }, 16);

    setTimeout(() => {
      if (token === this.tabToken) {
        this.tabSwitching = false;
      }
    }, Motion.NORMAL + 80);
  }


  /**
   * 下拉刷新：强制从磁盘重读（另一个进程可能刚改过数据），
   * 顺带把卡片和提醒对齐一次，最后收起指示器。
   */
  private doRefresh(): void {
    this.refreshing = true;
    // 先强制从磁盘重读：另一个进程（卡片）可能刚改过数据
    TaskStore.get().reload();
    this.lastRefresh = this.refresh(false);
    this.lastRefresh.then(() => {
      this.finishRefresh();
    }).catch((e: Object) => {
      Logger.error(`[UI] pull refresh failed: ${JSON.stringify(e)}`);
      this.finishRefresh();
    });
  }

  /** 收起刷新指示器：至少停留 250ms，避免一闪而过 */
  private finishRefresh(): void {
    setTimeout(() => {
      this.refreshing = false;
      this.pullOffset = 0;
      this.refreshStatus = RefreshStatus.Inactive;
      Logger.info('[UI] pull refresh done');
    }, 250);
  }

  /** 拖拽时跟随手指的预览：和列表行同尺寸，只加阴影"浮起"，不做缩放 */
  @Builder
  dragPreviewBuilder() {
    Row() {
      Row()
        .width(20)
        .height(20)
        .borderRadius(10)
        .borderWidth(1.5)
        .borderColor($r('app.color.text_secondary'))
      Text(this.dragTitle)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 12 })
    }
    .width(320)
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(14)
    .shadow(Motion.dragPreviewShadow())
  }

  @Builder
  swipeActions(task: TodoTask) {
    Row() {
      Button('我的一天')
        .fontSize(12)
        .type(ButtonType.Capsule)
        .backgroundColor($r('app.color.accent'))
        .margin({ right: 8 })
        .onClick(() => {
          this.toggleMyDay(task.id);
        })
      Button('删除')
        .fontSize(12)
        .type(ButtonType.Capsule)
        .backgroundColor($r('app.color.danger'))
        .onClick(() => {
          this.remove(task.id);
        })
    }
    .padding({ left: 8 })
  }

  /** 下拉刷新指示器：下拉时箭头随进度旋转，进入刷新态换成转圈 */
  @Builder
  refreshIndicator() {
    Column() {
      if (this.refreshing || this.refreshStatus === RefreshStatus.Refresh) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color($r('app.color.accent'))
      } else {
        Text('↓')
          .fontSize(16)
          .fontColor($r('app.color.text_secondary'))
          .rotate({ angle: Math.min(this.pullOffset / 48, 1) * 180 })
          .animation(Motion.linearParams(80))
      }
      Text(this.refreshing || this.refreshStatus === RefreshStatus.Refresh
        ? '刷新中…'
        : (this.pullOffset >= 48 ? '松手刷新' : '下拉刷新'))
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 4 })
    }
    .width('100%')
    .height(64)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  emptyView() {
    Column() {
      Text(this.currentTab === 0
        ? (this.myDayTotal > 0 && this.doneToday >= this.myDayTotal ? '今天的任务都完成了' : '今天还没有安排')
        : '还没有任务')
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
      Text(this.currentTab === 0
        ? (this.myDayTotal > 0 && this.doneToday >= this.myDayTotal
          ? '点右下角 ＋ 继续添加'
          : '点右下角 ＋ 新建，或从"全部任务"里划出加入')
        : '点右下角 ＋ 新建任务')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 8 })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 16, right: 16 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  editorSheet() {
    Column() {
      TaskEditorSheet({
        initDraft: this.draft,
        draftVersion: this.draftVersion,
        onSave: (d: TaskDraft) => {
          this.save(d);
        },
        onCancel: () => {
          this.showEditor = false;
          this.finishFromCard(false);
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.card_bg'))
  }

  @Builder
  settingsSheet() {
    Column() {
      Text('设置')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .margin({ top: 16, bottom: 16 })
      Row() {
        Text('早上提醒时间').fontSize(14)
        Blank()
        Text(SettingsStore.morningText())
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .height(40)
      TimePicker({ selected: new Date(TimeUtil.atTime(Date.now(), this.morningHour, this.morningMinute)) })
        .onChange((v: TimePickerResult) => {
          this.morningHour = v.hour;
          this.morningMinute = v.minute;
        })
      Text('修改后会重建所有提醒（代理提醒单应用上限 30 条，只对近期到期任务排期）')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 12 })
      Button('保存')
        .width('100%')
        .margin({ top: 16 })
        .onClick(() => {
          this.applyMorning();
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.card_bg'))
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 背景层：延伸到状态栏 / 导航栏下面，避免底部留出一条"给返回栏的白边"
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.page_bg'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        // 头部
        Row() {
          Column() {
            Text(this.currentTab === 0 ? '我的一天' : '全部任务')
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.headerSubtitle())
              .fontSize(12)
              .fontColor(this.draggingId.length > 0
                ? $r('app.color.accent')
                : $r('app.color.text_secondary'))
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)

          Blank()

          Text('设置')
            .fontSize(13)
            .fontColor($r('app.color.accent'))
            .padding(8)
            .bindSheet($$this.showSettings, this.settingsSheet(), {
              height: 420,
              dragBar: true,
              backgroundColor: $r('app.color.card_bg')
            })
            .onClick(() => {
              this.showSettings = true;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 8, top: 12, bottom: 8 })

        // 通知未开启提示
        if (!this.remindEnabled) {
          Row() {
            Text('提醒未开启：任务到期不会通知你。请到系统设置里允许通知，或点右侧重试')
              .fontSize(11)
              .fontColor($r('app.color.danger'))
              .layoutWeight(1)
            Text('重试')
              .fontSize(11)
              .fontColor($r('app.color.accent'))
              .onClick(() => {
                ReminderScheduler.ensureNotificationPermission(this.ctx()).then((ok: boolean) => {
                  this.remindEnabled = ok;
                  if (ok) {
                    this.lastRefresh = this.refresh(false);
                  }
                }).catch((e: Object) => {
                  Logger.error(`[UI] retry notification failed: ${JSON.stringify(e)}`);
                });
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor($r('app.color.card_bg_secondary'))
        }

        // 存储不可用：数据写了也留不住，必须让用户知道
        if (!this.ready) {
          Row() {
            Text('本地存储不可用，任务可能无法保存。请重启应用或检查设备存储空间')
              .fontSize(11)
              .fontColor($r('app.color.danger'))
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor($r('app.color.card_bg_secondary'))
        }

        // 分段
        // 分段控件：灰轨道 + 会滑动的白色药丸。
        // 只有一个底块在动，两个文字只换颜色，因此不会出现"两个按钮同时亮"
        Row() {
          Stack({ alignContent: Alignment.TopStart }) {
            Row()
              .width(172)
              .height(34)
              .borderRadius(17)
              .backgroundColor($r('app.color.card_bg_secondary'))

            Row()
              .width(84)
              .height(30)
              .borderRadius(15)
              .backgroundColor($r('app.color.card_bg'))
              .shadow({ radius: 6, color: '#1A000000', offsetY: 1 })
              .translate({ x: this.currentTab === 0 ? 0 : 84 })
              .animation(Motion.params(Motion.FAST))
              .margin({ left: 2, top: 2 })

            Row() {
              Text('我的一天')
                .width(84)
                .height(34)
                .textAlign(TextAlign.Center)
                .fontSize(14)
                .fontWeight(this.currentTab === 0 ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.currentTab === 0
                  ? $r('app.color.text_primary')
                  : $r('app.color.text_secondary'))
                .onClick(() => {
                  this.switchTab(0);
                })
              Text('全部任务')
                .width(84)
                .height(34)
                .textAlign(TextAlign.Center)
                .fontSize(14)
                .fontWeight(this.currentTab === 1 ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.currentTab === 1
                  ? $r('app.color.text_primary')
                  : $r('app.color.text_secondary'))
                .onClick(() => {
                  this.switchTab(1);
                })
            }
            .margin({ left: 2 })
          }
          .width(172)
          .height(34)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 8 })

        // 列表卡片：与上方标题在视觉上分开
        Column() {
          if (this.currentTab === 0) {
            // 「我的一天」在分段条的左边 → 进入时从左侧滑入
            Column() {
              if (this.myDayTasks.length === 0) {
                this.emptyView()
              } else {
                Refresh({ refreshing: $$this.refreshing, builder: this.refreshIndicator() }) {
                List({ space: 0 }) {
                  ForEach(this.myDayTasks, (task: TodoTask) => {
                    ListItem() {
                      TaskRow({
                        taskId: task.id,
                        title: task.title,
                        dueAt: task.dueAt,
                        done: task.done,
                        overdue: TimeUtil.isOverdue(task.dueAt, Date.now()),
                        inMyDay: !task.done && MyDayService.isInMyDay(task, TimeUtil.todayKey(), Date.now()),
                        carried: !task.done && MyDayService.isCarriedOver(task, TimeUtil.todayKey(), Date.now()),
                        onToggle: (id: string) => {
                          this.toggle(id);
                        },
                        onOpen: (id: string) => {
                          this.openTask(id);
                        }
                      })
                    }
                    .swipeAction({ end: this.swipeActions(task) })
                    // 拖拽/切页期间不播"删除过渡"，否则换位时整行会往左甩一下
                    .transition(this.tabSwitching || this.rowAnimSuppressed || this.dragFrom >= 0
                      ? TransitionEffect.IDENTITY
                      : Motion.rowTransition())
                    // 被拖起的这一行在列表里只留一个"淡色空位"；
                    // 浮动卡片（带阴影）由拖拽预览负责，避免矩形阴影只在四角露出来
                    .opacity(this.draggingId === task.id ? 0.3 : 1)
                    .animation(Motion.params(Motion.FAST))
                  }, (task: TodoTask) => `${task.id}:${task.done ? 1 : 0}:${task.updatedAt}`)
                }
                .width('100%')
                .height('100%')
                .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 48 })
                .scrollBar(BarState.Off)
                .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
                  const task = this.myDayTasks[itemIndex];
                  this.dragOrigin = this.myDayTasks.slice();
                  this.dragDirty = false;
                  this.dragFrom = itemIndex;
                  this.dragTitle = task !== undefined ? task.title : '';
                  // 视觉上认 id 不认 index：换位后 index 会变，认 index 会导致整行重建（闪现）
                  this.draggingId = task !== undefined ? task.id : '';
                  return this.dragPreviewBuilder;
                })
                .onItemDragMove((event: ItemDragInfo, itemIndex: number, insertIndex: number) => {
                  // 拖动过程中实时换位：其他任务立刻让路，松手前不落库
                  if (this.dragFrom < 0 || insertIndex < 0 || insertIndex >= this.myDayTasks.length) {
                    return;
                  }
                  if (insertIndex === this.dragFrom) {
                    return;
                  }
                  const next = MyDayService.moveItem(this.myDayTasks, this.dragFrom, insertIndex);
                  this.dragDirty = true;
                  // 数组和下标在同一帧更新，其他行才会整体平移让路（而不是各自跳一下）
                  this.getUIContext().animateTo(Motion.params(Motion.REORDER), () => {
                    this.myDayTasks = next;
                    this.dragFrom = insertIndex;
                  });
                })
                .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
                  if (!isSuccess && this.dragDirty) {
                    // 拖到非法区域：还原成拖动前的顺序
                    this.myDayTasks = this.dragOrigin;
                    this.dragFrom = -1;
                    this.draggingId = '';
                    this.dragDirty = false;
                    return;
                  }
                  this.dragFrom = -1;
                  this.draggingId = '';
                  if (this.dragDirty) {
                    this.dragDirty = false;
                    // 落库后由仓储事件刷新（排序不播增删动画）
                    TaskRepository.get().reorderMyDay(this.myDayTasks);
                  }
                })
                }
                .width('100%')
                .layoutWeight(1)
                .onOffsetChange((offset: number) => {
                  this.pullOffset = offset;
                })
                .onStateChange((state: RefreshStatus) => {
                  this.refreshStatus = state;
                })
                .onRefreshing(() => {
                  this.doRefresh();
                })
              }
            }
            .width('100%')
            .height('100%')
            .translate({ x: this.tabOffset })
            .opacity(this.tabOffset === 0 ? 1 : 0.7)
            .animation(this.tabAnimEnabled ? Motion.params(Motion.NORMAL) : Motion.params(0))
          } else {
            // 「全部任务」在右边 → 进入时从右侧滑入
            Column() {
              if (this.allTasks.length === 0) {
                this.emptyView()
              } else {
                Refresh({ refreshing: $$this.refreshing, builder: this.refreshIndicator() }) {
                List({ space: 0 }) {
                  ForEach(this.allTasks, (task: TodoTask) => {
                    ListItem() {
                      TaskRow({
                        taskId: task.id,
                        title: task.title,
                        dueAt: task.dueAt,
                        done: task.done,
                        overdue: TimeUtil.isOverdue(task.dueAt, Date.now()),
                        inMyDay: !task.done && MyDayService.isInMyDay(task, TimeUtil.todayKey(), Date.now()),
                        carried: !task.done && MyDayService.isCarriedOver(task, TimeUtil.todayKey(), Date.now()),
                        onToggle: (id: string) => {
                          this.toggle(id);
                        },
                        onOpen: (id: string) => {
                          this.openTask(id);
                        }
                      })
                    }
                    .swipeAction({ end: this.swipeActions(task) })
                    .transition(this.tabSwitching || this.rowAnimSuppressed
                      ? TransitionEffect.IDENTITY
                      : Motion.rowTransition())
                  }, (task: TodoTask) => `${task.id}:${task.done ? 1 : 0}:${task.updatedAt}`)
                }
                .width('100%')
                .height('100%')
                .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 48 })
                .scrollBar(BarState.Off)
                // 并行手势：只认"向右"的滑动（回到「我的一天」），
                // 向左留给行内的 swipeAction 菜单，互不抢占
                .parallelGesture(
                  PanGesture({ direction: PanDirection.Horizontal, distance: 20 })
                    .onActionEnd((event: GestureEvent) => {
                      if (event.offsetX >= 60 && this.currentTab === 1) {
                        this.switchTab(0);
                      }
                    })
                )
                }
                .width('100%')
                .layoutWeight(1)
                .onOffsetChange((offset: number) => {
                  this.pullOffset = offset;
                })
                .onStateChange((state: RefreshStatus) => {
                  this.refreshStatus = state;
                })
                .onRefreshing(() => {
                  this.doRefresh();
                })
              }
            }
            .width('100%')
            .height('100%')
            .translate({ x: this.tabOffset })
            .opacity(this.tabOffset === 0 ? 1 : 0.7)
            .animation(this.tabAnimEnabled ? Motion.params(Motion.NORMAL) : Motion.params(0))
          }
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(18)
        .margin({ left: 12, right: 12, bottom: 12 })
        .shadow({ radius: 10, color: '#0F000000', offsetY: 3 })
        .clip(true)

      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      // 顶部按状态栏高度让位（全屏后框架不会自动避让），底部延伸到底
      .padding({ top: this.getUIContext().px2vp(this.statusBarPx) })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      // 左右滑切页：挂在整页内容上，标题/分段/卡片空白都能滑；
      // 任务行上的右滑留给行内菜单，左滑留给切页
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: 24 })
          .onActionEnd((event: GestureEvent) => {
            const dx = event.offsetX;
            if (dx <= -60 && this.currentTab === 0) {
              this.switchTab(1);
            } else if (dx >= 60 && this.currentTab === 1) {
              this.switchTab(0);
            }
          })
      )

      // 新建按钮：用两条圆角矩形画"＋"，保证严格居中（文字字形会偏）
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Stack() {
          Row()
            .width(20)
            .height(2.4)
            .borderRadius(1.2)
            .backgroundColor(Color.White)
          Row()
            .width(2.4)
            .height(20)
            .borderRadius(1.2)
            .backgroundColor(Color.White)
        }
        .width('100%')
        .height('100%')
        .alignContent(Alignment.Center)
      }
      .width(56)
      .height(56)
      .backgroundColor($r('app.color.accent'))
      .shadow({ radius: 12, color: '#330A59F7', offsetY: 4 })
      .margin({ right: 20, bottom: 32 })
      .onClick(() => {
        this.openNew();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .bindSheet($$this.showEditor, this.editorSheet(), {
      height: '68%',
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.card_bg'),
      onDisappear: () => {
        // 这里**不能**再 reload：保存时仓储事件已经用 animateTo 播了"新任务淡入/行位移"，
        // 关闭动画结束再重算一次状态会把动画掐断（表现为闪一下）。
        // 下滑手势关闭面板时也要能"自动返回桌面"。
        this.finishFromCard(false);
      }
    })
  }
}
