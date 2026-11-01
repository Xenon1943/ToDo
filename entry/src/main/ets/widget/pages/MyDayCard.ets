import { CardItem } from '../../common/Models';
import { TimeUtil } from '../../common/TimeUtil';
import { Motion } from '../../common/Motion';

let storageMyDay: LocalStorage = new LocalStorage();

/** 卡片渲染视图（由快照 JSON 解析而来，卡片侧只依赖这些字段） */
class CardView {
  date: string = '';
  total: number = 0;
  done: number = 0;
  items: CardItem[] = [];
}

interface CardItemJson {
  id?: string;
  t?: string;
  due?: number;
  od?: boolean;
}

interface CardViewJson {
  date?: string;
  total?: number;
  done?: number;
  items?: CardItemJson[];
}

/** message 事件参数（postCardAction 的 params） */
class MsgParams {
  op: string = '';
  id: string = '';
  ts: number = 0;

  constructor(op: string, id: string, ts: number) {
    this.op = op;
    this.id = id;
    this.ts = ts;
  }
}

class MsgAction {
  action: string = 'message';
  params: MsgParams;

  constructor(params: MsgParams) {
    this.params = params;
  }
}

/** router 事件参数：action = quickAdd / openTask / openMyDay */
class RouterParams {
  action: string = 'openMyDay';
  taskId: string = '';

  constructor(action: string, taskId: string) {
    this.action = action;
    this.taskId = taskId;
  }
}

class RouterAction {
  action: string = 'router';
  bundleName: string = 'com.xenon.todo';
  moduleName: string = 'entry';
  abilityName: string = 'EntryAbility';
  params: RouterParams;

  constructor(params: RouterParams) {
    this.params = params;
  }
}

function parseView(raw: string): CardView {
  const view = new CardView();
  if (raw === undefined || raw === null || raw.length === 0) {
    return view;
  }
  try {
    const obj = JSON.parse(raw) as CardViewJson;
    if (obj === null || obj === undefined) {
      return view;
    }
    view.date = typeof obj.date === 'string' ? obj.date : '';
    view.total = typeof obj.total === 'number' ? obj.total : 0;
    view.done = typeof obj.done === 'number' ? obj.done : 0;
    const list = obj.items;
    if (list instanceof Array) {
      const arr = list as CardItemJson[];
      for (let i = 0; i < arr.length; i++) {
        const it = arr[i];
        if (it === null || it === undefined) {
          continue;
        }
        const id = typeof it.id === 'string' ? it.id : '';
        if (id.length === 0) {
          continue;
        }
        const title = typeof it.t === 'string' ? it.t : '';
        const due = typeof it.due === 'number' ? it.due : 0;
        const od = it.od === true;
        view.items.push(new CardItem(id, title, due, od));
      }
    }
  } catch (e) {
    return new CardView();
  }
  return view;
}

/**
 * 「我的一天」服务卡片。
 *
 * 能力边界（已确认）：
 * - 卡片内可用 List（纵向滑动），不可用 Scroll / TextInput / DatePicker
 * - 交互只能通过 postCardAction 发起：message 交给卡片提供方进程，router 拉起应用
 * - 数据只经 LocalStorageProp 下发，且一定是 string
 *
 * 交互：
 * - 勾选圆圈：message(toggle)，卡片本地先划掉，再以回推快照为准
 * - 点任务标题：router(openTask) → 应用的任务详情
 * - 点 ＋：router(quickAdd) → 应用的新建页，保存后自动返回桌面
 * - 点空白：router(openMyDay) → 应用的「我的一天」
 */
@Entry(storageMyDay)
@Component
struct MyDayCard {
  @LocalStorageProp('myday') @Watch('onRawChanged') raw: string = '';
  @State view: CardView = new CardView();
  /** 正在播放离场动画的任务 id */
  @State leavingId: string = '';

  aboutToAppear(): void {
    this.view = parseView(this.raw);
  }

  onRawChanged(): void {
    this.view = parseView(this.raw);
    // 新快照已生效：离场动画结束，条目该在的在、该没的没
    this.leavingId = '';
  }

  private toggle(id: string): void {
    // 卡片里不能用 animateTo / setTimeout，所以用"隐式动画 + 权威快照驱动删除"：
    // 1) 标记 leavingId → .animation() 让这一行淡出左移；
    // 2) message 交给卡片进程写库并回推新快照；
    // 3) 新快照到达（onRawChanged）时列表里已经没有它，动画标记顺带清掉。
    this.leavingId = id;
    postCardAction(this, new MsgAction(new MsgParams('toggle', id, Date.now())));
  }

  private quickAdd(): void {
    // 卡片里没有输入框，直接拉起应用的新建页；保存/取消后应用会自动返回桌面
    postCardAction(this, new RouterAction(new RouterParams('quickAdd', '')));
  }

  private openMyDay(): void {
    postCardAction(this, new RouterAction(new RouterParams('openMyDay', '')));
  }

  private openTask(id: string): void {
    postCardAction(this, new RouterAction(new RouterParams('openTask', id)));
  }

  @Builder
  taskRow(item: CardItem) {
    Row() {
      // 圆形勾选框：只负责完成，不跳转
      Row() {
        Text('')
      }
      .width(18)
      .height(18)
      .borderRadius(9)
      .borderWidth(1.5)
      .borderColor($r('app.color.accent'))
      .onClick(() => {
        this.toggle(item.id);
      })

      Column() {
        Text(item.t)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (item.due > 0) {
          Text(TimeUtil.formatDue(item.due))
            .fontSize(12)
            .fontColor(item.od ? $r('app.color.danger') : $r('app.color.text_secondary'))
            .margin({ top: 2 })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 8 })
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
    .alignItems(VerticalAlign.Center)
    .opacity(this.leavingId === item.id ? Motion.CARD_LEAVE_OPACITY : 1)
    .translate({ x: this.leavingId === item.id ? -56 : 0 })
    .animation(Motion.params(Motion.FAST))
    .onClick(() => {
      // 点任务本体 → 应用的任务详情（子组件手势优先，不会冒泡到卡片空白点击）
      this.openTask(item.id);
    })
  }

  build() {
    // 卡片空白处（留白 / 页脚 / 空列表）→ 打开应用「我的一天」
    Column() {
      // 头部
      Row() {
        Text('我的一天')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(` ${this.view.done}/${this.view.total}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 4 })
        Blank()
        Text('＋')
          .fontSize(22)
          .fontColor($r('app.color.accent'))
          .padding({ left: 8, right: 2 })
          .onClick(() => {
            this.quickAdd();
          })
      }
      .width('100%')
      .height(26)
      .alignItems(VerticalAlign.Center)

      if (this.view.items.length === 0) {
        Column() {
          Text(this.view.total > 0 && this.view.done >= this.view.total ? '今天的任务都完成了' : '今天还没有安排')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Text(this.view.total > 0 && this.view.done >= this.view.total ? '点右上角 ＋ 继续添加' : '点右上角 ＋ 快速添加')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 4 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List({ space: 0 }) {
          ForEach(this.view.items, (item: CardItem) => {
            ListItem() {
              this.taskRow(item)
            }
          }, (item: CardItem) => item.id)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }

      Row() {
        Text('查看全部任务')
          .fontSize(12)
          .fontColor($r('app.color.accent'))
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor($r('app.color.card_bg'))
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openMyDay();
    })
  }
}
