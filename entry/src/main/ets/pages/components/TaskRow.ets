import { TimeUtil } from '../../common/TimeUtil';
import { Motion } from '../../common/Motion';

/** 列表行组件：只吃基础类型，避免 @Prop 传对象带来的深拷贝与刷新问题 */
@Component
export struct TaskRow {
  @Prop taskId: string = '';
  @Prop title: string = '';
  @Prop dueAt: number = 0;
  @Prop done: boolean = false;
  @Prop overdue: boolean = false;
  @Prop inMyDay: boolean = false;
  /** 从以前顺延过来的（昨天没做完） */
  @Prop carried: boolean = false;
  /** 按下态：手指一落下就有明显"下凹"，不用等到开始拖动 */
  @State pressed: boolean = false;
  onToggle: (id: string) => void = () => {
  };
  onOpen: (id: string) => void = () => {
  };

  build() {
    Row() {
      Row() {
        if (this.done) {
          Text('✓')
            .fontSize(12)
            .fontColor(Color.White)
        }
      }
      .width(20)
      .height(20)
      .borderRadius(10)
      .backgroundColor(this.done ? $r('app.color.accent') : Color.Transparent)
      .borderWidth(1.5)
      .borderColor(this.done ? $r('app.color.accent') : $r('app.color.text_secondary'))
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.onToggle(this.taskId);
      })

      Column() {
        Text(this.title)
          .fontSize(17)
          .fontColor(this.done ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
          .decoration({ type: this.done ? TextDecorationType.LineThrough : TextDecorationType.None })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.inMyDay || this.carried || this.dueAt > 0) {
          Row({ space: 6 }) {
            if (this.inMyDay) {
              Text('我的一天')
                .fontSize(11)
                .fontColor($r('app.color.accent'))
                .backgroundColor($r('app.color.card_bg_secondary'))
                .borderRadius(4)
                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            }
            if (this.carried) {
              Text('顺延')
                .fontSize(11)
                .fontColor($r('app.color.danger'))
                .backgroundColor($r('app.color.card_bg_secondary'))
                .borderRadius(4)
                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            }
            if (this.dueAt > 0) {
              Text(TimeUtil.formatDue(this.dueAt))
                .fontSize(13)
                .fontColor(this.overdue && !this.done ? $r('app.color.danger') : $r('app.color.text_secondary'))
            }
          }
          .margin({ top: 3 })
          .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
    }
    .width('100%')
    .padding({ top: 13, bottom: 13, left: 16, right: 16 })
    .backgroundColor(this.pressed ? $r('app.color.card_bg_secondary') : $r('app.color.card_bg'))
    .scale({ x: this.pressed ? 0.975 : 1, y: this.pressed ? 0.975 : 1 })
    .animation(Motion.params(Motion.FAST))
    .alignItems(VerticalAlign.Top)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => {
      this.onOpen(this.taskId);
    })
  }
}
