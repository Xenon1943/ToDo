import { TaskStore } from './TaskStore';

const KEY_MORNING_HOUR: string = 'setting:morningHour';
const KEY_MORNING_MINUTE: string = 'setting:morningMinute';
const KEY_REMIND_ENABLED: string = 'setting:remindEnabled';
const KEY_NOTIFY_ASKED: string = 'setting:notifyAsked';

/**
 * 设置项。与任务共用同一个 Preferences 文件（不额外 bump 任务版本号，
 * 避免"改设置"导致另一个进程白重载一遍任务）。
 */
export class SettingsStore {
  /** 早上提醒时刻，默认 08:00 */
  static morningHour(): number {
    return TaskStore.get().getNumber(KEY_MORNING_HOUR, 8);
  }

  static morningMinute(): number {
    return TaskStore.get().getNumber(KEY_MORNING_MINUTE, 0);
  }

  static setMorning(hour: number, minute: number): void {
    TaskStore.get().putNumber(KEY_MORNING_HOUR, hour);
    TaskStore.get().putNumber(KEY_MORNING_MINUTE, minute);
  }

  /** 用户是否开启了提醒（通知授权被拒时置 0，界面上要显式提示） */
  static remindEnabled(): boolean {
    return TaskStore.get().getNumber(KEY_REMIND_ENABLED, 1) === 1;
  }

  static setRemindEnabled(enabled: boolean): void {
    TaskStore.get().putNumber(KEY_REMIND_ENABLED, enabled ? 1 : 0);
  }

  static morningText(): string {
    const h = SettingsStore.morningHour();
    const m = SettingsStore.morningMinute();
    return `${h < 10 ? '0' + h : h}:${m < 10 ? '0' + m : m}`;
  }

  /** 是否已经弹过通知授权（避免每次启动都打扰用户） */
  static notifyAsked(): boolean {
    return TaskStore.get().getNumber(KEY_NOTIFY_ASKED, 0) === 1;
  }

  static setNotifyAsked(): void {
    TaskStore.get().putNumber(KEY_NOTIFY_ASKED, 1);
  }
}
