/**
 * 领域模型：任务
 *
 * 约定：
 * - `dueAt` / `remindAt` / `doneAt` 用 0 表示"没有"（Preferences 只存简单类型，避免 null 参与序列化）
 * - `myDayDate` / `myDayHiddenOn` 用 'YYYY-MM-DD'，空串表示无
 * - 分类（我的一天 / 全部任务 / 计划中）不落库，全部派生，见 MyDayService
 */
export class TodoTask {
  id: string = '';
  title: string = '';
  dueAt: number = 0;
  remindAt: number = 0;
  note: string = '';
  done: boolean = false;
  doneAt: number = 0;
  createdAt: number = 0;
  updatedAt: number = 0;
  /** 手动加入"我的一天"的日期 */
  myDayDate: string = '';
  /** 用户当天把"因截止日自动归类进来"的任务移出时记录日期 */
  myDayHiddenOn: string = '';
  /** 已发布的代理提醒 id */
  reminderIds: number[] = [];
  /** 手动排序序号（只在"我的一天"里生效；0 表示用 createdAt 兜底） */
  order: number = 0;

  hasDue(): boolean {
    return this.dueAt > 0;
  }

  hasRemind(): boolean {
    return this.remindAt > 0;
  }

  clone(): TodoTask {
    const t = new TodoTask();
    t.id = this.id;
    t.title = this.title;
    t.dueAt = this.dueAt;
    t.remindAt = this.remindAt;
    t.note = this.note;
    t.done = this.done;
    t.doneAt = this.doneAt;
    t.createdAt = this.createdAt;
    t.updatedAt = this.updatedAt;
    t.myDayDate = this.myDayDate;
    t.myDayHiddenOn = this.myDayHiddenOn;
    t.reminderIds = this.reminderIds.slice();
    t.order = this.order;
    return t;
  }

  toJson(): string {
    return JSON.stringify(this);
  }

  /**
   * 反序列化，任何字段异常都回退到默认值，绝不抛出——
   * 卡片进程和应用进程都会读同一份数据，容错比严格更重要。
   */
  static fromJson(raw: string): TodoTask | null {
    if (!raw || raw.length === 0) {
      return null;
    }
    let obj: TodoTaskJson | null = null;
    try {
      obj = JSON.parse(raw) as TodoTaskJson;
    } catch (e) {
      return null;
    }
    if (obj === null || obj === undefined) {
      return null;
    }
    const t = new TodoTask();
    t.id = typeof obj.id === 'string' ? obj.id : '';
    if (t.id.length === 0) {
      return null;
    }
    t.title = typeof obj.title === 'string' ? obj.title : '';
    t.dueAt = typeof obj.dueAt === 'number' ? obj.dueAt : 0;
    t.remindAt = typeof obj.remindAt === 'number' ? obj.remindAt : 0;
    t.note = typeof obj.note === 'string' ? obj.note : '';
    t.done = obj.done === true;
    t.doneAt = typeof obj.doneAt === 'number' ? obj.doneAt : 0;
    t.createdAt = typeof obj.createdAt === 'number' ? obj.createdAt : 0;
    t.updatedAt = typeof obj.updatedAt === 'number' ? obj.updatedAt : 0;
    t.myDayDate = typeof obj.myDayDate === 'string' ? obj.myDayDate : '';
    t.myDayHiddenOn = typeof obj.myDayHiddenOn === 'string' ? obj.myDayHiddenOn : '';
    t.order = typeof obj.order === 'number' ? obj.order : 0;
    t.reminderIds = [];
    if (obj.reminderIds instanceof Array) {
      const arr = obj.reminderIds as number[];
      for (let i = 0; i < arr.length; i++) {
        const v = arr[i];
        if (typeof v === 'number') {
          t.reminderIds.push(v);
        }
      }
    }
    return t;
  }
}

/** JSON 落库结构，字段全 optional 以便对旧数据/脏数据容错 */
interface TodoTaskJson {
  id?: string;
  title?: string;
  dueAt?: number;
  remindAt?: number;
  note?: string;
  done?: boolean;
  doneAt?: number;
  createdAt?: number;
  updatedAt?: number;
  myDayDate?: string;
  myDayHiddenOn?: string;
  reminderIds?: number[];
  order?: number;
}

/** 卡片渲染用的最小快照项 */
export class CardItem {
  id: string = '';
  /** 标题（短字段名是为了缩小 IPC 数据） */
  t: string = '';
  /** 截止时间戳，0 表示无 */
  due: number = 0;
  /** 是否逾期 */
  od: boolean = false;

  constructor(id: string, title: string, due: number, overdue: boolean) {
    this.id = id;
    this.t = title;
    this.due = due;
    this.od = overdue;
  }
}

/** 推给卡片的数据快照 */
export class MyDaySnapshot {
  /** 快照版本，卡片侧做兼容 */
  v: number = 1;
  date: string = '';
  /** 我的一天的任务总数，**含已完成** */
  total: number = 0;
  /** 其中已完成的数量（total >= done） */
  done: number = 0;
  /** 只放未完成的任务，用于列表渲染 */
  items: CardItem[] = [];
  updatedAt: number = 0;

  toJson(): string {
    return JSON.stringify(this);
  }
}

/** 卡片 → 应用的消息体（经 postCardAction message，落地是字符串） */
export class CardAction {
  op: string = '';
  id: string = '';
  ts: number = 0;

  static parse(raw: string): CardAction | null {
    if (!raw || raw.length === 0) {
      return null;
    }
    let obj: CardActionJson | null = null;
    try {
      obj = JSON.parse(raw) as CardActionJson;
    } catch (e) {
      return null;
    }
    if (obj === null || obj === undefined || typeof obj.op !== 'string') {
      return null;
    }
    const a = new CardAction();
    a.op = obj.op as string;
    a.id = typeof obj.id === 'string' ? obj.id : '';
    a.ts = typeof obj.ts === 'number' ? obj.ts : 0;
    return a;
  }
}

interface CardActionJson {
  op?: string;
  id?: string;
  ts?: number;
}

export class CardOp {
  static readonly TOGGLE: string = 'toggle';
  static readonly QUICK_ADD: string = 'quickAdd';
  static readonly UNDO: string = 'undo';
  static readonly OPEN_APP: string = 'openApp';
}

/** 编辑面板的数据载体（新建与编辑共用） */
export class TaskDraft {
  id: string = '';
  isNew: boolean = true;
  title: string = '';
  dueAt: number = 0;
  remindAt: number = 0;
  note: string = '';
  intoMyDay: boolean = true;

  static fromTask(task: TodoTask): TaskDraft {
    const d = new TaskDraft();
    d.id = task.id;
    d.isNew = false;
    d.title = task.title;
    d.dueAt = task.dueAt;
    d.remindAt = task.remindAt;
    d.note = task.note;
    d.intoMyDay = task.myDayDate.length > 0;
    return d;
  }

  static empty(): TaskDraft {
    const d = new TaskDraft();
    d.isNew = true;
    d.intoMyDay = true;
    return d;
  }

  clone(): TaskDraft {
    const d = new TaskDraft();
    d.id = this.id;
    d.isNew = this.isNew;
    d.title = this.title;
    d.dueAt = this.dueAt;
    d.remindAt = this.remindAt;
    d.note = this.note;
    d.intoMyDay = this.intoMyDay;
    return d;
  }
}
