import { common } from '@kit.AbilityKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { TodoTask } from '../common/Models';
import { TimeUtil } from '../common/TimeUtil';
import { Logger } from '../common/Logger';
import { TaskStore } from '../data/TaskStore';
import { SettingsStore } from '../data/SettingsStore';

const KEY_INDEX: string = 'reminder:index';
const KEY_ITEM_PREFIX: string = 'reminder:';
const WANT_URI_PREFIX: string = 'todo://task/';
const DUE_AHEAD_MS: number = 10 * 60 * 1000;
const MIN_LEAD_MS: number = 30 * 1000;

/** 一条待发布的提醒 */
class ReminderPlan {
  kind: string = '';
  triggerAt: number = 0;
  title: string = '';
  content: string = '';

  constructor(kind: string, triggerAt: number, title: string, content: string) {
    this.kind = kind;
    this.triggerAt = triggerAt;
    this.title = title;
    this.content = content;
  }
}

interface ReminderBookJson {
  sig?: string;
  ids?: number[];
}

/** 排期账本：记录某任务当前发布出去的提醒 id 与签名，用于增量对账 */
class ReminderBook {
  sig: string = '';
  ids: number[] = [];

  toJson(): string {
    const o: ReminderBookJson = { sig: this.sig, ids: this.ids };
    return JSON.stringify(o);
  }

  static parse(raw: string): ReminderBook | null {
    if (raw === undefined || raw === null || raw.length === 0) {
      return null;
    }
    let o: ReminderBookJson | null = null;
    try {
      o = JSON.parse(raw) as ReminderBookJson;
    } catch (e) {
      return null;
    }
    if (o === null || o === undefined) {
      return null;
    }
    const b = new ReminderBook();
    b.sig = typeof o.sig === 'string' ? o.sig : '';
    b.ids = [];
    const ids = o.ids;
    if (ids instanceof Array) {
      const arr = ids as number[];
      for (let i = 0; i < arr.length; i++) {
        if (typeof arr[i] === 'number') {
          b.ids.push(arr[i]);
        }
      }
    }
    return b;
  }
}

/** 任务 + 提醒 的组合，便于按时间排序裁剪 */
class PlanRef {
  task: TodoTask;
  plan: ReminderPlan;

  constructor(task: TodoTask, plan: ReminderPlan) {
    this.task = task;
    this.plan = plan;
  }
}

/**
 * 代理提醒排期。
 *
 * 硬约束：普通应用最多 30 条有效提醒，所以必须做预算与增量对账，
 * 不能每次变更就 cancelAll + 全量重发（会抖动，也容易超限）。
 *
 * 规则：
 * - 有截止日期：截止当天"早上时间"(可配，默认 08:00) 一条 + 截止前 10 分钟一条
 * - 有提醒日期：提醒日期一条（与上面时间重复则合并）
 * - 已完成：全部取消
 */
export class ReminderScheduler {
  /** 预算留 2 条余量 */
  static readonly BUDGET: number = 28;

