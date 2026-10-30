#!/bin/bash
# ===========================================================================
# run_sandy_test.sh (v2) -- COAWST Sandy 耦合测试 (WRF + ROMS + WW3)
#
# 目录规划: 代码/可执行留在树根, 一切模拟运行整理到 Run/ 下
#   COAWST_org/                 <- 源码 + 构建 + coawstM (代码区)
#   Run/prep/                   <- 共享预处理产物 (SCRIP 权重, mod_def, restart)
#   Run/sandy_smoke/            <- SMOKE=1 的 3 小时冒烟测试 (输入+输出)
#   Run/sandy_48h/              <- 完整 48 小时测试 (输入+输出)
#   (RUNDIR=xxx 可覆盖运行目录)
#
# 测试内容: KPP-LT (LT_KPP, LT_KPP_LAGRANGIAN, Reichl et al. 2016)
#           + CL 波流相互作用 (WEC_VF 涡漩力, WW3 谱斯托克斯漂移)
#
# 用法:
#   ./run_sandy_test.sh [prep|run|all]      默认 all
#     prep : 生成 SCRIP 插值权重 + WW3 mod_def/restart (存入 Run/prep)
#     run  : 布置 Run/<案例> 运行目录并启动耦合
#     all  : prep + run
#
#   SMOKE=1 ./run_sandy_test.sh run         3 小时冒烟测试 (改短三模型窗口)
#   PARTITION=xxx ./run_sandy_test.sh run   指定运行分区 (默认 cp6)
#   TIMEOUT_MIN=580 ./run_sandy_test.sh run yhrun 限时保险 (分钟)
#
# 说明:
#   - MPI 进程数 = NnodesATM+WAV+OCN = 1+1+1 = 3 (见 coupling_sandy.in)
#   - 运行目录内有 Projects 符号链接, ocean_sandy.in 的相对路径原样可用
#   - 输出: Run/<案例>/sandy_run_<时间>.log, wrfout_d0*, Sandy_ocean_*.nc,
#           out_grd.grd*
# ===========================================================================

ROOT="/fs2/home/xhzhou/Model/COAWST_org"
# 按用户惯例: 代码在 ~/Model/, 实验在 ~/Run/<模式名>/ 下
RUNROOT="/fs2/home/xhzhou/Run/COAWST_org"
PREPDIR="$RUNROOT/prep"
MODE="${1:-all}"
NP=3                                  # coupling_sandy.in: ATM=1 WAV=1 OCN=1
SCRIP_NC="scrip_sandy_roms_ww3_3grids.nc"
WW3BIN="$ROOT/WW3/build/bin"
SCRIPDIR="$ROOT/Lib/SCRIP_COAWST"
WORK="$RUNROOT/ww3_prep"

log()  { echo "[sandy-test $(date +%H:%M:%S)] $*"; }
die()  { echo "[sandy-test ERROR] $*"; exit 1; }

# --- MPI 启动器: 本机 MPICH 无自带 mpirun (PMIx 依赖调度器), 用天河 yhrun ---
PARTITION="${PARTITION:-cp6}"           # 耦合测试运行分区
if command -v yhrun >/dev/null 2>&1; then
  run_mpi() { # run_mpi <partition> <nproc> <cmd...>  (单节点)
    # TIMEOUT_MIN=20 run ... 可选: 提前于分区限时杀掉挂死作业
    # (debug6 分区上限 30 分钟, 自动钳到 29, 否则 yhrun 报 time limit invalid)
    if [ -n "${TIMEOUT_MIN:-}" ]; then
      local t="$TIMEOUT_MIN"
      [ "$1" = "debug6" ] && [ "$t" -gt 29 ] && t=29
      yhrun -p "$1" -N 1 -n "$2" -t "$t" "${@:3}"
    else
      yhrun -p "$1" -N 1 -n "$2" "${@:3}"
    fi
  }
else
  run_mpi() { mpirun -np "$2" "${@:3}"; }   # 无 yhrun 环境回退
fi

# --- 环境 (mpich/ifort/netcdf/pnetcdf) ---
source /fs2/software/modules/4.2.1-gcc8.5.0/init/bash >/dev/null 2>&1
module purge >/dev/null 2>&1
source "$ROOT/module_load.sh" >/dev/null 2>&1
export LD_LIBRARY_PATH="$ROOT/Lib/MCT/lib:$LD_LIBRARY_PATH"

[ -x "$ROOT/coawstM" ]         || die "coawstM 不存在, 请先运行 build_coawst.sh"
[ -x "$WW3BIN/ww3_grid" ]      || die "缺少 WW3 工具 $WW3BIN/ww3_grid"

