import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 统一日志。
 * 刷新链路（卡片 ↔ 应用）问题排查全靠这里，所以所有关键节点必须打点，
 * 关键字固定为 [Form]/[Repo]/[Reminder]/[MyDay]，方便 hilog 过滤。
 */
export class Logger {
  static readonly DOMAIN: number = 0xA001;
  static readonly TAG: string = 'TodoApp';

  static info(msg: string): void {
    hilog.info(Logger.DOMAIN, Logger.TAG, '%{public}s', msg);
  }

  static warn(msg: string): void {
    hilog.warn(Logger.DOMAIN, Logger.TAG, '%{public}s', msg);
  }

  static error(msg: string): void {
    hilog.error(Logger.DOMAIN, Logger.TAG, '%{public}s', msg);
  }

  static debug(msg: string): void {
    hilog.debug(Logger.DOMAIN, Logger.TAG, '%{public}s', msg);
  }
}
