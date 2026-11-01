import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { TodoTask } from '../common/Models';
import { Logger } from '../common/Logger';

const STORE_NAME: string = 'todo_store';
const KEY_PREFIX: string = 'task:';
const KEY_VERSION: string = 'meta:version';

/**
 * 任务存储（底层）。
 *
 * 关键设计：
 * 1. 存储模式必须是 **GSKV**：卡片提供方进程与应用主进程是两个进程，只有 GSKV 模式官方明确
 *    "支持多进程并发读写"。XML 模式官方明确"不支持在多进程场景下使用"，会损坏文件。
 * 2. 每条任务一个 key（`task:<id>`），两个进程同时写不同任务互不冲突。
 * 3. 进程内做"版本号 + 缓存"：`meta:version` 每次写入自增，读取前比对版本，
 *    变了才全量重读。这样跨进程写入能被另一个进程察觉（GSKV 实时落盘）。
 */
export class TaskStore {
  private static instance: TaskStore | null = null;

  private prefs: preferences.Preferences | null = null;
  private cache: Map<string, TodoTask> = new Map<string, TodoTask>();
  private cachedVersion: number = -1;
  private ready: boolean = false;
  private gskv: boolean = false;

  static get(): TaskStore {
    if (TaskStore.instance === null) {
      TaskStore.instance = new TaskStore();
    }
    return TaskStore.instance;
  }

  /** 主应用与卡片提供方进程各自调用一次，传各自的 Context（同一沙箱，指向同一份数据） */
  init(context: common.Context): void {
    if (this.prefs !== null) {
      return;
    }
    try {
      this.gskv = preferences.isStorageTypeSupported(preferences.StorageType.GSKV);
      const opts: preferences.Options = this.gskv
        ? { name: STORE_NAME, storageType: preferences.StorageType.GSKV }
        : { name: STORE_NAME };
      this.prefs = preferences.getPreferencesSync(context, opts);
      this.ready = true;
      Logger.info(`[Repo] store init ok, gskv=${this.gskv}`);
    } catch (e) {
      this.prefs = null;
      this.ready = false;
      Logger.error(`[Repo] store init failed: ${JSON.stringify(e)}`);
    }
  }

  isReady(): boolean {
    return this.ready && this.prefs !== null;
  }

  isGskv(): boolean {
    return this.gskv;
  }

