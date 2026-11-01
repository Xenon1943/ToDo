/** 全局常量：卡片事件里要显式带 bundleName/moduleName/abilityName */
export class AppConfig {
  static readonly BUNDLE_NAME: string = 'com.xenon.todo';
  static readonly MODULE_NAME: string = 'entry';
  static readonly MAIN_ABILITY: string = 'EntryAbility';
  static readonly FORM_ABILITY: string = 'TodoFormAbility';
  static readonly FORM_NAME: string = 'myday_card';
  /** 卡片一次最多渲染的条数（再多的靠"在应用中查看"） */
  static readonly CARD_ITEM_LIMIT: number = 12;
  static readonly WANT_URI_PREFIX: string = 'todo://task/';
}
