import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CardAction, CardOp } from '../common/Models';
import { Logger } from '../common/Logger';
import { AppConfig } from '../common/AppConfig';
import { TaskRepository } from '../data/TaskRepository';
import { TaskStore } from '../data/TaskStore';
import { FormBridge } from '../service/FormBridge';
import { ReminderScheduler } from '../service/ReminderScheduler';

/**
 * 卡片提供方（独立进程，共享应用沙箱）。
 *
 * 注意：本进程生命周期调度完成后只再存活约 10 秒，所以这里只做
 * "轻量读改写 + 回推卡片"，绝不在这里做批量操作或长任务。
 */
export default class TodoFormAbility extends FormExtensionAbility {
  private initOnce(): void {
    TaskRepository.get().init(this.context);
  }

  /** 生成最新快照：先强制从磁盘重读，保证拿到的是另一个进程刚写的状态 */
  private snapshot(): string {
    TaskStore.get().reload();
    return FormBridge.snapshotJson(TaskRepository.get().listAll(), AppConfig.CARD_ITEM_LIMIT);
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    this.initOnce();
    Logger.info('[Form] onAddForm');
    return FormBridge.binding(this.snapshot());
  }

  onUpdateForm(formId: string): void {
    this.initOnce();
    Logger.info(`[Form] onUpdateForm formId=${formId}`);
    const json = this.snapshot();
    formProvider.updateForm(formId, FormBridge.binding(json)).then(() => {
      Logger.info(`[Form] onUpdateForm pushed formId=${formId}`);
    }).catch((err: BusinessError) => {
      Logger.error(`[Form] onUpdateForm push failed formId=${formId}: ${err.code} ${err.message}`);
    });
  }

  onFormEvent(formId: string, message: string): void {
    this.initOnce();
    Logger.info(`[Form] onFormEvent formId=${formId} message=${message}`);
    this.handle(formId, message).then(() => {
    }).catch((err: BusinessError) => {
      Logger.error(`[Form] onFormEvent handle failed: ${JSON.stringify(err)}`);
    });
  }

  /**
   * 卡片上的交互统一走 message 事件：
   * - toggle   ：勾选/取消勾选（带 ts 做幂等）
   * 说明：卡片上的"新建"走的是 router 拉起应用新建页，不再在这里直接建任务。
   * 处理完立刻回推快照，再做提醒对账（对账失败不影响卡片状态）。
   */
  private async handle(formId: string, message: string): Promise<void> {
    const action = CardAction.parse(message);
    if (action === null) {
      Logger.warn(`[Form] ignore unknown message: ${message}`);
      return;
    }
    const repo = TaskRepository.get();
    if (action.op === CardOp.TOGGLE) {
      repo.toggleDone(action.id, action.ts);
    } else {
      Logger.warn(`[Form] unsupported op=${action.op}`);
      return;
    }
    const json = this.snapshot();
    await FormBridge.pushToForm(formId, json);
    // 提醒排期跟随任务状态变化（异步，失败只记日志）
    try {
      await ReminderScheduler.sync(this.context, repo.listAll());
    } catch (e) {
      Logger.error(`[Form] reminder sync failed: ${JSON.stringify(e)}`);
    }
  }

  onRemoveForm(formId: string): void {
    Logger.info(`[Form] onRemoveForm formId=${formId}`);
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
