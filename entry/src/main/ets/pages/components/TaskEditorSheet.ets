import { TaskDraft } from '../../common/Models';
import { TimeUtil } from '../../common/TimeUtil';
import { Motion } from '../../common/Motion';

/**
 * 新建/编辑任务面板（半模态内容）。
 *
 * 几个踩过的坑，改的时候别再踩回去：
 * 1. 表单主体用 `List` 而不是 `Scroll`——Scroll 的子组件在内容不足一屏时会被垂直居中。
 * 2. 日期/时间选择器**纵向排列、各占满宽**：并排时 DatePicker 会被挤成 0 宽，只剩时间能滚。
 * 3. 「今天/明天」这类按钮**直接写在 build 里**，不要包进 @Builder 再按值传参——
 *    ArkUI 不会因为 @Builder 参数没变就重新执行，导致按钮颜色不刷新。
 * 4. 面板内容**始终挂载**，不要在 showEditor=false 时把内容抽掉：
 *    抽掉后 bindSheet 的收起动画会因为内容消失而卡成一片白。
 */
@Component
export struct TaskEditorSheet {
  /** 初始草稿：用 @Prop 保证父组件换 draft 时能同步过来（普通属性只在创建时赋值一次） */
  @Prop @Watch('resetFromDraft') initDraft: TaskDraft = TaskDraft.empty();
  /** 每次打开自增，用于把内部状态重置成新的 draft（防止面板实例被复用） */
  @Prop @Watch('resetFromDraft') draftVersion: number = 0;
  onSave: (draft: TaskDraft) => void = (draft: TaskDraft): void => {
  };
  onCancel: () => void = (): void => {
  };

  @State title: string = '';
  @State note: string = '';
  @State dueEnabled: boolean = false;
  @State remindEnabled: boolean = false;
  @State dueDay: number = 0;
  @State remindDay: number = 0;
  @State dueHour: number = 9;
  @State dueMinute: number = 0;
  @State remindHour: number = 9;
  @State remindMinute: number = 0;
  @State moreDue: boolean = false;
  @State moreRemind: boolean = false;

  aboutToAppear(): void {
    this.resetFromDraft();
  }

  resetFromDraft(): void {
    const d = this.initDraft;
    this.title = d.title;
    this.note = d.note;
    this.dueEnabled = d.dueAt > 0;
    this.remindEnabled = d.remindAt > 0;
    this.moreDue = false;
    this.moreRemind = false;
    const now = Date.now();
    const dueBase = d.dueAt > 0 ? d.dueAt : TimeUtil.startOfDay(now) + 9 * 60 * 60 * 1000;
    const remindBase = d.remindAt > 0 ? d.remindAt : TimeUtil.startOfDay(now) + 9 * 60 * 60 * 1000;
    this.dueDay = TimeUtil.startOfDay(dueBase);
    this.remindDay = TimeUtil.startOfDay(remindBase);
    const dd = new Date(dueBase);
    this.dueHour = dd.getHours();
    this.dueMinute = dd.getMinutes();
    const rd = new Date(remindBase);
    this.remindHour = rd.getHours();
    this.remindMinute = rd.getMinutes();
  }

  private pickDay(offset: number, forDue: boolean): void {
    const day = TimeUtil.addDays(Date.now(), offset);
    if (forDue) {
      this.dueDay = day;
      this.dueEnabled = true;
      this.moreDue = false;
    } else {
      this.remindDay = day;
      this.remindEnabled = true;
      this.moreRemind = false;
    }
  }

  private save(): void {
    const d = this.initDraft.clone();
    d.title = this.title.trim().length > 0 ? this.title.trim() : '未命名任务';
    d.note = this.note;
    d.dueAt = this.dueEnabled ? TimeUtil.atTime(this.dueDay, this.dueHour, this.dueMinute) : 0;
    d.remindAt = this.remindEnabled ? TimeUtil.atTime(this.remindDay, this.remindHour, this.remindMinute) : 0;
    this.onSave(d);
  }

