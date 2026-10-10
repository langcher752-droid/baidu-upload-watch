#!/usr/bin/env bash
# ==============================================================================
# 百度网盘上传值守脚本 v2 (macOS / AppleScript)
#
# 作用: 你离开电脑后, Mac 自动"看管"百度网盘桌面版的上传任务——
#   1. 每隔几秒扫描百度网盘窗口的全部 UI 元素(不只是按钮)
#   2. 发现"重试/重新上传/继续上传"按钮 -> 自动点击(失败自动续传)
#   3. 连续多轮无失败、无进行中上传 -> 判定全部传完 -> 自动关机
#
# v2 相比 v1 的修复/升级:
#   - 修复 v1 扫描不到任何元素的 bug(旧写法在 AppleScript 里必然报错被 try 吞掉)
#   - busy 判定改为扫描全部元素的文本(名称/描述/值/标题), 覆盖"正在上传/传输中/
#     排队中"等静态文本, 并用速度字样(如 2.3MB/s)兜底 -> 不会再传到一半误关机
#   - 暂停状态的任务会自动点"继续上传"恢复
#   - 累计重试点击上限(MAX_RETRY_CLICKS): 防止某个文件永久失败导致整夜死循环
#   - "武装"机制: 没看到过传输窗口/上传活动就绝不关机, 防止启动过早误关机
#   - 传输窗口被关闭时不会自动关机(只警告), 必须保持传输窗口打开
#   - 百度网盘进程退出连续多轮 -> 视为任务结束 -> 关机
#   - osascript 的报错会透传进日志(权限问题一眼可见)
#   - --dump 模式: 导出脚本"眼中"的界面元素树, 一次性校准关键字
#
# 用法:
#   ./baidu_upload_watch.sh --dump     第一次必跑: 导出界面元素, 校准关键字
#   ./baidu_upload_watch.sh --debug    干跑: 只打印检测结果, 不点击、不关机
#   ./baidu_upload_watch.sh            正式值守(关机前 10 秒可按回车取消)
#   ./baidu_upload_watch.sh --yes      正式值守, 直接关机不确认
#
# 首次使用前必须授权:
#   系统设置 > 隐私与安全性 > 辅助功能 -> 勾选你运行脚本的终端
#
# 重要: 先把上传任务加入百度网盘队列、打开传输窗口, 再启动本脚本。
# ==============================================================================
set -u

# ----------------------- 配置区 -----------------------
POLL_SECONDS=8            # 每轮检查间隔(秒)
DONE_QUIET_CHECKS=4       # 连续多少轮"无失败、无进行中"判定上传完成
START_GRACE_SECONDS=180   # 启动后多少秒内, 若从未见过上传活动则不判定完成(防止任务还没加进去就关机)
MAX_RETRY_CLICKS=60       # 累计自动重试点击上限, 0=不限; 达到后停止点击, 只等剩余任务传完
MAX_HOURS=0               # 最长值守时间(小时), 0=不限; 超时强制关机
EXIT_CONFIRM_ROUNDS=5     # 百度网盘进程连续消失多少轮 -> 判定任务结束 -> 关机
NOTIFY=1                  # 关键事件发 macOS 通知(1=开 0=关)

APP_KEYWORDS="百度网盘|BaiduNetdisk"          # 进程名匹配(用 | 分隔)
CLICK_KEYWORDS="重试|重新上传|继续上传"         # 命中就点的按钮文字
BUSY_KEYWORDS="正在上传|传输中|排队中|等待中|暂停|取消上传|继续上传"  # 出现即视为"还在忙"
DONE_KEYWORDS="全部完成|已完成"                # 完成字样(仅记录日志参考)
SPEED_HINT="/s"                               # 任意文本含此子串(如 2.3MB/s)视为进行中; 留空关闭
WINDOW_TITLE="传输|提示|警告|错误"              # 深度扫描标题含这些字的窗口; 一个都没匹配到时兜底扫全部

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$BASEDIR/baidu_upload_watch.log"
ERR_FILE="$BASEDIR/baidu_upload_watch.log.err"
DUMP_FILE="$BASEDIR/baidu_ui_dump.txt"
# ------------------------------------------------------