  /** 强制全量重读（跨进程场景下由调用方在关键入口调用） */
  reload(): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    const next: Map<string, TodoTask> = new Map<string, TodoTask>();
    try {
      const all = p.getAllSync() as Record<string, string>;
      const keys = Object.keys(all);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        if (!key.startsWith(KEY_PREFIX)) {
          continue;
        }
        const raw = all[key];
        if (typeof raw !== 'string') {
          continue;
        }
        const task = TodoTask.fromJson(raw);
        if (task !== null) {
          next.set(task.id, task);
        }
      }
      this.cache = next;
      this.cachedVersion = this.readVersion();
      Logger.info(`[Repo] reload, tasks=${next.size}, version=${this.cachedVersion}`);
    } catch (e) {
      Logger.error(`[Repo] reload failed: ${JSON.stringify(e)}`);
    }
  }

  /** 版本变了就重读，避免每次读取都全量解析 */
  private ensureFresh(): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    const v = this.readVersion();
    if (v !== this.cachedVersion) {
      this.reload();
    }
  }

  private readVersion(): number {
    const p = this.prefs;
    if (p === null) {
      return 0;
    }
    try {
      const v = p.getSync(KEY_VERSION, 0);
      return typeof v === 'number' ? v : 0;
    } catch (e) {
      return 0;
    }
  }

  private bumpVersion(): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    try {
      p.putSync(KEY_VERSION, this.readVersion() + 1);
    } catch (e) {
      Logger.error(`[Repo] bumpVersion failed: ${JSON.stringify(e)}`);
    }
  }

  /** GSKV 写即落盘；XML 模式必须 flush，否则另一个进程读不到 */
  private flushIfNeeded(): void {
    const p = this.prefs;
    if (p === null || this.gskv) {
      return;
    }
    p.flush().then(() => {
    }).catch((e: Object) => {
      Logger.error(`[Repo] flush failed: ${JSON.stringify(e)}`);
    });
  }

  /**
   * 读取一律返回**拷贝**：调用方随便改都不会污染缓存，
   * 想落库必须显式 put——避免"改了内存但没写盘"的隐性不一致。
   */
  list(): TodoTask[] {
    this.ensureFresh();
    const result: TodoTask[] = [];
    this.cache.forEach((task: TodoTask) => {
      result.push(task.clone());
    });
    return result;
  }

  get(id: string): TodoTask | null {
    this.ensureFresh();
    const t = this.cache.get(id);
    return t === undefined ? null : t.clone();
  }

  put(task: TodoTask): void {
    const p = this.prefs;
    if (p === null) {
      Logger.error('[Repo] put but store not ready');
      return;
    }
    try {
      p.putSync(KEY_PREFIX + task.id, task.toJson());
      this.bumpVersion();
      this.flushIfNeeded();
      this.cache.set(task.id, task.clone());
      this.cachedVersion = this.readVersion();
    } catch (e) {
      Logger.error(`[Repo] put failed id=${task.id}: ${JSON.stringify(e)}`);
    }
  }

  /** 批量写入（拖拽排序时用）：一次版本号自增，避免逐条写放大跨进程重载 */
  putMany(tasks: TodoTask[]): void {
    const p = this.prefs;
    if (p === null || tasks.length === 0) {
      return;
    }
    try {
      for (let i = 0; i < tasks.length; i++) {
        const task = tasks[i];
        p.putSync(KEY_PREFIX + task.id, task.toJson());
        this.cache.set(task.id, task.clone());
      }
      this.bumpVersion();
      this.flushIfNeeded();
      this.cachedVersion = this.readVersion();
      Logger.info(`[Repo] putMany, count=${tasks.length}`);
    } catch (e) {
      Logger.error(`[Repo] putMany failed: ${JSON.stringify(e)}`);
    }
  }

  remove(id: string): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    try {
      p.deleteSync(KEY_PREFIX + id);
      this.bumpVersion();
      this.flushIfNeeded();
      this.cache.delete(id);
      this.cachedVersion = this.readVersion();
    } catch (e) {
      Logger.error(`[Repo] remove failed id=${id}: ${JSON.stringify(e)}`);
    }
  }



  // ---- 通用 KV（设置项等），与任务共用同一个 Preferences 文件 ----

  getNumber(key: string, defValue: number): number {
    const p = this.prefs;
    if (p === null) {
      return defValue;
    }
    try {
      const v = p.getSync(key, defValue);
      return typeof v === 'number' ? v : defValue;
    } catch (e) {
      return defValue;
    }
  }

  putNumber(key: string, value: number): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    try {
      p.putSync(key, value);
      this.flushIfNeeded();
    } catch (e) {
      Logger.error(`[Repo] putNumber failed key=${key}: ${JSON.stringify(e)}`);
    }
  }

  getString(key: string, defValue: string): string {
    const p = this.prefs;
    if (p === null) {
      return defValue;
    }
    try {
      const v = p.getSync(key, defValue);
      return typeof v === 'string' ? v : defValue;
    } catch (e) {
      return defValue;
    }
  }

  putString(key: string, value: string): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    try {
      p.putSync(key, value);
      this.flushIfNeeded();
    } catch (e) {
      Logger.error(`[Repo] putString failed key=${key}: ${JSON.stringify(e)}`);
    }
  }

  removeKey(key: string): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    try {
      p.deleteSync(key);
      this.flushIfNeeded();
    } catch (e) {
      Logger.error(`[Repo] removeKey failed key=${key}: ${JSON.stringify(e)}`);
    }
  }
}
