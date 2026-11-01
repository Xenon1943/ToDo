/** 时间工具：全部使用本地时区，日期跨天以本地 0 点为界 */
export class TimeUtil {
  static readonly DAY_MS: number = 24 * 60 * 60 * 1000;

  static pad2(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }

  /** 'YYYY-MM-DD'（本地时区） */
  static dayKey(ms: number): string {
    const d = new Date(ms);
    return `${d.getFullYear()}-${TimeUtil.pad2(d.getMonth() + 1)}-${TimeUtil.pad2(d.getDate())}`;
  }

  static todayKey(): string {
    return TimeUtil.dayKey(Date.now());
  }

  /** 当天 00:00:00.000 的时间戳 */
  static startOfDay(ms: number): number {
    const d = new Date(ms);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  static addDays(ms: number, days: number): number {
    return TimeUtil.startOfDay(ms) + days * TimeUtil.DAY_MS;
  }

  /** 指定某天的某个时刻 */
  static atTime(dayMs: number, hour: number, minute: number): number {
    const d = new Date(TimeUtil.startOfDay(dayMs));
    d.setHours(hour, minute, 0, 0);
    return d.getTime();
  }

  static isSameDay(a: number, b: number): boolean {
    return TimeUtil.startOfDay(a) === TimeUtil.startOfDay(b);
  }

  static isToday(ms: number): boolean {
    return ms > 0 && TimeUtil.isSameDay(ms, Date.now());
  }

  /** 是否已逾期：有截止时间且早于当前 */
  static isOverdue(dueAt: number, now: number): boolean {
    return dueAt > 0 && dueAt < now;
  }

  /** 列表用短格式：今天 18:00 / 明天 09:30 / 昨天 12:00 / 10月30日 18:00 / 10月30日 */
  static formatDue(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    const now = Date.now();
    const d = new Date(ms);
    const hhmm = `${TimeUtil.pad2(d.getHours())}:${TimeUtil.pad2(d.getMinutes())}`;
    const hasTime = !(d.getHours() === 0 && d.getMinutes() === 0);
    const today = TimeUtil.startOfDay(now);
    const target = TimeUtil.startOfDay(ms);
    const diffDays = Math.round((target - today) / TimeUtil.DAY_MS);
    let dayText = '';
    if (diffDays === 0) {
      dayText = '今天';
    } else if (diffDays === 1) {
      dayText = '明天';
    } else if (diffDays === -1) {
      dayText = '昨天';
    } else {
      dayText = `${d.getMonth() + 1}月${d.getDate()}日`;
      if (d.getFullYear() !== new Date(now).getFullYear()) {
        dayText = `${d.getFullYear()}年${dayText}`;
      }
    }
    return hasTime ? `${dayText} ${hhmm}` : dayText;
  }

  /** 编辑面板用完整格式：2026-10-30 18:00 */
  static formatDateTime(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    const d = new Date(ms);
    return `${TimeUtil.dayKey(ms)} ${TimeUtil.pad2(d.getHours())}:${TimeUtil.pad2(d.getMinutes())}`;
  }

  /** 相对当前时刻的简短描述，用于提醒排期调试日志 */
  static describe(ms: number): string {
    return `${TimeUtil.formatDateTime(ms)}(${Math.round((ms - Date.now()) / 60000)}分钟后)`;
  }
}
