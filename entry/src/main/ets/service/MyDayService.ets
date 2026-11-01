import { TodoTask, MyDaySnapshot, CardItem } from '../common/Models';
import { TimeUtil } from '../common/TimeUtil';

/** 「我的一天」计数：total 含已完成，done 只统计其中的已完成 */
export class MyDayStats {
  total: number = 0;
  done: number = 0;
}

/**
 * "我的一天" 派生逻辑（纯函数，可单测，无副作用）。
 *
 * 为什么不落库：需求说"有截止日期的任务在截止当天自动进入我的一天"。
 * 如果落库就必须有人每天 0 点执行写操作——而卡片定点刷新只在卡片可见时触发、
 * workScheduler 又不保证准点。改成"读取时派生"后，跨天永远正确，零后台依赖。
 *
 * 关键口径：
 * - **归属（scope）**只看"是否属于今天的我的一天"，与完成状态无关；
 * - 列表只展示未完成的（`myDayTasks`），计数则把已完成的一起算进去（`myDayStats`），
 *   否则做完最后一个任务会显示成 "1/0"。
 */
export class MyDayService {
  /**
   * 是否属于今天的"我的一天"（**不考虑完成状态**）。
   *
   * 规则（按优先级）：
   * 1. 今天被手动移出过 → 今天不出现
   * 2. 今天手动加入的 → 出现
   * 3. 截止日就是今天 → 出现
   * 4. 已逾期还没做完 → 继续出现（昨天/更早没做完的都会顺延到今天）
   * 5. 往期手动加入过、且还没做完 → 顺延
   * 6. 上面这些如果今天完成了，仍计入今天的统计（只是不进列表）
   */
  static inScope(task: TodoTask, todayKey: string, now: number): boolean {
    if (task.myDayHiddenOn === todayKey) {
      return false;
    }
    if (task.myDayDate === todayKey) {
      return true;
    }
    const startOfToday = TimeUtil.startOfDay(now);
    const doneToday = task.done && task.doneAt > 0 && TimeUtil.isSameDay(task.doneAt, now);
    if (task.dueAt > 0) {
      if (TimeUtil.isSameDay(task.dueAt, now)) {
        return true;
      }
      if (task.dueAt < startOfToday) {
        // 逾期的：没做完就一直留着；今天做完的今天还计入
        return !task.done || doneToday;
      }
    }
    if (task.myDayDate.length > 0 && task.myDayDate < todayKey) {
      // 往期手动加入、还没完成 → 顺延到今天
      return !task.done || doneToday;
    }
    return false;
  }

  /** 兼容旧调用：判断"是否在我的一天里"，同样忽略完成状态 */
  static isInMyDay(task: TodoTask, todayKey: string, now: number): boolean {
    return MyDayService.inScope(task, todayKey, now);
  }

  /** 是否属于"从以前顺延过来"的任务（既不是今天加的，也不是今天到期的） */
  static isCarriedOver(task: TodoTask, todayKey: string, now: number): boolean {
    if (!MyDayService.inScope(task, todayKey, now)) {
      return false;
    }
    if (task.myDayDate === todayKey) {
      return false;
    }
    if (task.dueAt > 0 && TimeUtil.isSameDay(task.dueAt, now)) {
      return false;
    }
    return true;
  }

  /** 今天"我的一天"里**还没完成**的任务，按截止时间、创建时间排序 */
  static myDayTasks(tasks: TodoTask[], todayKey: string, now: number): TodoTask[] {
    const result: TodoTask[] = [];
    for (let i = 0; i < tasks.length; i++) {
      const task = tasks[i];
      if (task.done) {
        continue;
      }
      if (MyDayService.inScope(task, todayKey, now)) {
        result.push(task);
      }
    }
    result.sort((a: TodoTask, b: TodoTask): number => {
      // 手动排序优先；没有排序号的（老数据）用创建时间兜底
      const ao = a.order > 0 ? a.order : a.createdAt;
      const bo = b.order > 0 ? b.order : b.createdAt;
      if (ao !== bo) {
        return ao - bo;
      }
      return a.createdAt - b.createdAt;
    });
    return result;
  }

  /** 拖拽排序：把 from 位置的元素移动到 to 位置，返回新数组（不修改入参，便于单测） */
  static moveItem(list: TodoTask[], from: number, to: number): TodoTask[] {
    const copy: TodoTask[] = [];
    for (let i = 0; i < list.length; i++) {
      copy.push(list[i]);
    }
    if (from < 0 || from >= copy.length || to < 0 || to >= copy.length || from === to) {
      return copy;
    }
    const moved = copy.splice(from, 1);
    copy.splice(to, 0, moved[0]);
    return copy;
  }

  /** 今天"我的一天"的进度：total 含已完成，done 是其中已完成的数量 */
  static myDayStats(tasks: TodoTask[], todayKey: string, now: number): MyDayStats {
    const stats = new MyDayStats();
    for (let i = 0; i < tasks.length; i++) {
      const task = tasks[i];
      if (!MyDayService.inScope(task, todayKey, now)) {
        continue;
      }
      stats.total++;
      if (task.done) {
        stats.done++;
      }
    }
    return stats;
  }

  /** 卡片快照：只带渲染需要的字段，条数受限（卡片尺寸有限） */
  static buildSnapshot(tasks: TodoTask[], todayKey: string, now: number, limit: number): MyDaySnapshot {
    const myDay = MyDayService.myDayTasks(tasks, todayKey, now);
    const stats = MyDayService.myDayStats(tasks, todayKey, now);
    const snap = new MyDaySnapshot();
    snap.date = todayKey;
    snap.total = stats.total;
    snap.done = stats.done;
    snap.updatedAt = now;
    const max = Math.min(limit, myDay.length);
    for (let i = 0; i < max; i++) {
      const t = myDay[i];
      snap.items.push(new CardItem(t.id, t.title, t.dueAt, TimeUtil.isOverdue(t.dueAt, now)));
    }
    return snap;
  }
}
