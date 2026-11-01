import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { TodoTask } from '../common/Models';
import { TimeUtil } from '../common/TimeUtil';
import { Logger } from '../common/Logger';
import { TaskStore } from './TaskStore';

/** 变更原因：UI 据此决定"要不要播动画"（external 表示外部/系统触发，不播） */
export type TaskChangeReason = 'create' | 'update' | 'toggle' | 'delete' | 'order' | 'external';

export type TaskChangeListener = (reason: TaskChangeReason) => void;

/**
 * 任务仓储（业务入口）。主应用与卡片提供方进程共用同一份实现。
 *
 * **所有写操作落库后都会 notify()**，UI/卡片订阅即可，
 * 调用方不再需要记着"改完要手动刷新"——这是之前最容易漏的地方。
 */
export class TaskRepository {
  private static instance: TaskRepository | null = null;
  private listeners: TaskChangeListener[] = [];

  static get(): TaskRepository {
    if (TaskRepository.instance === null) {
      TaskRepository.instance = new TaskRepository();
    }
    return TaskRepository.instance;
  }

  init(context: common.Context): void {
    TaskStore.get().init(context);
  }

  isReady(): boolean {
    return TaskStore.get().isReady();
  }

  onChange(listener: TaskChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  offChange(listener: TaskChangeListener): void {
    const i = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  private notify(reason: TaskChangeReason): void {
    for (let i = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i](reason);
      } catch (e) {
        Logger.error(`[Repo] listener failed: ${JSON.stringify(e)}`);
      }
    }
  }

  /** 全量读取：未完成在前；有截止日期的按截止时间升序，无截止的按更新时间倒序 */
  listAll(): TodoTask[] {
    const list = TaskStore.get().list();
    list.sort((a: TodoTask, b: TodoTask): number => {
      if (a.done !== b.done) {
        return a.done ? 1 : -1;
      }
      const ad = a.dueAt > 0 ? a.dueAt : Number.MAX_SAFE_INTEGER;
      const bd = b.dueAt > 0 ? b.dueAt : Number.MAX_SAFE_INTEGER;
      if (ad !== bd) {
        return ad - bd;
      }
      return b.updatedAt - a.updatedAt;
    });
    return list;
  }

  getById(id: string): TodoTask | null {
    return TaskStore.get().get(id);
  }

  /** 新建任务（字段全部可空，title 为空时给默认名） */
  create(title: string, dueAt: number, remindAt: number, note: string, intoMyDay: boolean): TodoTask {
    const now = Date.now();
    const task = new TodoTask();
    task.id = util.generateRandomUUID(true);
    task.title = title.trim().length > 0 ? title.trim() : '未命名任务';
    task.dueAt = dueAt > 0 ? dueAt : 0;
    task.remindAt = remindAt > 0 ? remindAt : 0;
    task.note = note;
    task.done = false;
    task.doneAt = 0;
    task.createdAt = now;
    task.updatedAt = now;
    task.myDayDate = intoMyDay ? TimeUtil.todayKey() : '';
    task.myDayHiddenOn = '';
    task.reminderIds = [];
    // 新任务排在"我的一天"最后
    task.order = this.nextOrder();
    TaskStore.get().put(task);
    Logger.info(`[Repo] create id=${task.id} title=${task.title} due=${task.dueAt} remind=${task.remindAt} order=${task.order}`);
    this.notify('create');
    return task;
  }

  /** 取一个比现有最大值更大的排序号，保证新建的排在最后 */
  private nextOrder(): number {
    const all = TaskStore.get().list();
    let max = 0;
    for (let i = 0; i < all.length; i++) {
      if (all[i].order > max) {
        max = all[i].order;
      }
    }
    return max > 0 ? max + 1000 : Date.now();
  }

  /**
   * 拖拽排序落库：按传入顺序重排"我的一天"里这些任务的 order（步长 1000，留出手动插入空间）。
   * 只影响这批任务，其它任务的 order 不动。
   */
  reorderMyDay(ordered: TodoTask[]): void {
    const changed: TodoTask[] = [];
    for (let i = 0; i < ordered.length; i++) {
      const task = ordered[i];
      const next = (i + 1) * 1000;
      if (task.order !== next) {
        task.order = next;
        // 故意不动 updatedAt：排序不是内容变更，避免列表行的 key 变化导致整行重建
        changed.push(task);
      }
    }
    if (changed.length === 0) {
      return;
    }
    TaskStore.get().putMany(changed);
    Logger.info(`[Repo] reorderMyDay, changed=${changed.length}`);
    this.notify('order');
  }

  /** 卡片上的"快速新建"：进我的一天、无截止日期 */
  quickAddMyDay(): TodoTask {
    const task = this.create('新任务', 0, 0, '', true);
    Logger.info(`[Repo] quickAddMyDay id=${task.id}`);
    return task;
  }

  update(task: TodoTask): TodoTask {
    task.updatedAt = Date.now();
    TaskStore.get().put(task);
    this.notify('update');
    return task;
  }

  /** 勾选/取消勾选。返回更新后的任务，任务不存在返回 null */
  setDone(id: string, done: boolean): TodoTask | null {
    const task = TaskStore.get().get(id);
    if (task === null) {
      Logger.warn(`[Repo] setDone miss id=${id}`);
      return null;
    }
    task.done = done;
    task.doneAt = done ? Date.now() : 0;
    task.updatedAt = Date.now();
    TaskStore.get().put(task);
    Logger.info(`[Repo] setDone id=${id} done=${done}`);
    this.notify('toggle');
    return task;
  }

  /** 卡片消息是幂等的：只有当消息比当前状态更新时才应用 */
  toggleDone(id: string, msgTs: number): TodoTask | null {
    const task = TaskStore.get().get(id);
    if (task === null) {
      return null;
    }
    if (msgTs > 0 && task.updatedAt > msgTs) {
      Logger.warn(`[Repo] toggleDone stale msg id=${id} msgTs=${msgTs} updatedAt=${task.updatedAt}`);
      return task;
    }
    return this.setDone(id, !task.done);
  }

  remove(id: string): void {
    TaskStore.get().remove(id);
    Logger.info(`[Repo] remove id=${id}`);
    this.notify('delete');
  }

  /** 手动加入"我的一天" */
  addToMyDay(id: string): TodoTask | null {
    const task = TaskStore.get().get(id);
    if (task === null) {
      return null;
    }
    task.myDayDate = TimeUtil.todayKey();
    task.myDayHiddenOn = '';
    task.updatedAt = Date.now();
    TaskStore.get().put(task);
    Logger.info(`[Repo] addToMyDay id=${id}`);
    this.notify('update');
    return task;
  }

  /**
   * 从"我的一天"移出：清掉归属日期，并标记"今天移出过"。
   * 未完成且逾期的任务第二天仍会顺延回来（这是"继续出现"的语义）；
   * 想要彻底不再出现，就把它做完或删掉。
   */
  removeFromMyDay(id: string): TodoTask | null {
    const task = TaskStore.get().get(id);
    if (task === null) {
      return null;
    }
    task.myDayHiddenOn = TimeUtil.todayKey();
    task.myDayDate = '';
    task.updatedAt = Date.now();
    TaskStore.get().put(task);
    Logger.info(`[Repo] removeFromMyDay id=${id}`);
    this.notify('update');
    return task;
  }


}