  @Builder
  dateTimePanel(forDue: boolean, dayMs: number, hour: number, minute: number) {
    Column() {
      Row() {
        Text('日期').fontSize(14).fontColor($r('app.color.text_secondary'))
        Blank()
        Text(TimeUtil.dayKey(dayMs)).fontSize(15).fontColor($r('app.color.accent'))
      }
      .width('100%')
      .height(28)

      DatePicker({ selected: new Date(dayMs) })
        .width('100%')
        .height(118)
        .textStyle({ font: { size: 13 } })
        .selectedTextStyle({ font: { size: 17, weight: FontWeight.Medium } })
        .disappearTextStyle({ font: { size: 11 } })
        .onDateChange((value: Date) => {
          if (forDue) {
            this.dueDay = TimeUtil.startOfDay(value.getTime());
          } else {
            this.remindDay = TimeUtil.startOfDay(value.getTime());
          }
        })

      Row() {
        Text('时间').fontSize(14).fontColor($r('app.color.text_secondary'))
        Blank()
        Text(TimeUtil.formatDateTime(TimeUtil.atTime(dayMs, hour, minute)).substring(11))
          .fontSize(15)
          .fontColor($r('app.color.accent'))
      }
      .width('100%')
      .height(28)
      .margin({ top: 4 })

      TimePicker({ selected: new Date(TimeUtil.atTime(dayMs, hour, minute)) })
        .width('100%')
        .height(118)
        .textStyle({ font: { size: 13 } })
        .selectedTextStyle({ font: { size: 17, weight: FontWeight.Medium } })
        .disappearTextStyle({ font: { size: 11 } })
        .onChange((v: TimePickerResult) => {
          if (forDue) {
            this.dueHour = v.hour !== undefined ? v.hour : this.dueHour;
            this.dueMinute = v.minute !== undefined ? v.minute : this.dueMinute;
          } else {
            this.remindHour = v.hour !== undefined ? v.hour : this.remindHour;
            this.remindMinute = v.minute !== undefined ? v.minute : this.remindMinute;
          }
        })
    }
    .width('100%')
    .margin({ top: 4 })
  }