# --- 旧版产物一次性迁移: 树根 -> Run/prep (幂等) ---
migrate_prep()
{
  mkdir -p "$PREPDIR"
  local f
  for f in "$SCRIP_NC" mod_def.grd1 mod_def.grd2 mod_def.grd3 \
           restart.grd1 restart.grd2 restart.grd3; do
    [ -f "$ROOT/$f" ] && [ ! -f "$PREPDIR/$f" ] && mv -f "$ROOT/$f" "$PREPDIR/"
  done
}

# ===========================================================================
# 1) SCRIP 耦合插值权重 (coupling_sandy.in: SCRIP_COAWST_NAME)
# ===========================================================================
prep_scrip()
{
  if [ -f "$PREPDIR/$SCRIP_NC" ]; then log "SCRIP 权重已存在, 跳过"; return; fi
  migrate_prep
  [ -f "$PREPDIR/$SCRIP_NC" ] && { log "SCRIP 权重已迁移, 跳过"; return; }

  if [ ! -x "$SCRIPDIR/scrip_coawst" ]; then
    log "编译 scrip_coawst 工具..."
    ( cd "$SCRIPDIR"
      make clean >/dev/null 2>&1
      # 本目录的 cppdefs.h (遮蔽 ROMS/Include/cppdefs.h) 阻止 globaldefs.h
      # 定义 SCRIP_COAWST —— 该宏会把 scrip_coawst.F 编成 subroutine (库模式),
      # 独立可执行文件会链接失败 (undefined MAIN__)。
      SCRIP_CPPFLAGS="-P -traditional-cpp -w -DMPI -DLINUX -DX86_64 -DIFORT"
      SCRIP_CPPFLAGS+=" -I. -I$ROOT/ROMS/Include"
      make CPPFLAGS="$SCRIP_CPPFLAGS" >/tmp/scrip_build.log 2>&1 \
        || { tail -20 /tmp/scrip_build.log; exit 1; }
    ) || die "scrip_coawst 编译失败 (详见 /tmp/scrip_build.log)"
  fi

  log "计算 SCRIP 权重 (WRF2 + ROMS3 + WW3 网格, 需几分钟)..."
  ( cd "$SCRIPDIR"
    sed "s|^OUTPUT_NCFILE=.*|OUTPUT_NCFILE='$SCRIP_NC',|" \
        scrip_coawst_sandy.in > scrip_coawst_sandy_run.in
    # 此 MPICH 为 PMIx 构建, 直接执行会在 MPI_Init 失败, 需经 yhrun 启动。
    # debug6 分区空闲节点多 (30 分钟限时), 权重计算几分钟即可完成
    run_mpi debug6 1 ./scrip_coawst scrip_coawst_sandy_run.in >/tmp/scrip_run.log 2>&1 \
      || { tail -30 /tmp/scrip_run.log; exit 1; }
    mv -f "$SCRIP_NC" "$PREPDIR/"
  ) || die "SCRIP 权重生成失败 (详见 /tmp/scrip_run.log)"
  [ -f "$PREPDIR/$SCRIP_NC" ] || die "SCRIP 输出未生成"
  log "SCRIP 权重完成 -> $PREPDIR/$SCRIP_NC"
}

