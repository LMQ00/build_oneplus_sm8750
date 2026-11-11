#!/bin/bash
# 让风驰（hmbird）调度在 RMX5010 上真正生效，并修掉它绕过 CPU 亲和性的缺陷。
#
# 用法：apply_hmbird.sh <内核源码目录>
#
# 背景（全部有源码依据）：
#   1. `include/linux/sched/hmbird_version.h` 的 get_hmbird_version_type() 通过
#      /proc/device-tree/soc/oplus,hmbird/version_type 读版本。RMX5010 的 DT 是
#      volkswagen-24885 系列，**没有** 这个节点（只有 volkswagen-24816 的 overlay 里有），
#      于是落到 HMBIRD_UNKNOW_VERSION。下游两处 gate：
#        kernel/sched/hmbird/hmbird_sched_proc.c:326  hmbird_proc_init()
#        kernel/sched/hmbird/hmbird_shadow_tick.c:152 hmbird_shadow_tick_init()
#      都 `return 0`，导致 /proc/hmbird_sched 不出现、shadow tick 不启动，
#      风驰实际上等于不存在。
#   2. `kernel/sched/hmbird/hmbird.c` 的 task_can_run_on_rq() 只判断
#      task_fits_cpu_hmbird()（一个恒返回 1 的桩）、misfit 和 rq online，
#      **完全不看 p->cpus_ptr**；select_task_rq_hmbird() 也没有把返回值收敛到
#      允许的 CPU 集合。而 kernel/sched/core.c 里厂商又给 hmbird class 开了后门：
#        if (unlikely(!is_cpu_allowed(p, cpu)) && (p->sched_class != &hmbird_sched_class))
#          cpu = select_fallback_rq(task_cpu(p), p);
#      三者叠加 → 风驰任务可能被投递到它的亲和性掩码之外的 CPU。
#      设备上实测到的 `WALT-BUG selecting unaffined cpu=` 就是这条链路的产物。
#
# 本脚本只做两件事：
#   A. DT 节点缺失时按 HMBIRD_OGKI_VERSION 处理（节点存在时行为不变）。
#   B. 让 hmbird 的选核/入队遵守 p->cpus_ptr。
# 不改 core.c 的厂商后门，避免动到范围之外的调度路径。
set -euo pipefail

COMMON="${1:?用法: apply_hmbird.sh <内核源码目录>}"

[ -f "$COMMON/kernel/sched/hmbird/hmbird.c" ] || {
	echo "::error::${COMMON} 里没有 kernel/sched/hmbird/，该源码分支未内置风驰"
	exit 1
}
cd "$COMMON"

fail() {
	echo "::error::$*"
	exit 1
}

echo "== [1/3] hmbird_version.h：DT 节点缺失时回落到 HMBIRD_OGKI_VERSION =="
VER_H=include/linux/sched/hmbird_version.h
if grep -q 'LZ4KDS_HMBIRD_FORCE_OGKI' "$VER_H"; then
	echo "  - 已打过，跳过"
else
	python3 - "$VER_H" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = """	hmbird_version_type = HMBIRD_UNKNOW_VERSION;
	pr_debug("hmbird version use default HMBIRD_UNKNOW_VERSION");
	return hmbird_version_type;
}"""
new = """	/*
	 * LZ4KDS_HMBIRD_FORCE_OGKI:
	 * RMX5010 的 DT（volkswagen-24885 系列）没有 /soc/oplus,hmbird 节点，
	 * 上游实现会落成 HMBIRD_UNKNOW_VERSION，使 hmbird_proc_init() 与
	 * hmbird_shadow_tick_init() 全部 early-return —— 风驰等于没编进内核。
	 * 这里只在“节点不存在”这一条路径上按 OGKI 处理；节点存在时行为不变。
	 */
	hmbird_version_type = HMBIRD_OGKI_VERSION;
	pr_info("hmbird: no DT version node, force HMBIRD_OGKI_VERSION\\n");
	return hmbird_version_type;
}"""
if old not in s:
    sys.exit("hmbird_version.h 中找不到预期片段")
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
	echo "  + ${VER_H} 已修改"
fi

echo "== [2/3] hmbird.c：task_can_run_on_rq() 遵守 p->cpus_ptr =="
HM=kernel/sched/hmbird/hmbird.c
if grep -q 'LZ4KDS_HMBIRD_AFFINITY' "$HM"; then
	echo "  - 已打过，跳过"
else
	python3 - "$HM" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = """static bool task_can_run_on_rq(struct task_struct *p, struct rq *rq, struct hmbird_dispatch_q *dsq)
{
	if (!task_fits_cpu_hmbird(p, cpu_of(rq)))
		return false;
"""
new = """static bool task_can_run_on_rq(struct task_struct *p, struct rq *rq, struct hmbird_dispatch_q *dsq)
{
	/*
	 * LZ4KDS_HMBIRD_AFFINITY:
	 * 上游这里不看 p->cpus_ptr，而 task_fits_cpu_hmbird() 是个恒返回 1 的桩，
	 * 于是可以被投递到任务亲和性掩码之外的 CPU（设备上表现为
	 * `WALT-BUG selecting unaffined cpu=`）。补上亲和性判断。
	 */
	if (!cpumask_test_cpu(cpu_of(rq), p->cpus_ptr))
		return false;

	if (!task_fits_cpu_hmbird(p, cpu_of(rq)))
		return false;
"""
if old not in s:
    sys.exit("hmbird.c 中找不到 task_can_run_on_rq 的预期片段")
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
	echo "  + ${HM} task_can_run_on_rq 已加亲和性判断"
fi

echo "== [3/3] hmbird.c：select_task_rq_hmbird() 把结果收敛到允许的 CPU =="
if grep -q 'LZ4KDS_HMBIRD_SELECT_GUARD' "$HM"; then
	echo "  - 已打过，跳过"
else
	python3 - "$HM" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = """static int select_task_rq_hmbird(struct task_struct *p, int prev_cpu, int wake_flags)
{
	return hmbird_select_cpu_dfl(p, prev_cpu, wake_flags);
}"""
new = """static int select_task_rq_hmbird(struct task_struct *p, int prev_cpu, int wake_flags)
{
	int cpu = hmbird_select_cpu_dfl(p, prev_cpu, wake_flags);

	/*
	 * LZ4KDS_HMBIRD_SELECT_GUARD:
	 * hmbird_select_cpu_dfl() 的若干分支会返回不在 p->cpus_ptr 里的 CPU
	 * （例如 prev_cpu 或 pick_idle 的结果）。core.c 对 hmbird class 又跳过了
	 * select_fallback_rq()，所以这里必须自己兜住。
	 */
	if (unlikely(!cpumask_test_cpu(cpu, p->cpus_ptr))) {
		int fallback = cpumask_any_and(p->cpus_ptr, cpu_active_mask);

		if (fallback < nr_cpu_ids)
			cpu = fallback;
	}

	return cpu;
}"""
if old not in s:
    sys.exit("hmbird.c 中找不到 select_task_rq_hmbird 的预期片段")
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
	echo "  + ${HM} select_task_rq_hmbird 已收敛"
fi

echo "== 自检 =="
grep -q 'LZ4KDS_HMBIRD_FORCE_OGKI' "$VER_H" || fail "hmbird_version.h 修改未生效"
grep -q 'LZ4KDS_HMBIRD_AFFINITY' "$HM"      || fail "task_can_run_on_rq 修改未生效"
grep -q 'LZ4KDS_HMBIRD_SELECT_GUARD' "$HM"  || fail "select_task_rq_hmbird 修改未生效"
echo "风驰补丁已应用（DT 门 + 亲和性）"
