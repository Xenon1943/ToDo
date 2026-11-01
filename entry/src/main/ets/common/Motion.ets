/**
 * 动效基线：全工程的时长、曲线、过渡与阴影都从这里取，避免各处硬编码。
 *
 * 卡片（form 应用）里不能调用 animateTo / getUIContext / setTimeout，
 * 所以卡片只用这里的**常量**，动画靠 `.animation()` 隐式播放。
 */
export class Motion {
  /** 按压/离场这类"小动作" */
  static readonly FAST: number = 140;

  /** 常规过渡：增删行、切页 */
  static readonly NORMAL: number = 220;

  /** 拖拽让路、长按浮起 */
  static readonly SLOW: number = 300;

  /** 拖拽换位时其他行的让路时长（跟手优先，不能太长） */
  static readonly REORDER: number = 200;

  /** 长按选中后的行透明度 */
  static readonly PRESS_OPACITY: number = 0.88;

  /** 卡片上"正在离场"的行透明度（万一快照没回来，还能看见可点） */
  static readonly CARD_LEAVE_OPACITY: number = 0.15;

  static params(duration: number = Motion.NORMAL): AnimateParam {
    const p: AnimateParam = { duration: duration, curve: Curve.FastOutSlowIn };
    return p;
  }

  /** 线性动画：刷新箭头这类"跟手"的位移用它 */
  static linearParams(duration: number): AnimateParam {
    const p: AnimateParam = { duration: duration, curve: Curve.Linear };
    return p;
  }

  /**
   * 列表行的增删过渡。
   * 关键点：新增只淡入、删除才"淡出 + 左移"。
   * 早期两端都带位移，导致内容变化（行被重建）时看起来像"从左边飞进来"。
   */
  static rowTransition(): TransitionEffect {
    const appear = TransitionEffect.OPACITY.animation(Motion.params(Motion.NORMAL));
    const disappear = TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ x: -72, y: 0 }))
      .animation(Motion.params(Motion.NORMAL));
    return TransitionEffect.asymmetric(appear, disappear);
  }

  /** 分段切页：dir = -1 从左侧滑入，dir = 1 从右侧滑入 */
  static pageSlide(dir: number): TransitionEffect {
    const appear = TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ x: dir * 120, y: 0 }))
      .animation(Motion.params(Motion.NORMAL));
    // 旧页不做淡出：否则切换瞬间新旧两页同时可见，看起来像"两个 Tab 都亮着"
    const disappear = TransitionEffect.IDENTITY;
    return TransitionEffect.asymmetric(appear, disappear);
  }

  /** 拖拽时跟随手指的预览卡片阴影 */
  static dragPreviewShadow(): ShadowOptions {
    const s: ShadowOptions = { radius: 24, color: '#33000000', offsetY: 10 };
    return s;
  }
}