# ===========================================================================
# 2) WW3 前处理: mod_def.grd1/2/3 (ww3_grid) + restart.grd1/2/3 (ww3_strt)
#    ww3_grid.inp 中 parent/child1/child2 三个结构网格块按需切换
# ===========================================================================
prep_ww3()
{
  local grid var ok=0
  for grid in grd1 grd2 grd3; do
    [ -f "$PREPDIR/mod_def.$grid" ] && [ -f "$PREPDIR/restart.$grid" ] && ok=$((ok+1))
  done
  [ $ok -eq 3 ] && { log "WW3 mod_def/restart 已存在, 跳过"; return; }
  migrate_prep

  mkdir -p "$WORK"
  for grid in grd1 grd2 grd3; do
    case $grid in
      grd1) var=parent ;; grd2) var=child1 ;; grd3) var=child2 ;;
    esac

    if [ ! -f "$PREPDIR/mod_def.$grid" ]; then
      log "WW3 $grid ($var): ww3_grid 生成 mod_def..."
      # 标记行本身注明行数 ("these next 5 lines" 网格块 / "next 1 line" mapsta 块),
      # 按标记行的行数切换注释, 避免窗口外溢误激活后续行
      awk -v V="$var" '
        match($0, /Uncomment these next ([0-9]+) lines? for the (parent|child1|child2) Sandy grid - structured/, m) {
          left=m[1]+0; want=(m[2]==V); print; next
        }
        left>0 { left--
          if (want) { sub(/^\$ */, ""); print }
          else if ($0 !~ /^\$/) { print "$" $0 } else { print }
          next }
        { print }' \
        "$ROOT/Projects/Sandy/WW3/ww3_grid.inp" > "$WORK/ww3_grid.inp"

      ( cd "$WORK"
        for f in "$ROOT"/Projects/Sandy/WW3/ww3_*Sandy_roms_grid*.dat; do ln -sf "$f" .; done
        rm -f mod_def.ww3
        run_mpi debug6 1 "$WW3BIN/ww3_grid" > ww3_grid_$grid.log 2>&1 \
          || { tail -20 ww3_grid_$grid.log; exit 1; }
        [ -f mod_def.ww3 ] || { echo "ww3_grid $grid 未输出 mod_def"; exit 1; }
        mv -f mod_def.ww3 "$PREPDIR/mod_def.$grid"
      ) || die "ww3_grid $grid 失败 (详见 $WORK/ww3_grid_$grid.log)"
    fi

    if [ ! -f "$PREPDIR/restart.$grid" ]; then
      log "WW3 $grid: ww3_strt 生成冷启动 restart..."
      ( cd "$WORK"
        rm -f mod_def.ww3 restart.*
        ln -sf "$PREPDIR/mod_def.$grid" mod_def.ww3
        ln -sf "$ROOT/Projects/Sandy/WW3/ww3_strt.inp" .
        run_mpi debug6 1 "$WW3BIN/ww3_strt" > ww3_strt_$grid.log 2>&1 \
          || { tail -20 ww3_strt_$grid.log; exit 1; }
        rst=$(ls restart.* 2>/dev/null | head -1)
        [ -n "$rst" ] || { echo "ww3_strt $grid 未输出 restart"; exit 1; }
        mv -f "$rst" "$PREPDIR/restart.$grid"
      ) || die "ww3_strt $grid 失败 (详见 $WORK/ww3_strt_$grid.log)"
    fi
  done
  log "WW3 mod_def/restart 就绪 -> $PREPDIR"
}