DEBUG=0; FORCE=0; DUMP=0
for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG=1 ;;
    --yes)   FORCE=1 ;;
    --dump)  DUMP=1 ;;
    *) echo "未知参数: $arg (支持 --debug / --yes / --dump)"; exit 1 ;;
  esac
done

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
note() { printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
notify() {
  [ "$NOTIFY" = "1" ] || return 0
  osascript -e "display notification \"$1\" with title \"网盘值守\"" >/dev/null 2>&1 || true
}

# 把 "a|b|c" 转成 AppleScript 列表字面量 {"a", "b", "c"}; 空串 -> {""}
# 注意: 关键词里不要出现英文双引号
kw_to_as() {
  local out="{" kw first=1 oldIFS="$IFS"
  IFS='|'
  for kw in $1; do
    if [ "$first" = 1 ]; then first=0; else out="$out, "; fi
    out="$out\"$kw\""
  done
  IFS="$oldIFS"
  if [ "$first" = 1 ]; then out="$out\"\""; fi
  printf '%s' "$out}"
}

# --------------------- AppleScript: 界面扫描 ---------------------
# 返回: clicked=点击重试次数 busy=0/1 found=0/1 wins=扫描窗口数 fb=是否兜底全扫 done=是否出现完成字样 cap=被截断窗口数
scan_apple() {
  # 关键: 关键词由 shell 直接内联为 AppleScript 列表字面量, 不要走 system attribute!
  # 实测中文环境变量经 system attribute 转手后, 在 tell 块里参与比较会触发
  # 无法被 try 捕获的 -1700, 整轮扫描崩溃(时好时坏, 与百度是否开窗有关)。
  local app_as click_as busy_as done_as win_as
  app_as="$(kw_to_as "$APP_KEYWORDS")"
  click_as="$(kw_to_as "$CLICK_KEYWORDS")"
  busy_as="$(kw_to_as "$BUSY_KEYWORDS")"
  done_as="$(kw_to_as "$DONE_KEYWORDS")"
  win_as="$(kw_to_as "$WINDOW_TITLE")"
  osascript - 2>"$ERR_FILE" <<APPLESCRIPT
on run argv
  set appList to $app_as
  set clickList to $click_as
  set busyList to $busy_as
  set doneList to $done_as
  set winList to $win_as
  set spdHint to "$SPEED_HINT"
  set doClick to "$DO_CLICK"

  set clicked to 0
  set busy to 0
  set foundProc to 0
  set winCount to 0
  set fallback to 0
  set doneSeen to 0
  set capped to 0
  set capTarget to 1500
  set capFB to 400

  try
    tell application "System Events"
      -- 注意: 不要用 "whose background only is false" 过滤, 该子句在进程瞬间退出时
      -- 会抛出无法被 try 捕获的 -1700 (实测), 导致整轮扫描崩溃。改为逐进程防御式读取。
      set procs to every process
      repeat with p in procs
        set pname to ""
        try
          set pname to name of p as text
        end try
        set matched to false
        if pname is not "" then
          -- 注意: 此处不能套 try! 匹配是纯内存比较; 实测 bare try 包住
          -- "contains (contents of kw)" 会在 tell 块上下文里触发无法捕获的 -1700
          repeat with kw in appList
            if pname contains (contents of kw) then
              set matched to true
              exit repeat
            end if
          end repeat
        end if
        if matched then
          set isBG to true
          try
            set isBG to background only of p
          end try
          if isBG is false then
            set foundProc to 1
            try
              tell process pname
              set allWins to windows
              set targetWins to {}
              if (count of winList) is 0 then
                set targetWins to allWins
              else
                repeat with w in allWins
                  set wTitle to ""
                  try
                    set wTitle to name of w as text
                  end try
                  repeat with kw in winList
                    if wTitle contains (contents of kw) then
                      copy w to end of targetWins
                      exit repeat
                    end if
                  end repeat
                end repeat
              end if
              if (count of targetWins) is 0 then
                set fallback to 1
                set targetWins to allWins
              end if
              repeat with w in targetWins
                -- 每个窗口独立 try: 百度窗口的 AX 对象随时可能失效(迭代引用抛错),
                -- 一个窗口炸不能拖垮其余窗口的扫描(实测第二个窗口会毒死整轮)
                try
              set winCount to winCount + 1
              set thisCap to capTarget
              set wTitle2 to ""
              try
                set wTitle2 to name of w as text
              end try
              if fallback is 1 then set thisCap to capFB
              set els to {}
              try
                set els to entire contents of w
              end try
              set i to 0
              repeat with el in els
                  set i to i + 1
                  if i > thisCap then
                    set capped to capped + 1
                    exit repeat
                  end if
                  set pr to {}
                  try
                    set pr to properties of el
                  end try
                  if (count of pr) > 0 then
                    set nm to ""
                    set dsc to ""
                    set vl to ""
                    set ttl to ""
                    set roleStr to ""
                    set isEn to true
                    try
                      set nm to (name of pr) as text
                    end try
                    try
                      set dsc to (description of pr) as text
                    end try
                    try
                      set vl to (value of pr) as text
                    end try
                    try
                      set ttl to (title of pr) as text
                    end try
                    try
                      set roleStr to (role of pr) as text
                    end try
                    try
                      set isEn to enabled of pr
                    end try
                    set blob to nm & " § " & dsc & " § " & vl & " § " & ttl
                    set isBtn to false
                    if roleStr contains "Button" then set isBtn to true

                    -- 自动点击 重试/继续上传 (每次扫描最多点20下)
                    if (doClick is "1") and isBtn and isEn and clicked < 20 then
                      repeat with kw in clickList
                        if blob contains (contents of kw) then
                          set hitOk to false
                          try
                            click el
                            set hitOk to true
                          end try
                          if not hitOk then
                            try
                              perform action "AXPress" of el
                              set hitOk to true
                            end try
                          end if
                          if hitOk then
                            set clicked to clicked + 1
                            exit repeat
                          end if
                        end if
                      end repeat
                    end if

                    -- 进行中判定: 按钮须为可用状态, 静态文本一律算
                    if busy is 0 then
                      set mayBusy to true
                      if isBtn and (not isEn) then set mayBusy to false
                      if mayBusy then
                        repeat with kw in bzyList
                          if blob contains (contents of kw) then
                            set busy to 1
                            exit repeat
                          end if
                        end repeat
                      end if
                    end if
                    if busy is 0 and spdHint is not "" then
                      if blob contains spdHint then set busy to 1
                    end if

                    -- 完成字样(仅日志参考)
                    if doneSeen is 0 then
                      repeat with kw in doneList
                        if blob contains (contents of kw) then
                          set doneSeen to 1
                          exit repeat
                        end if
                      end repeat
                    end if
                  end if
                end repeat
                end try
              end repeat
            end tell
          end try
          end if
        end if
      end repeat
    end tell
  end try

  return "clicked=" & (clicked as text) & " busy=" & (busy as text) & " found=" & (foundProc as text) & " wins=" & (winCount as text) & " fb=" & (fallback as text) & " done=" & (doneSeen as text) & " cap=" & (capped as text)
end run
APPLESCRIPT
}

# --------------------- AppleScript: 导出界面元素(--dump 校准用) ---------------------
dump_apple() {
  # 同 scan: 关键词由 shell 内联, 不走 system attribute(否则会触发无法捕获的 -1700)
  local app_as
  app_as="$(kw_to_as "$APP_KEYWORDS")"
  osascript - 2>"$ERR_FILE" <<APPLESCRIPT
on run argv
  set appList to $app_as
  -- 注意: 变量名不能叫 accLines! System Events 词典里有 UI 元素类 outlines,
  -- 术语匹配不分大小写, 在 tell 块内 set end of accLines 会被解析成
  -- "every outline" 引用而必炸 -10006 (被 try 吞掉后 dump 静默返回空)。
  set accLines to {}
  set maxE to 4000

  try
    tell application "System Events"
      -- 同 scan: 不用 whose 子句过滤, 逐进程防御式读取(避开不可捕获的 -1700)
      set procs to every process
      repeat with p in procs
        set pname to ""
        try
          set pname to name of p as text
        end try
        set matched to false
        if pname is not "" then
          -- 同 scan: 匹配循环不能套 try
          repeat with kw in appList
            if pname contains (contents of kw) then
              set matched to true
              exit repeat
            end if
          end repeat
        end if
        if matched then
          set isBG to true
          try
            set isBG to background only of p
          end try
          if isBG is false then
          set end of accLines to "PROCESS  " & pname
          try
            tell process pname
              set allWins to windows
              set end of accLines to "WINDOWS  " & ((count of allWins) as text)
              repeat with w in allWins
                -- 每窗独立 try(同 scan): 一个窗口的 AX 引用失效不能拖垮其余窗口
                try
                set wTitle to ""
                try
                  set wTitle to name of w as text
                end try
                set end of accLines to "== WINDOW [" & wTitle & "]"
                set els to {}
                try
                  set els to entire contents of w
                end try
                set i to 0
                repeat with el in els
                  set i to i + 1
                  if i > maxE then
                    set end of accLines to "...(超过" & (maxE as text) & "个元素, 已截断)"
                    exit repeat
                  end if
                  set pr to {}
                  try
                    set pr to properties of el
                  end try
                  set nm to ""
                  set dsc to ""
                  set vl to ""
                  set ttl to ""
                  set roleStr to ""
                  set enStr to ""
                  try
                    set nm to (name of pr) as text
                  end try
                  try
                    set dsc to (description of pr) as text
                  end try
                  try
                    set vl to (value of pr) as text
                  end try
                  try
                    set ttl to (title of pr) as text
                  end try
                  try
                    set roleStr to (role of pr) as text
                  end try
                  try
                    set enStr to (enabled of pr) as text
                  end try
                  set end of accLines to (i as text) & tab & roleStr & tab & enStr & tab & "[" & nm & "] [" & dsc & "] [" & vl & "] [" & ttl & "]"
                end repeat
                end try
              end repeat
            end tell
          end try
          end if
        end if
      end repeat
    end tell
  end try

  set AppleScript's text item delimiters to linefeed
  set out to accLines as text
  set AppleScript's text item delimiters to ""
  return out
end run
APPLESCRIPT
}

# 解析 scan_apple 返回的 "k=v ..." 字符串
parse_val() {
  local v
  v="$(printf '%s' "$2" | sed -n "s/.*${1}=\([0-9][0-9]*\).*/\1/p")"
  if [ -z "$v" ]; then echo "0"; else echo "$v"; fi
}

# 关机: 0=已处理(关机/debug跳过) 1=用户取消(继续值守) 2=失败(退出脚本)
shutdown_mac() {
  local reason="$1"
  log "判定值守结束(原因: ${reason}), 准备关机..."
  notify "上传完成: ${reason}, 即将关机"
  if [ "$DEBUG" = "1" ]; then
    log "[debug] --debug 模式, 跳过关机。"
    return 0
  fi
  if [ "$FORCE" != "1" ] && [ -t 0 ]; then
    log "10秒内按回车可取消本次自动关机; 不操作将关机。"
    if read -t 10 -r _; then
      log "检测到输入, 已取消本次关机, 继续值守。"
      quiet=0
      return 1
    fi
  else
    note "非交互环境或 --yes 模式, 跳过取消窗口。"
  fi
  if osascript -e 'tell application "System Events" to shut down' >>"$LOG_FILE" 2>&1; then
    log "已发出关机指令, Mac 稍后关闭。晚安~"
    return 0
  fi
  log "System Events 关机未成功, 尝试免密 sudo shutdown (需已配置 /etc/sudoers.d/nopass-shutdown)..."
  if sudo -n shutdown -h now >>"$LOG_FILE" 2>&1; then
    log "已通过 shutdown 指令关机。"
    return 0
  fi
  log "自动关机失败! 请手动关机。"
  notify "自动关机失败, 请手动关机"
  return 2
}

trap 'log "值守被手动中断, 退出。"; exit 0' INT TERM

# ------------------------------- --dump 校准模式 -------------------------------
if [ "$DUMP" = "1" ]; then
  log "--dump: 正在导出百度网盘界面元素(需已打开网盘和传输窗口)..."
  out="$(dump_apple)"
  printf '%s\n' "$out" > "$DUMP_FILE"
  lineN="$(wc -l < "$DUMP_FILE" | tr -d ' ')"
  log "--dump 完成: 共${lineN}行 -> $DUMP_FILE"
  echo "===== 快速检查(关键字在界面树中的命中行数) ====="
  for kw in 重试 重新上传 继续上传 正在上传 传输中 排队中 暂停 取消上传 已完成; do
    n="$(grep -c "$kw" "$DUMP_FILE" 2>/dev/null || true)"
    echo "  ${kw}: ${n:-0} 处"
  done
  echo "完整元素树: $DUMP_FILE (用 --debug 干跑前先核对上面关键字)"
  exit 0
fi

# ------------------------------- 主循环 -------------------------------
log "====== 百度网盘上传值守开始 (v2) ======"
log "配置: 轮询=${POLL_SECONDS}s 完成判定=连续${DONE_QUIET_CHECKS}轮无任务 重试上限=${MAX_RETRY_CLICKS} 最长=${MAX_HOURS}h debug=${DEBUG}"
log "请确认: 1) 百度网盘已打开  2) 传输窗口保持打开  3) 上传任务已加入队列"

armed=0            # 是否已"武装"(见过传输窗口或上传活动); 未武装绝不关机
sawActivity=0      # 是否见过上传活动(有过 busy 或点击)
quiet=0
totalClicked=0
goneRounds=0
fbRounds=0
waitRounds=0
startTs=$(date +%s)
lastErr=""
DO_CLICK=1

while :; do
  # 每轮决定是否允许点击: debug 不点; 达到重试上限不点
  DO_CLICK=1
  if [ "$DEBUG" = "1" ]; then DO_CLICK=0; fi
  if [ "$MAX_RETRY_CLICKS" -gt 0 ] && [ "$totalClicked" -ge "$MAX_RETRY_CLICKS" ]; then DO_CLICK=0; fi

  t0=$(date +%s)
  out="$(scan_apple)"
  scanRc=$?
  t1=$(date +%s)
  scanDur=$((t1 - t0))

  clicked="$(parse_val clicked "$out")"
  busy="$(parse_val busy "$out")"
  found="$(parse_val found "$out")"
  wins="$(parse_val wins "$out")"
  fb="$(parse_val fb "$out")"
  doneSeen="$(parse_val done "$out")"
  capN="$(parse_val cap "$out")"

  # osascript 报错透传(内容变化时才记)
  errTxt="$(cat "$ERR_FILE" 2>/dev/null || true)"
  if [ -n "$errTxt" ] && [ "$errTxt" != "$lastErr" ]; then
    note "osascript 报警: ${errTxt}"
    lastErr="$errTxt"
  fi

  # 重试点击统计
  if [ "$clicked" -gt 0 ]; then
    totalClicked=$((totalClicked + clicked))
    log "自动重试: 本轮点了${clicked}次, 累计${totalClicked}次"
    if [ "$MAX_RETRY_CLICKS" -gt 0 ] && [ "$totalClicked" -ge "$MAX_RETRY_CLICKS" ]; then
      log "累计重试已达上限(${MAX_RETRY_CLICKS}次), 停止自动点击, 只等待其余任务传完; 仍有失败项请早上手动处理。"
      notify "重试达上限, 停止点击, 等剩余任务"
    fi
  fi

  # 武装判定: 见过窗口或活动才开始考虑关机
  if [ "$armed" = "0" ] && { [ "$wins" -gt 0 ] || [ "$busy" = "1" ] || [ "$clicked" -gt 0 ]; }; then
    armed=1
    log "已检测到百度网盘窗口/上传活动, 值守进入工作状态。"
  fi

  if [ "$busy" = "1" ] || [ "$clicked" -gt 0 ]; then
    sawActivity=1
  fi

  # 未武装: 提示等待
  if [ "$armed" = "0" ]; then
    waitRounds=$((waitRounds + 1))
    if [ $((waitRounds % 20)) -eq 0 ]; then
      note "提示: 已等待${waitRounds}轮仍未检测到传输窗口/上传活动。请打开百度网盘传输窗口; 用 --dump 可查看脚本眼中的界面。"
    fi
  fi

  # 进程消失计数(仅在无 osascript 报错时计, 避免权限问题误判)
  if [ "$found" = "1" ]; then
    goneRounds=0
  elif [ -z "$errTxt" ]; then
    goneRounds=$((goneRounds + 1))
    if [ "$armed" = "1" ] && [ "$goneRounds" -eq 2 ]; then
      note "百度网盘进程暂时消失(第${goneRounds}轮); 连续${EXIT_CONFIRM_ROUNDS}轮将判定结束并关机。"
    fi
  fi

  # 传输窗口丢失: 兜底扫描模式时警告(不关机)
  if [ "$armed" = "1" ] && [ "$found" = "1" ] && [ "$fb" = "1" ]; then
    fbRounds=$((fbRounds + 1))
    if [ $((fbRounds % 10)) -eq 1 ]; then
      note "提示: 找不到标题含[${WINDOW_TITLE}]的窗口(正在兜底扫描全部窗口)。若你关闭了传输窗口请重新打开, 否则不会自动关机。可用 --dump 校准窗口标题。"
    fi
  else
    fbRounds=0
  fi

  # quiet 计数
  if [ "$busy" = "1" ] || [ "$clicked" -gt 0 ]; then
    quiet=0
  else
    quiet=$((quiet + 1))
  fi

  if [ "$DEBUG" = "1" ]; then
    log "[debug] clicked=${clicked} busy=${busy} found=${found} wins=${wins} fb=${fb} done=${doneSeen} cap=${capN} armed=${armed} quiet=${quiet}/${DONE_QUIET_CHECKS} 累计点击=${totalClicked} 扫描耗时=${scanDur}s"
  fi
  if [ "$scanDur" -gt $((POLL_SECONDS * 3)) ]; then
    note "扫描耗时${scanDur}s(界面元素较多), 建议调大 POLL_SECONDS。"
  fi

  # 完成判定 1: 进程退出
  if [ "$armed" = "1" ] && [ "$goneRounds" -ge "$EXIT_CONFIRM_ROUNDS" ]; then
    log "百度网盘进程已连续${goneRounds}轮未找到, 判定任务结束。"
    shutdown_mac "百度网盘已退出"
    rc=$?
    case $rc in
      0) break ;;
      1) continue ;;
      *) log "值守终止: 未能自动关机。"; break ;;
    esac
  fi

  # 完成判定 2: 传输窗口可见 + 连续安静
  #   附加条件: 见过上传活动, 或已超过启动缓冲期(防止任务还没加进去就关机)
  nowTs=$(date +%s)
  elapsed=$((nowTs - startTs))
  if [ "$armed" = "1" ] && [ "$found" = "1" ] && [ "$fb" = "0" ] && [ "$quiet" -ge "$DONE_QUIET_CHECKS" ] \
     && { [ "$sawActivity" = "1" ] || [ "$elapsed" -ge "$START_GRACE_SECONDS" ]; }; then
    log "已连续${DONE_QUIET_CHECKS}轮无失败/无进行中任务, 判定全部上传完成。"
    shutdown_mac "全部上传完成"
    rc=$?
    case $rc in
      0) break ;;
      1) continue ;;
      *) log "值守终止: 未能自动关机。"; break ;;
    esac
  fi

  # 完成判定 3: 超时强制关机
  if [ "$MAX_HOURS" -gt 0 ] && [ "$elapsed" -ge $((MAX_HOURS * 3600)) ]; then
    log "已达最长值守时间(${MAX_HOURS}小时), 强制结束。"
    shutdown_mac "值守超时"
    rc=$?
    case $rc in
      1) continue ;;
      *) break ;;
    esac
  fi

  sleep "$POLL_SECONDS"
done

log "====== 值守脚本结束 ======"
