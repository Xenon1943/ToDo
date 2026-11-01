import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { TaskRepository } from '../data/TaskRepository';
import { Logger } from '../common/Logger';
import { AppConfig } from '../common/AppConfig';

/** 启动/回前台时传给页面的动作（卡片 router 事件会带 parameters 进来） */
export class LaunchAction {
  static readonly NONE: string = '';
  static readonly QUICK_ADD: string = 'quickAdd';
  static readonly OPEN_TASK: string = 'openTask';
  static readonly OPEN_MY_DAY: string = 'openMyDay';
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info('[Ability] onCreate');
    TaskRepository.get().init(this.context);
    AppStorage.setOrCreate<number>('foregroundTick', 0);
    this.applyWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info('[Ability] onNewWant');
    this.applyWant(want);
  }

  /** 卡片 router 事件 / 代理提醒点击带过来的参数：{ action, taskId } 或 todo://task/<id> */
  private applyWant(want: Want): void {
    let action: string = LaunchAction.NONE;
    let taskId: string = '';
    const params = want.parameters;
    if (params !== undefined && params !== null) {
      const a = params['action'];
      const t = params['taskId'];
      if (typeof a === 'string' && a.length > 0) {
        action = a;
      }
      if (typeof t === 'string') {
        taskId = t;
      }
    }
    // 代理提醒的 wantAgent 用的是 uri
    const uri = want.uri;
    if (action === LaunchAction.NONE && uri !== undefined && uri.length > 0
      && uri.startsWith(AppConfig.WANT_URI_PREFIX)) {
      action = LaunchAction.OPEN_TASK;
      taskId = uri.substring(AppConfig.WANT_URI_PREFIX.length);
    }
    if (action === LaunchAction.NONE) {
      AppStorage.setOrCreate<string>('launchAction', LaunchAction.NONE);
      return;
    }
    const payload: LaunchPayload = { action: action, taskId: taskId };
    AppStorage.setOrCreate<string>('launchAction', JSON.stringify(payload));
    Logger.info(`[Ability] launchAction=${action} taskId=${taskId}`);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 先设全屏 + 量出安全区，再加载页面：这样首帧就有正确的状态栏高度，不会先顶到状态栏再跳一下
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).then(() => {
        Logger.info('[Ability] setWindowLayoutFullScreen ok');
      }).catch((e: Object) => {
        Logger.error(`[Ability] setWindowLayoutFullScreen failed: ${JSON.stringify(e)}`);
      });
      EntryAbility.publishAvoidArea(win);
    } catch (e) {
      Logger.error(`[Ability] window setup failed: ${JSON.stringify(e)}`);
      AppStorage.setOrCreate<number>('statusBarPx', 0);
      AppStorage.setOrCreate<number>('navBarPx', 0);
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.error(`[Ability] loadContent failed: ${JSON.stringify(err)}`);
        return;
      }
      Logger.info('[Ability] loadContent ok');
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      Logger.error(`[Ability] setColorMode failed: ${JSON.stringify(err)}`);
    }
  }

  /** 把状态栏/导航栏高度（px）放进 AppStorage，页面据此给内容留安全边距 */
  private static publishAvoidArea(win: window.Window): void {
    try {
      const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const top: number = area.topRect !== undefined ? area.topRect.height : 0;
      const bottom: number = area.bottomRect !== undefined ? area.bottomRect.height : 0;
      AppStorage.setOrCreate<number>('statusBarPx', top);
      AppStorage.setOrCreate<number>('navBarPx', bottom);
      Logger.info(`[Ability] avoid area top=${top}px bottom=${bottom}px`);
    } catch (e) {
      Logger.error(`[Ability] getWindowAvoidArea failed: ${JSON.stringify(e)}`);
      AppStorage.setOrCreate<number>('statusBarPx', 0);
      AppStorage.setOrCreate<number>('navBarPx', 0);
    }
  }

  onForeground(): void {
    // 从卡片/后台回来：通知页面重新加载（onForeground 要求回调内只做轻量操作，重活交给页面）
    const tick = AppStorage.get<number>('foregroundTick');
    AppStorage.setOrCreate<number>('foregroundTick', (tick === undefined ? 0 : tick) + 1);
    Logger.info('[Ability] onForeground');
  }

  onBackground(): void {
    Logger.info('[Ability] onBackground');
  }

  onDestroy(): void {
    Logger.info('[Ability] onDestroy');
  }
}

interface LaunchPayload {
  action: string;
  taskId: string;
}
