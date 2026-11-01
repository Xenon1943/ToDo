import { common } from '@kit.AbilityKit';
import { formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { TodoTask } from '../common/Models';
import { TimeUtil } from '../common/TimeUtil';
import { Logger } from '../common/Logger';
import { AppConfig } from '../common/AppConfig';
import { MyDayService } from './MyDayService';
import { TaskRepository } from '../data/TaskRepository';

/** 卡片数据桥：快照构建 + 刷新触发（主应用与卡片进程共用） */
export class FormBridge {
  /** 卡片渲染数据：一段 JSON 字符串，通过 LocalStorageProp 下发 */
  static snapshotJson(tasks: TodoTask[], limit: number): string {
    const now = Date.now();
    const snap = MyDayService.buildSnapshot(tasks, TimeUtil.todayKey(), now, limit);
    return snap.toJson();
  }

  /** 用当前存储里的最新数据构造一份卡片数据（每次都新建，避免复用同一个对象） */
  static currentBinding(): formBindingData.FormBindingData {
    return FormBridge.binding(FormBridge.snapshotJson(TaskRepository.get().listAll(), AppConfig.CARD_ITEM_LIMIT));
  }

  static binding(json: string): formBindingData.FormBindingData {
    const obj: Record<string, string> = { 'myday': json };
    return formBindingData.createFormBindingData(obj);
  }

  /**
   * 主应用侧：数据一变就把最新快照**直接**推到桌面上的每张卡片。
   *
   * 之前只用 `reloadAllForms`（走 FMS → 拉起卡片进程 → onUpdateForm → updateForm），
   * 链路长、体感上会"卡很久"。这里先用 `getPublishedRunningFormInfos()`（API 20+）
   * 拿到已加桌的 formId，逐张 `updateForm` 直推；只有推失败时才退回 `reloadAllForms` 兜底。
   */
  static async refreshAll(context: common.UIAbilityContext): Promise<void> {
    const json = FormBridge.snapshotJson(TaskRepository.get().listAll(), AppConfig.CARD_ITEM_LIMIT);
    let formCount = 0;
    let pushed = 0;
    let enumerationOk = false;
    try {
      const forms: formInfo.RunningFormInfo[] = await formProvider.getPublishedRunningFormInfos();
      enumerationOk = true;
      formCount = forms.length;
      for (let i = 0; i < formCount; i++) {
        const ok = await FormBridge.pushToForm(forms[i].formId, json);
        if (ok) {
          pushed++;
        }
      }
      Logger.info(`[Form] direct push ${pushed}/${formCount}`);
    } catch (e) {
      Logger.error(`[Form] getPublishedRunningFormInfos failed: ${JSON.stringify(e)}`);
    }

    if (enumerationOk && formCount === 0) {
      Logger.info('[Form] no form enumerated on desktop');
    }
    // 无论直推成功与否，都再走一次 FMS 通道（reloadAllForms → 卡片进程 onUpdateForm）。
    // 直推快但不保证渲染，FMS 慢但一定会让卡片进程重读数据；两条都走才是"改完就能看到"。
    try {
      const count = await formProvider.reloadAllForms(context);
      Logger.info(`[Form] reloadAllForms ok, affected=${count}, directPush=${pushed}/${formCount}`);
    } catch (e) {
      Logger.error(`[Form] reloadAllForms failed: ${JSON.stringify(e)}`);
    }
  }

  /** 单卡片回推（卡片进程内用，也用于主应用直推）。返回是否成功 */
  static async pushToForm(formId: string, json: string): Promise<boolean> {
    try {
      await formProvider.updateForm(formId, FormBridge.binding(json));
      Logger.info(`[Form] updateForm ok, formId=${formId}, bytes=${json.length}`);
      return true;
    } catch (e) {
      // 16501001 卡片不存在 / 16501003 无权操作：卡片已被移除，不必再重试
      Logger.error(`[Form] updateForm failed formId=${formId}: ${JSON.stringify(e)}`);
      return false;
    }
  }

  /** 卡片进程里：读库 → 生成快照 → 回推 */
  static async pushCurrentToForm(formId: string): Promise<void> {
    await FormBridge.pushToForm(formId, FormBridge.snapshotJson(
      TaskRepository.get().listAll(), AppConfig.CARD_ITEM_LIMIT));
  }

  static formName(): string {
    return AppConfig.FORM_NAME;
  }
}