# ===========================================================================
# 3) 布置运行目录 Run/<案例>: 可执行/输入/预处理产物符号链接 + 自检
# ===========================================================================
setup_rundir()
{
  migrate_prep                      # 树根残留的预处理产物先归位 Run/prep
  if [ "${SMOKE:-0}" = "1" ]; then
    RUNDIR="${RUNDIR:-$RUNROOT/sandy_smoke}"
  else
    RUNDIR="${RUNDIR:-$RUNROOT/sandy_48h}"
  fi
  mkdir -p "$RUNDIR"
  cd "$RUNDIR"

  ln -sfn "$ROOT/coawstM" coawstM
  # Projects 目录链接: ocean_sandy.in 等输入内的 "Projects/..." 相对路径原样可用
  ln -sfn "$ROOT/Projects" Projects
  # ROMS 目录链接: 运行时按 cwd 相对路径读 ROMS/External/varinfo*.yaml
  ln -sfn "$ROOT/ROMS" ROMS

  # WRF 场文件与 namelist
  local f b
  for f in namelist.input wrfinput_d01 wrfinput_d02 wrfbdy_d01 wrflowinp_d01 wrflowinp_d02; do
    ln -sfn "$ROOT/Projects/Sandy/WRF/$f" "$f"
  done
  # WRF 物理常数表 (跳过 namelist*/exe/README/源码)
  for f in "$ROOT"/WRF/run/*; do
    b=$(basename "$f")
    case "$b" in
      namelist*|*.exe|README*|*.nc|*.backup*|create_p3*|*.f90*) continue ;;
    esac
    ln -sfn "$f" "$b"
  done
  # WW3 driver + ww3_grid.inp (SPECTRUM_STOKES 耦合时 coupler 从中读取
  # 网格名/谱参数行, 模板顶部这两行本就未注释, 直接链接即可)
  ln -sfn "$ROOT/Projects/Sandy/WW3/ww3_multi.inp" ww3_multi.inp
  ln -sfn "$ROOT/Projects/Sandy/WW3/ww3_grid.inp" ww3_grid.inp
  # 预处理产物
  ln -sfn "$PREPDIR/$SCRIP_NC" "$SCRIP_NC"
  for f in mod_def.grd1 mod_def.grd2 mod_def.grd3 \
           restart.grd1 restart.grd2 restart.grd3; do
    ln -sfn "$PREPDIR/$f" "$f"
  done

  # 关键输入自检
  for f in Projects/Sandy/ROMS/Sandy_roms_grid.nc \
           Projects/Sandy/ROMS/Sandy_roms_grid_child1.nc \
           ROMS/External/varinfo.yaml \
           Projects/Sandy/ROMS/Sandy_roms_grid_child2.nc \
           Projects/Sandy/ROMS/Sandy_ini.nc \
           Projects/Sandy/ROMS/coawst_bdy_20121028.nc \
           Projects/Sandy/ROMS/Sandy_clm.nc \
           Projects/Sandy/WRF/wrfinput_d01 \
           "$SCRIP_NC" mod_def.grd1 mod_def.grd2 mod_def.grd3 \
           restart.grd1 restart.grd2 restart.grd3; do
    [ -e "$f" ] || die "运行目录 $RUNDIR 缺少输入: $f"
  done
  log "运行目录布置完成 -> $RUNDIR"
}

# ===========================================================================
# 4) 运行;  SMOKE=1 时把 48h 窗口缩短为 3h (本地副本, 不改原文件)
# ===========================================================================
run_model()
{
  cd "$RUNDIR"
  local cpl="$ROOT/Projects/Sandy/coupling_sandy.in"

  if [ "${SMOKE:-0}" = "1" ]; then
    log "SMOKE 模式: 48h -> 3h"
    sed 's/NTIMES == 5760    11520    11520/NTIMES == 360      720      720/' \
        "$ROOT/Projects/Sandy/ROMS/ocean_sandy.in" > ocean_sandy_smoke.in
    # 三个域的 end_day/end_hour 都要改, 且 run_hours 必须同步
    sed -e '/run_hours/ s/48/3/' \
        -e '/end_day/  s/30/28/g' \
        -e '/end_hour/ s/12/15/g' \
        "$ROOT/Projects/Sandy/WRF/namelist.input" > namelist_smoke.input
    sed 's/20121030 120000/20121028 150000/g' \
        "$ROOT/Projects/Sandy/WW3/ww3_multi.inp" > ww3_multi_smoke.inp
    sed -e 's|OCN_name = Projects/Sandy/ROMS/ocean_sandy.in|OCN_name = ocean_sandy_smoke.in|' \
        -e 's|ATM_name = namelist.input|ATM_name = namelist_smoke.input|' \
        -e 's|WAV_name = ww3_multi.inp|WAV_name = ww3_multi_smoke.inp|' \
        "$ROOT/Projects/Sandy/coupling_sandy.in" > coupling_sandy_smoke.in
    cpl="coupling_sandy_smoke.in"
    # 耦合态下 WRF/WW3 读的是硬编码的 ./namelist.input 与 ./ww3_multi.inp
    # (coupling 里的 ATM_name/WAV_name 只供耦合器解析), 必须把运行目录的
    # 这两个链接改指 smoke 副本, 否则 WRF/WW3 按 48h 窗口跑, 在 ROMS
    # 3h 结束后死等交换直到被分区限时杀掉
    ln -sfn namelist_smoke.input namelist.input
    ln -sfn ww3_multi_smoke.inp  ww3_multi.inp
    grep -q "NTIMES == 360"         ocean_sandy_smoke.in   || die "SMOKE: NTIMES 替换失败"
    grep -q "run_hours.*= 3,"       namelist_smoke.input   || die "SMOKE: WRF run_hours 替换失败"
    grep -q "end_day.*28,   28,   28" namelist_smoke.input || die "SMOKE: WRF end_day 替换失败"
    grep -q "20121028 150000"       ww3_multi_smoke.inp    || die "SMOKE: WW3 stop 替换失败"
  fi

  local outlog="sandy_run_$(date +%Y%m%d_%H%M%S).log"
  log "启动: yhrun -p $PARTITION -np $NP ./coawstM $cpl  (日志 $RUNDIR/$outlog)"
  set -o pipefail
  run_mpi "$PARTITION" "$NP" ./coawstM "$cpl" 2>&1 | tee "$outlog"
  local rc=$?
  set +o pipefail
  if [ $rc -eq 0 ]; then
    log "正常运行结束 (rc=0), 输出在 $RUNDIR"
  else
    log "异常退出 rc=$rc, 检查 $RUNDIR/$outlog"
  fi
  exit $rc
}

# ===========================================================================
case "$MODE" in
  prep) prep_scrip; prep_ww3; log "prep 完成 -> $PREPDIR" ;;
  run ) setup_rundir; run_model ;;
  all ) prep_scrip; prep_ww3; setup_rundir; run_model ;;
  *   ) die "用法: $0 [prep|run|all]  (SMOKE=1, PARTITION=, TIMEOUT_MIN=, RUNDIR= 可选)" ;;
esac