  /** 首次启动请求通知授权（代理提醒的前置条件） */
  static async ensureNotificationPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (enabled) {
        SettingsStore.setRemindEnabled(true);
        return true;
      }
      await notificationManager.requestEnableNotification(context);
      const after = await notificationManager.isNotificationEnabled();
      SettingsStore.setRemindEnabled(after);
      Logger.info(`[Reminder] notification enabled=${after}`);
      return after;
    } catch (e) {
      Logger.error(`[Reminder] requestEnableNotification failed: ${JSON.stringify(e)}`);
      SettingsStore.setRemindEnabled(false);
      return false;
    }
  }

  /** 清空所有提醒（改设置后用） */
  static async reset(): Promise<void> {
    try {
      await reminderAgentManager.cancelAllReminders();
      TaskStore.get().putString(KEY_INDEX, '[]');
      Logger.info('[Reminder] reset all');
    } catch (e) {
      Logger.error(`[Reminder] reset failed: ${JSON.stringify(e)}`);
    }
  }

  /** 进程内重入保护：卡片进程和应用进程可能同时触发对账，本进程内先串行化 */
  private static syncing: boolean = false;

  /** 全量对账：以任务列表为目标状态，增量发布/取消 */
  static async sync(context: common.Context, tasks: TodoTask[]): Promise<void> {
    if (ReminderScheduler.syncing) {
      Logger.info('[Reminder] sync skipped, previous one still running');
      return;
    }
    ReminderScheduler.syncing = true;
    try {
      await ReminderScheduler.doSync(context, tasks);
    } catch (e) {
      Logger.error(`[Reminder] sync failed: ${JSON.stringify(e)}`);
    } finally {
      ReminderScheduler.syncing = false;
    }
  }

  private static async doSync(context: common.Context, tasks: TodoTask[]): Promise<void> {
    if (!SettingsStore.remindEnabled()) {
      Logger.info('[Reminder] sync skipped, remind disabled');
      return;
    }
    const now = Date.now();
    let pkgName = '';
    try {
      pkgName = context.applicationInfo.name;
    } catch (e) {
      pkgName = 'com.xenon.todo';
    }

    // 1. 生成所有期望的提醒，按触发时间排序后裁剪到预算内
    const all: PlanRef[] = [];
    for (let i = 0; i < tasks.length; i++) {
      const plans = ReminderScheduler.plansFor(tasks[i], now);
      for (let j = 0; j < plans.length; j++) {
        all.push(new PlanRef(tasks[i], plans[j]));
      }
    }
    all.sort((a: PlanRef, b: PlanRef): number => a.plan.triggerAt - b.plan.triggerAt);
    const kept: PlanRef[] = all.length > ReminderScheduler.BUDGET
      ? all.slice(0, ReminderScheduler.BUDGET)
      : all;
    if (all.length > ReminderScheduler.BUDGET) {
      Logger.warn(`[Reminder] budget trimmed ${all.length} -> ${ReminderScheduler.BUDGET}`);
    }

    // 2. 按任务分组
    const desired: Map<string, ReminderPlan[]> = new Map<string, ReminderPlan[]>();
    for (let i = 0; i < kept.length; i++) {
      const ref = kept[i];
      const list = desired.get(ref.task.id);
      if (list === undefined) {
        desired.set(ref.task.id, [ref.plan]);
      } else {
        list.push(ref.plan);
      }
    }

    // 3. 账本里有、期望里没有的 → 取消
    const index = ReminderScheduler.readIndex();
    for (let i = 0; i < index.length; i++) {
      const taskId = index[i];
      if (!desired.has(taskId)) {
        await ReminderScheduler.cancelBook(taskId);
        Logger.info(`[Reminder] cancel all for task=${taskId} (no longer needed)`);
      }
    }

    // 4. 期望里有但签名变了的 → 重发
    const taskIds: string[] = [];
    desired.forEach((plans: ReminderPlan[], taskId: string) => {
      taskIds.push(taskId);
    });
    for (let i = 0; i < taskIds.length; i++) {
      const taskId = taskIds[i];
      await ReminderScheduler.applyTask(taskId, desired.get(taskId) as ReminderPlan[], pkgName);
    }

    // 5. 账本索引重建
    const newIndex: string[] = [];
    desired.forEach((plans: ReminderPlan[], taskId: string) => {
      newIndex.push(taskId);
    });
    TaskStore.get().putString(KEY_INDEX, JSON.stringify(newIndex));
  }

  /** 某任务期望的提醒列表 */
  static plansFor(task: TodoTask, now: number): ReminderPlan[] {
    const plans: ReminderPlan[] = [];
    if (task.done) {
      return plans;
    }
    if (task.dueAt > 0) {
      const morningAt = TimeUtil.atTime(task.dueAt, SettingsStore.morningHour(), SettingsStore.morningMinute());
      if (morningAt > now + MIN_LEAD_MS) {
        plans.push(new ReminderPlan('morning', morningAt, task.title,
          `今天到期 · ${TimeUtil.formatDue(task.dueAt)}`));
      }
      const dueAhead = task.dueAt - DUE_AHEAD_MS;
      if (dueAhead > now + MIN_LEAD_MS) {
        plans.push(new ReminderPlan('due10', dueAhead, task.title, '还有 10 分钟就到截止时间了'));
      }
    }
    if (task.remindAt > 0 && task.remindAt > now + MIN_LEAD_MS) {
      let duplicated = false;
      for (let i = 0; i < plans.length; i++) {
        if (Math.abs(plans[i].triggerAt - task.remindAt) < 60 * 1000) {
          duplicated = true;
          break;
        }
      }
      if (!duplicated) {
        plans.push(new ReminderPlan('user', task.remindAt, task.title, '提醒时间到了'));
      }
    }
    plans.sort((a: ReminderPlan, b: ReminderPlan): number => a.triggerAt - b.triggerAt);
    return plans;
  }

  private static sigOf(plans: ReminderPlan[]): string {
    const parts: string[] = [];
    for (let i = 0; i < plans.length; i++) {
      parts.push(`${plans[i].kind}@${plans[i].triggerAt}@${plans[i].title}`);
    }
    return parts.join('|');
  }

  private static async applyTask(taskId: string, plans: ReminderPlan[], pkgName: string): Promise<void> {
    const sig = ReminderScheduler.sigOf(plans);
    const old = ReminderBook.parse(TaskStore.get().getString(KEY_ITEM_PREFIX + taskId, ''));
    if (old !== null && old.sig === sig) {
      return;
    }
    await ReminderScheduler.cancelBook(taskId);
    const ids: number[] = [];
    for (let i = 0; i < plans.length; i++) {
      const id = await ReminderScheduler.publish(taskId, plans[i], pkgName);
      if (id > 0) {
        ids.push(id);
      }
    }
    const book = new ReminderBook();
    book.sig = sig;
    book.ids = ids;
    TaskStore.get().putString(KEY_ITEM_PREFIX + taskId, book.toJson());
    Logger.info(`[Reminder] task=${taskId} published=${ids.length} sig=${sig}`);
  }

  private static async cancelBook(taskId: string): Promise<void> {
    const old = ReminderBook.parse(TaskStore.get().getString(KEY_ITEM_PREFIX + taskId, ''));
    if (old === null) {
      return;
    }
    for (let i = 0; i < old.ids.length; i++) {
      try {
        await reminderAgentManager.cancelReminder(old.ids[i]);
      } catch (e) {
        // 已被系统清理/过期的 id 会报错，属正常
        Logger.debug(`[Reminder] cancel ${old.ids[i]} ignored: ${JSON.stringify(e)}`);
      }
    }
    TaskStore.get().removeKey(KEY_ITEM_PREFIX + taskId);
  }

  private static async publish(taskId: string, plan: ReminderPlan, pkgName: string): Promise<number> {
    const d = new Date(plan.triggerAt);
    const dateTime: reminderAgentManager.LocalDateTime = {
      year: d.getFullYear(),
      month: d.getMonth() + 1,
      day: d.getDate(),
      hour: d.getHours(),
      minute: d.getMinutes(),
      second: d.getSeconds()
    };
    const wantAgent: reminderAgentManager.WantAgent = {
      pkgName: pkgName,
      abilityName: 'EntryAbility',
      uri: WANT_URI_PREFIX + taskId
    };
    const req: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: dateTime,
      title: plan.title,
      content: plan.content,
      expiredContent: '已过期',
      notificationId: ReminderScheduler.notificationId(taskId, plan.kind),
      slotType: notificationManager.SlotType.CONTENT_INFORMATION,
      wantAgent: wantAgent,
      ringDuration: 3,
      actionButton: [
        {
          title: '知道了',
          type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE
        }
      ]
    };
    try {
      const id = await reminderAgentManager.publishReminder(req);
      Logger.info(`[Reminder] publish task=${taskId} kind=${plan.kind} at=${TimeUtil.describe(plan.triggerAt)} id=${id}`);
      return id;
    } catch (e) {
      Logger.error(`[Reminder] publish failed task=${taskId} kind=${plan.kind}: ${JSON.stringify(e)}`);
      return -1;
    }
  }

  /** 同一任务同类提醒固定通知 id，避免重复弹窗 */
  private static notificationId(taskId: string, kind: string): number {
    let h = 7;
    for (let i = 0; i < taskId.length; i++) {
      h = (h * 31 + taskId.charCodeAt(i)) % 100000;
    }
    const base = Math.abs(h) * 2;
    return kind === 'due10' ? base + 1 : base;
  }

  private static readIndex(): string[] {
    const raw = TaskStore.get().getString(KEY_INDEX, '[]');
    const result: string[] = [];
    try {
      const arr = JSON.parse(raw) as string[];
      if (arr instanceof Array) {
        for (let i = 0; i < arr.length; i++) {
          if (typeof arr[i] === 'string') {
            result.push(arr[i]);
          }
        }
      }
    } catch (e) {
      Logger.warn('[Reminder] index parse failed, reset');
    }
    return result;
  }

  /** 排障用：打印系统里当前有效的提醒条数 */
  static async logValidCount(): Promise<void> {
    try {
      const list = await reminderAgentManager.getValidReminders();
      Logger.info(`[Reminder] valid reminders=${list.length}`);
    } catch (e) {
      Logger.error(`[Reminder] getValidReminders failed: ${JSON.stringify(e)}`);
    }
  }
}