  build() {
    Column() {
      // 头部：固定不滚动
      Row() {
        Text(this.initDraft.isNew ? '新建任务' : '任务详情')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('取消')
          .fontSize(17)
          .fontColor($r('app.color.text_secondary'))
          .padding(6)
          .onClick(() => {
            this.onCancel();
          })
        Text('保存')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .padding(6)
          .margin({ left: 10 })
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .padding({ top: 14, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      List({ space: 0 }) {
        ListItem() {
          Column() {
            TextInput({ text: this.title, placeholder: '任务名称' })
              .maxLength(200)
              .fontSize(18)
              .height(54)
              .backgroundColor($r('app.color.card_bg_secondary'))
              .borderRadius(12)
              .onChange((v: string) => {
                this.title = v;
              })

            // ---------- 截止日期 ----------
            Row() {
              Text('截止日期').fontSize(17).fontColor($r('app.color.text_primary'))
              Blank()
              Text(this.dueEnabled
                ? TimeUtil.formatDateTime(TimeUtil.atTime(this.dueDay, this.dueHour, this.dueMinute))
                : '无')
                .fontSize(15)
                .fontColor($r('app.color.text_secondary'))
                .margin({ right: 6 })
              Toggle({ type: ToggleType.Switch, isOn: this.dueEnabled })
                .onChange((value: boolean) => {
                  this.dueEnabled = value;
                  if (value) {
                    this.moreDue = true;
                  }
                })
            }
            .width('100%')
            .height(56)

            if (this.dueEnabled) {
              // 三个按钮直接写在 build 里：颜色变化才能即时生效并带过渡动画
              Row({ space: 10 }) {
                Text('今天')
                  .fontSize(15)
                  .fontColor(TimeUtil.isSameDay(this.dueDay, Date.now())
                    ? Color.White
                    : $r('app.color.text_primary'))
                  .backgroundColor(TimeUtil.isSameDay(this.dueDay, Date.now())
                    ? $r('app.color.accent')
                    : $r('app.color.card_bg_secondary'))
                  .borderRadius(16)
                  .padding({ left: 18, right: 18, top: 8, bottom: 8 })
                  .animation(Motion.params(Motion.FAST))
                  .onClick(() => {
                    this.pickDay(0, true);
                  })
                Text('明天')
                  .fontSize(15)
                  .fontColor(TimeUtil.isSameDay(this.dueDay, TimeUtil.addDays(Date.now(), 1))
                    ? Color.White
                    : $r('app.color.text_primary'))
                  .backgroundColor(TimeUtil.isSameDay(this.dueDay, TimeUtil.addDays(Date.now(), 1))
                    ? $r('app.color.accent')
                    : $r('app.color.card_bg_secondary'))
                  .borderRadius(16)
                  .padding({ left: 18, right: 18, top: 8, bottom: 8 })
                  .animation(Motion.params(Motion.FAST))
                  .onClick(() => {
                    this.pickDay(1, true);
                  })
                Text('自定义')
                  .fontSize(15)
                  .fontColor(this.moreDue ? Color.White : $r('app.color.text_primary'))
                  .backgroundColor(this.moreDue
                    ? $r('app.color.accent')
                    : $r('app.color.card_bg_secondary'))
                  .borderRadius(16)
                  .padding({ left: 18, right: 18, top: 8, bottom: 8 })
                  .animation(Motion.params(Motion.FAST))
                  .onClick(() => {
                    this.moreDue = !this.moreDue;
                  })
              }
              .width('100%')
              .margin({ top: 2, bottom: 4 })

              if (this.moreDue) {
                this.dateTimePanel(true, this.dueDay, this.dueHour, this.dueMinute)
              }
            }

            Divider().color($r('app.color.divider')).margin({ top: 10, bottom: 10 })

            // ---------- 提醒日期 ----------
            Row() {
              Text('提醒日期').fontSize(17).fontColor($r('app.color.text_primary'))
              Blank()
              Text(this.remindEnabled
                ? TimeUtil.formatDateTime(TimeUtil.atTime(this.remindDay, this.remindHour, this.remindMinute))
                : '无')
                .fontSize(15)
                .fontColor($r('app.color.text_secondary'))
                .margin({ right: 6 })
              Toggle({ type: ToggleType.Switch, isOn: this.remindEnabled })
                .onChange((value: boolean) => {
                  this.remindEnabled = value;
                  if (value) {
                    this.moreRemind = true;
                  }
                })
            }
            .width('100%')
            .height(56)

            if (this.remindEnabled) {
              Row({ space: 10 }) {
                Text('今天')
                  .fontSize(15)
                  .fontColor(TimeUtil.isSameDay(this.remindDay, Date.now())
                    ? Color.White
                    : $r('app.color.text_primary'))
                  .backgroundColor(TimeUtil.isSameDay(this.remindDay, Date.now())
                    ? $r('app.color.accent')
                    : $r('app.color.card_bg_secondary'))
                  .borderRadius(16)
                  .padding({ left: 18, right: 18, top: 8, bottom: 8 })
                  .animation(Motion.params(Motion.FAST))
                  .onClick(() => {
                    this.pickDay(0, false);
                  })
                Text('明天')
                  .fontSize(15)
                  .fontColor(TimeUtil.isSameDay(this.remindDay, TimeUtil.addDays(Date.now(), 1))
                    ? Color.White
                    : $r('app.color.text_primary'))
                  .backgroundColor(TimeUtil.isSameDay(this.remindDay, TimeUtil.addDays(Date.now(), 1))
                    ? $r('app.color.accent')
                    : $r('app.color.card_bg_secondary'))
                  .borderRadius(16)
                  .padding({ left: 18, right: 18, top: 8, bottom: 8 })
                  .animation(Motion.params(Motion.FAST))
                  .onClick(() => {
                    this.pickDay(1, false);
                  })
                Text('自定义')
                  .fontSize(15)
                  .fontColor(this.moreRemind ? Color.White : $r('app.color.text_primary'))
                  .backgroundColor(this.moreRemind
                    ? $r('app.color.accent')
                    : $r('app.color.card_bg_secondary'))
                  .borderRadius(16)
                  .padding({ left: 18, right: 18, top: 8, bottom: 8 })
                  .animation(Motion.params(Motion.FAST))
                  .onClick(() => {
                    this.moreRemind = !this.moreRemind;
                  })
              }
              .width('100%')
              .margin({ top: 2, bottom: 4 })

              if (this.moreRemind) {
                this.dateTimePanel(false, this.remindDay, this.remindHour, this.remindMinute)
              }
            }

            Divider().color($r('app.color.divider')).margin({ top: 10, bottom: 10 })

            TextArea({ text: this.note, placeholder: '具体描述（可选）' })
              .height(104)
              .fontSize(16)
              .backgroundColor($r('app.color.card_bg_secondary'))
              .borderRadius(12)
              .onChange((v: string) => {
                this.note = v;
              })

            Text('有截止日期时：截止当天早上 + 截止前 10 分钟各提醒一次')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 12, bottom: 20 })
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18 })
    .alignItems(HorizontalAlign.Start)
  }
}
