import { describe, it, expect } from '@ohos/hypium';
import { TimeUtil } from '../main/ets/common/TimeUtil';
import { TodoTask, MyDaySnapshot, CardAction, CardOp } from '../main/ets/common/Models';
import { MyDayService } from '../main/ets/service/MyDayService';

/** 造一个"今天 18:00 到期"的任务 */
function taskDueToday(title: string, done: boolean): TodoTask {
  const t = new TodoTask();
  t.id = `id-${title}`;
  t.title = title;
  t.done = done;
  t.createdAt = Date.now();
  t.updatedAt = Date.now();
  t.dueAt = TimeUtil.atTime(Date.now(), 18, 0);
  return t;
}

function plainTask(title: string): TodoTask {
  const t = new TodoTask();
  t.id = `id-${title}`;
  t.title = title;
  t.createdAt = Date.now();
  t.updatedAt = Date.now();
  return t;
}

export default function coreLogicTest() {
  describe('TimeUtil', () => {
    it('dayKey_formats_local_date', 0, () => {
      const ms = new Date(2026, 9, 30, 20, 5).getTime();
      expect(TimeUtil.dayKey(ms)).assertEqual('2026-10-30');
    });

    it('startOfDay_is_zero_oclock', 0, () => {
      const ms = new Date(2026, 9, 30, 20, 5).getTime();
      const start = new Date(TimeUtil.startOfDay(ms));
      expect(start.getHours()).assertEqual(0);
      expect(start.getMinutes()).assertEqual(0);
    });

    it('isSameDay_across_midnight', 0, () => {
      const a = new Date(2026, 9, 30, 23, 59).getTime();
      const b = new Date(2026, 9, 31, 0, 1).getTime();
      expect(TimeUtil.isSameDay(a, b)).assertFalse();
    });

    it('atTime_builds_exact_moment', 0, () => {
      const day = new Date(2026, 9, 30, 13, 0).getTime();
      const at = new Date(TimeUtil.atTime(day, 8, 30));
      expect(at.getDate()).assertEqual(30);
      expect(at.getHours()).assertEqual(8);
      expect(at.getMinutes()).assertEqual(30);
    });

    it('isOverdue_only_for_past_due', 0, () => {
      const now = Date.now();
      expect(TimeUtil.isOverdue(now - 60000, now)).assertTrue();
      expect(TimeUtil.isOverdue(now + 60000, now)).assertFalse();
      expect(TimeUtil.isOverdue(0, now)).assertFalse();
    });

    it('formatDue_uses_relative_day', 0, () => {
      expect(TimeUtil.formatDue(TimeUtil.atTime(Date.now(), 18, 0))).assertContain('今天');
      expect(TimeUtil.formatDue(TimeUtil.atTime(TimeUtil.addDays(Date.now(), 1), 18, 0))).assertContain('明天');
      expect(TimeUtil.formatDue(0)).assertEqual('');
    });
  });

  describe('MyDayService', () => {
    it('manual_myday_task_is_included', 0, () => {
      const t = plainTask('手动加入');
      t.myDayDate = TimeUtil.todayKey();
      const list = MyDayService.myDayTasks([t], TimeUtil.todayKey(), Date.now());
      expect(list.length).assertEqual(1);
    });

    it('task_without_due_and_without_manual_flag_is_excluded', 0, () => {
      const list = MyDayService.myDayTasks([plainTask('普通任务')], TimeUtil.todayKey(), Date.now());
      expect(list.length).assertEqual(0);
    });

    it('due_today_is_auto_included', 0, () => {
      const list = MyDayService.myDayTasks([taskDueToday('今天到期', false)], TimeUtil.todayKey(), Date.now());
      expect(list.length).assertEqual(1);
    });

    it('done_task_is_excluded', 0, () => {
      const list = MyDayService.myDayTasks([taskDueToday('已完成', true)], TimeUtil.todayKey(), Date.now());
      expect(list.length).assertEqual(0);
    });

    it('hidden_on_today_is_excluded', 0, () => {
      const t = taskDueToday('被移出', false);
      t.myDayHiddenOn = TimeUtil.todayKey();
      const list = MyDayService.myDayTasks([t], TimeUtil.todayKey(), Date.now());
      expect(list.length).assertEqual(0);
    });

    it('hidden_yesterday_is_included_again_today', 0, () => {
      const t = taskDueToday('昨天移出过', false);
      t.myDayHiddenOn = TimeUtil.dayKey(TimeUtil.addDays(Date.now(), -1));
      const list = MyDayService.myDayTasks([t], TimeUtil.todayKey(), Date.now());
      expect(list.length).assertEqual(1);
    });

    it('tomorrow_due_is_not_in_myday', 0, () => {
      const t = plainTask('明天到期');
      t.dueAt = TimeUtil.atTime(TimeUtil.addDays(Date.now(), 1), 9, 0);
      const list = MyDayService.myDayTasks([t], TimeUtil.todayKey(), Date.now());
      expect(list.length).assertEqual(0);
    });

    it('snapshot_respects_limit_and_counts', 0, () => {
      const tasks: TodoTask[] = [];
      for (let i = 0; i < 20; i++) {
        tasks.push(taskDueToday(`任务${i}`, false));
      }
      const snap: MyDaySnapshot = MyDayService.buildSnapshot(tasks, TimeUtil.todayKey(), Date.now(), 12);
      expect(snap.total).assertEqual(20);
      expect(snap.items.length).assertEqual(12);
      expect(snap.date).assertEqual(TimeUtil.todayKey());
    });

    // 回归：做完最后一个任务时显示成 "1/0"
    it('stats_total_includes_completed', 0, () => {
      const t = taskDueToday('唯一任务', true);
      const stats = MyDayService.myDayStats([t], TimeUtil.todayKey(), Date.now());
      expect(stats.total).assertEqual(1);
      expect(stats.done).assertEqual(1);
    });

    it('completed_task_leaves_list_but_stays_in_total', 0, () => {
      const tasks = [taskDueToday('做完了', true), taskDueToday('没做完', false)];
      const today = TimeUtil.todayKey();
      const now = Date.now();
      const list = MyDayService.myDayTasks(tasks, today, now);
      const stats = MyDayService.myDayStats(tasks, today, now);
      expect(list.length).assertEqual(1);
      expect(list[0].title).assertEqual('没做完');
      expect(stats.total).assertEqual(2);
      expect(stats.done).assertEqual(1);
    });

    // 回归：今天完成、但不属于"我的一天"的任务不应计入
    it('task_outside_myday_is_not_counted_even_if_done_today', 0, () => {
      const t = plainTask('别处的任务');
      t.done = true;
      t.doneAt = Date.now();
      const stats = MyDayService.myDayStats([t], TimeUtil.todayKey(), Date.now());
      expect(stats.total).assertEqual(0);
      expect(stats.done).assertEqual(0);
    });

    it('manual_myday_completed_still_counts', 0, () => {
      const t = plainTask('手动加入后完成');
      t.myDayDate = TimeUtil.todayKey();
      t.done = true;
      t.doneAt = Date.now();
      const stats = MyDayService.myDayStats([t], TimeUtil.todayKey(), Date.now());
      expect(stats.total).assertEqual(1);
      expect(stats.done).assertEqual(1);
    });

    // 手动排序：order 优先于截止时间
    it('order_wins_over_due_date', 0, () => {
      const a = taskDueToday('A', false);
      a.order = 2000;
      a.dueAt = TimeUtil.atTime(Date.now(), 9, 0);
      const b = taskDueToday('B', false);
      b.order = 1000;
      b.dueAt = TimeUtil.atTime(Date.now(), 18, 0);
      const list = MyDayService.myDayTasks([a, b], TimeUtil.todayKey(), Date.now());
      expect(list[0].title).assertEqual('B');
      expect(list[1].title).assertEqual('A');
    });

    it('task_without_order_falls_back_to_createdAt', 0, () => {
      const older = plainTask('较早');
      older.myDayDate = TimeUtil.todayKey();
      older.createdAt = 1000;
      older.updatedAt = 1000;
      const newer = plainTask('较晚');
      newer.myDayDate = TimeUtil.todayKey();
      newer.createdAt = 2000;
      newer.updatedAt = 2000;
      const list = MyDayService.myDayTasks([newer, older], TimeUtil.todayKey(), Date.now());
      expect(list[0].title).assertEqual('较早');
    });

    it('moveItem_moves_down', 0, () => {
      const a = plainTask('A');
      const b = plainTask('B');
      const c = plainTask('C');
      const moved = MyDayService.moveItem([a, b, c], 0, 2);
      expect(moved[0].title).assertEqual('B');
      expect(moved[1].title).assertEqual('C');
      expect(moved[2].title).assertEqual('A');
    });

    it('moveItem_moves_up_and_ignores_bad_index', 0, () => {
      const a = plainTask('A');
      const b = plainTask('B');
      const c = plainTask('C');
      const up = MyDayService.moveItem([a, b, c], 2, 0);
      expect(up[0].title).assertEqual('C');
      expect(up[1].title).assertEqual('A');
      const bad = MyDayService.moveItem([a, b, c], 5, 0);
      expect(bad[0].title).assertEqual('A');
      expect(bad.length).assertEqual(3);
    });

    // ===== 未完成顺延 =====

    it('unfinished_manual_myday_carries_to_next_day', 0, () => {
      const t = plainTask('昨天没做完');
      t.myDayDate = TimeUtil.dayKey(TimeUtil.addDays(Date.now(), -1));
      const today = TimeUtil.todayKey();
      const now = Date.now();
      const list = MyDayService.myDayTasks([t], today, now);
      expect(list.length).assertEqual(1);
      expect(MyDayService.isCarriedOver(t, today, now)).assertTrue();
    });

    it('finished_yesterday_does_not_carry', 0, () => {
      const t = plainTask('昨天做完了');
      t.myDayDate = TimeUtil.dayKey(TimeUtil.addDays(Date.now(), -1));
      t.done = true;
      t.doneAt = TimeUtil.addDays(Date.now(), -1) + 3600000;
      const list = MyDayService.myDayTasks([t], TimeUtil.todayKey(), Date.now());
      expect(list.length).assertEqual(0);
      const stats = MyDayService.myDayStats([t], TimeUtil.todayKey(), Date.now());
      expect(stats.total).assertEqual(0);
    });

    it('finishing_carried_task_today_counts_in_total_not_in_list', 0, () => {
      const t = plainTask('今天做完了顺延的');
      t.myDayDate = TimeUtil.dayKey(TimeUtil.addDays(Date.now(), -1));
      t.done = true;
      t.doneAt = Date.now();
      const today = TimeUtil.todayKey();
      const now = Date.now();
      expect(MyDayService.myDayTasks([t], today, now).length).assertEqual(0);
      const stats = MyDayService.myDayStats([t], today, now);
      expect(stats.total).assertEqual(1);
      expect(stats.done).assertEqual(1);
    });

    it('overdue_unfinished_appears_in_myday', 0, () => {
      const t = plainTask('逾期未完成');
      t.dueAt = TimeUtil.atTime(TimeUtil.addDays(Date.now(), -2), 18, 0);
      const today = TimeUtil.todayKey();
      const now = Date.now();
      expect(MyDayService.myDayTasks([t], today, now).length).assertEqual(1);
      expect(MyDayService.isCarriedOver(t, today, now)).assertTrue();
    });

    it('overdue_finished_earlier_disappears', 0, () => {
      const t = plainTask('逾期但早做完了');
      t.dueAt = TimeUtil.atTime(TimeUtil.addDays(Date.now(), -2), 18, 0);
      t.done = true;
      t.doneAt = TimeUtil.addDays(Date.now(), -2);
      expect(MyDayService.myDayTasks([t], TimeUtil.todayKey(), Date.now()).length).assertEqual(0);
    });

    it('explicit_remove_today_wins_over_carry', 0, () => {
      const t = plainTask('今天移出过');
      t.myDayDate = TimeUtil.dayKey(TimeUtil.addDays(Date.now(), -1));
      t.myDayHiddenOn = TimeUtil.todayKey();
      expect(MyDayService.myDayTasks([t], TimeUtil.todayKey(), Date.now()).length).assertEqual(0);
    });
  });

  describe('TodoTask.serialization', () => {
    it('round_trip_keeps_fields', 0, () => {
      const t = taskDueToday('序列化', false);
      t.note = '备注内容';
      t.reminderIds = [11, 22];
      t.myDayDate = '2026-10-30';
      const back = TodoTask.fromJson(t.toJson());
      expect(back !== null).assertTrue();
      if (back !== null) {
        expect(back.id).assertEqual(t.id);
        expect(back.title).assertEqual('序列化');
        expect(back.dueAt).assertEqual(t.dueAt);
        expect(back.note).assertEqual('备注内容');
        expect(back.reminderIds.length).assertEqual(2);
        expect(back.myDayDate).assertEqual('2026-10-30');
      }
    });

    it('broken_json_returns_null', 0, () => {
      expect(TodoTask.fromJson('{not json') === null).assertTrue();
      expect(TodoTask.fromJson('') === null).assertTrue();
    });

    it('missing_id_returns_null', 0, () => {
      expect(TodoTask.fromJson('{"title":"没有id"}') === null).assertTrue();
    });
  });

  describe('CardAction', () => {
    it('parse_toggle_message', 0, () => {
      const a = CardAction.parse('{"op":"toggle","id":"abc","ts":123}');
      expect(a !== null).assertTrue();
      if (a !== null) {
        expect(a.op).assertEqual(CardOp.TOGGLE);
        expect(a.id).assertEqual('abc');
        expect(a.ts).assertEqual(123);
      }
    });

    it('parse_invalid_returns_null', 0, () => {
      expect(CardAction.parse('') === null).assertTrue();
      expect(CardAction.parse('{"id":"abc"}') === null).assertTrue();
    });
  });
}
