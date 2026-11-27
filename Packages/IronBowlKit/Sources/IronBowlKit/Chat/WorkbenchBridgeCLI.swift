import Foundation

/// 为首页「今天」AI 对话提供的本地命令行桥接工具（`ironbowl-cli`），让 AI CLI 可按需读写工作台共享 SQLite 数据。
public nonisolated enum WorkbenchBridgeCLI {
    public static var defaultDirectory: URL {
        AppPaths.supportDirectory.appending(path: "bin", directoryHint: .isDirectory)
    }

    public static var defaultExecutableURL: URL {
        defaultDirectory.appending(path: "ironbowl-cli")
    }

    /// 确保本地可执行脚本 `ironbowl-cli` 已安装且为最新版本。
    @discardableResult
    public static func ensureInstalled(at url: URL = defaultExecutableURL) throws -> URL {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing != scriptContent {
            try scriptContent.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// 注入到首页 AI 首轮对话（或切换后端续聊重建上下文时）的精简工具说明。
    public static func promptPreamble(
        cliPath: String,
        databasePath: String,
        permissionMode: ChatPermissionMode,
        now: Date = Date()
    ) -> String {
        let dayFmt = DateFormatter()
        dayFmt.calendar = Calendar(identifier: .gregorian)
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"
        let today = dayFmt.string(from: now)

        let weekdays = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let wd = weekdays[Calendar.current.component(.weekday, from: now)]

        let roFlag = permissionMode == .readOnly ? " --read-only" : ""
        let cmdPrefix = "\"\(cliPath)\" --db \"\(databasePath)\"\(roFlag)"

        return """
        <ironbowl_workbench>
        今天是 \(today)（\(wd)）。你正在「饭碗 IronBowl」工作台中运行，可通过本地只读/可写桥接命令直接查询与联动用户的工作台数据（待办、禅道日报、周报/月报/述职、随手便签、剪贴板片段、考勤加班）。
        当用户询问个人日程/待办/工时/报告/打卡，或要求记录待办、记工作内容到日报草稿、保存便签、设置加班时，请主动调用下方命令并用中文基于真实 JSON 结果回复（不要编造数据）：
        命令前缀：\(cmdPrefix)
        - 只读查询：
          - `status`（今日考勤、加班、待办数、便签数、已提交与草稿工时总览）
          - `todos [--all|--pending] [--limit N]`
          - `logs [--days N]`（近期禅道已提交工时与未提交草稿）
          - `reports [--kind weekly|monthly|review] [--limit N]`
          - `notes [--limit N]` / `snippets [--limit N] [--recent]` / `attendance [--days N]`
          - `search "<关键词>"`
        - 写入联动（\(permissionMode == .readOnly ? "当前处于只读模式，禁止调用写命令" : "仅在用户明确要求创建/修改/完成时调用")）：
          - `todo-add "<标题>" [--due yyyy-MM-dd] [--priority 0|1|2] [--hours H] [--notes "<备注>"]`
          - `todo-done "<id前缀>"`
          - `note-add "<标题>" "<正文>" [--pin]`
          - `draft-add "<工作内容>" [--hours H] [--date yyyy-MM-dd]`
          - `overtime-set <小时数> [--date yyyy-MM-dd]`
        </ironbowl_workbench>
        """
    }

    public static let scriptContent: String = #"""
#!/bin/zsh
set -euo pipefail

DB_PATH="${IRONBOWL_DB:-$HOME/Library/Application Support/IronBowl/ironbowl.sqlite}"
READ_ONLY="${IRONBOWL_READ_ONLY:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)
      [[ $# -ge 2 ]] || { print -u2 '{"ok":false,"error":"missing --db value"}'; exit 1; }
      DB_PATH="$2"
      shift 2
      ;;
    --read-only)
      READ_ONLY=1
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

SUBCMD="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

sql_escape() {
  print -rn -- "${1//'/''}"
}

require_db() {
  if [[ ! -f "$DB_PATH" ]]; then
    print -u2 "{\"ok\":false,\"error\":\"database not found\",\"path\":\"$DB_PATH\"}"
    exit 1
  fi
}

require_write() {
  if [[ "$READ_ONLY" == "1" ]]; then
    print -rn -- '{"ok":false,"error":"当前对话处于只读沙箱模式，禁止写入工作台数据"}'
    print ""
    exit 2
  fi
}

sql_scalar() {
  /usr/bin/sqlite3 -cmd ".timeout 3000" "$DB_PATH" "$1"
}

query_json() {
  local out
  out="$(/usr/bin/sqlite3 -cmd ".timeout 3000" -json "$DB_PATH" "$1")"
  if [[ -z "${out//[[:space:]]/}" ]]; then
    print -rn -- "[]"
  else
    print -rn -- "$out"
  fi
}

has_table() {
  local tbl
  tbl="$(sql_escape "$1")"
  local cnt
  cnt="$(sql_scalar "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='$tbl';")"
  [[ "$cnt" -gt 0 ]]
}

valid_int() {
  local val="$1"
  local fallback="$2"
  if [[ "$val" =~ '^[0-9]+$' ]]; then
    print -rn -- "$val"
  else
    print -rn -- "$fallback"
  fi
}

valid_number() {
  local val="$1"
  local fallback="$2"
  if [[ "$val" =~ '^-?[0-9]+([.][0-9]+)?$' ]]; then
    print -rn -- "$val"
  else
    print -rn -- "$fallback"
  fi
}

case "$SUBCMD" in
  help|-h|--help)
    cat <<'EOF'
Usage: ironbowl-cli [--db PATH] [--read-only] <command> [args]
Read commands:
  status
  todos [--all|--pending] [--limit N]
  logs [--days N]
  reports [--kind weekly|monthly|review] [--limit N]
  notes [--limit N]
  snippets [--limit N] [--recent]
  attendance [--days N]
  search <keyword>
Write commands:
  todo-add <title> [--due YYYY-MM-DD] [--priority 0|1|2] [--hours H] [--notes TEXT]
  todo-done <id-prefix>
  note-add <title> <content> [--pin]
  draft-add <work> [--hours H] [--date YYYY-MM-DD]
  overtime-set <hours> [--date YYYY-MM-DD]
EOF
    ;;

  status)
    require_db
    TODAY="$(date '+%Y-%m-%d')"
    OT_HOURS="$(sql_scalar "SELECT COALESCE((SELECT hours FROM dailyOvertime WHERE date = '$TODAY'), 0);")"
    TODO_PENDING="$(has_table todoItem && sql_scalar "SELECT count(*) FROM todoItem WHERE isCompleted = 0;" || print -rn 0)"
    NOTES_COUNT="$(has_table scratchpadNote && sql_scalar "SELECT count(*) FROM scratchpadNote;" || print -rn 0)"
    SNIPPETS_COUNT="$(has_table clipboardHistory && sql_scalar "SELECT count(*) FROM clipboardHistory WHERE isSnippet = 1;" || print -rn 0)"
    ATT_JSON="null"
    if has_table attendanceDailyRecord; then
      ATT_ROW="$(query_json "SELECT date, clockIn, clockOut, onDutyResult, offDutyResult, source FROM attendanceDailyRecord WHERE date = '$TODAY' LIMIT 1;")"
      if [[ "$ATT_ROW" != "[]" ]]; then
        ATT_JSON="$(sql_scalar "SELECT json_extract('$ATT_ROW', '$[0]');" 2>/dev/null || true)"
        if [[ -z "$ATT_JSON" ]]; then
          ATT_JSON="$ATT_ROW"
        fi
      fi
    fi
    SUBMITTED_HOURS="0"
    if has_table zentaoSubmission; then
      SUBMITTED_HOURS="$(sql_scalar "SELECT COALESCE(SUM(hours), 0) FROM zentaoSubmission WHERE date = '$TODAY';")"
    fi
    DRAFT_ENTRIES="0"
    if has_table zentaoPendingDraft; then
      DRAFT_ENTRIES="$(sql_scalar "SELECT COALESCE((SELECT json_array_length(payload) FROM zentaoPendingDraft WHERE date = '$TODAY'), 0);")"
    fi
    if [[ "$ATT_JSON" == "null" ]]; then
      sql_scalar "SELECT json_object('today', '$TODAY', 'overtimeHours', CAST($OT_HOURS AS REAL), 'pendingTodosCount', $TODO_PENDING, 'notesCount', $NOTES_COUNT, 'snippetsCount', $SNIPPETS_COUNT, 'submittedLogHours', CAST($SUBMITTED_HOURS AS REAL), 'pendingDraftCount', $DRAFT_ENTRIES, 'attendance', NULL);"
    else
      ESC_ATT="$(sql_escape "$ATT_JSON")"
      sql_scalar "SELECT json_object('today', '$TODAY', 'overtimeHours', CAST($OT_HOURS AS REAL), 'pendingTodosCount', $TODO_PENDING, 'notesCount', $NOTES_COUNT, 'snippetsCount', $SNIPPETS_COUNT, 'submittedLogHours', CAST($SUBMITTED_HOURS AS REAL), 'pendingDraftCount', $DRAFT_ENTRIES, 'attendance', json('$ESC_ATT'));"
    fi
    ;;

  todos)
    require_db
    has_table todoItem || { print -rn -- '[]'; print ""; exit 0; }
    FILTER="isCompleted = 0"
    LIMIT=30
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --all) FILTER="1=1"; shift ;;
        --pending) FILTER="isCompleted = 0"; shift ;;
        --limit) LIMIT="$(valid_int "${2:-30}" 30)"; shift 2 ;;
        *) shift ;;
      esac
    done
    query_json "SELECT id, title, notes, dueDate, priority, estimatedHours, isCompleted, loggedDate, zentaoObjectType, zentaoObjectID, updatedAt FROM todoItem WHERE $FILTER ORDER BY isCompleted ASC, priority DESC, COALESCE(dueDate, '9999-99-99') ASC, updatedAt DESC LIMIT $LIMIT;"
    print ""
    ;;

  logs)
    require_db
    DAYS=7
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --days) DAYS="$(valid_int "${2:-7}" 7)"; shift 2 ;;
        *) shift ;;
      esac
    done
    MIN_DAY="$(date -v-"${DAYS}"d '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')"
    SUBS="[]"
    if has_table zentaoSubmission; then
      SUBS="$(query_json "SELECT id, date, taskID, hours, left, work, isOvertime, submittedAt FROM zentaoSubmission WHERE date >= '$MIN_DAY' ORDER BY date DESC, id DESC LIMIT 100;")"
    fi
    DRAFTS="[]"
    if has_table zentaoPendingDraft; then
      DRAFTS="$(query_json "SELECT date, json(payload) AS entries, updatedAt FROM zentaoPendingDraft WHERE date >= '$MIN_DAY' ORDER BY date DESC LIMIT 30;")"
    fi
    ESC_SUBS="$(sql_escape "$SUBS")"
    ESC_DRAFTS="$(sql_escape "$DRAFTS")"
    sql_scalar "SELECT json_object('since', '$MIN_DAY', 'submissions', json('$ESC_SUBS'), 'drafts', json('$ESC_DRAFTS'));"
    ;;

  reports)
    require_db
    KIND="weekly"
    LIMIT=5
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --kind) KIND="${2:-weekly}"; shift 2 ;;
        --limit) LIMIT="$(valid_int "${2:-5}" 5)"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$KIND" in
      monthly)
        has_table monthlyReport || { print -rn -- '[]'; print ""; exit 0; }
        query_json "SELECT monthKey, periodStart, periodEnd, title, style, totalHours, content, extraNotes, monthlyOKR, updatedAt FROM monthlyReport ORDER BY monthKey DESC LIMIT $LIMIT;"
        ;;
      review|annual)
        has_table reviewReport || { print -rn -- '[]'; print ""; exit 0; }
        query_json "SELECT periodKey, scopeKind, periodStart, periodEnd, title, style, totalHours, overtimeHours, commitCount, content, updatedAt FROM reviewReport ORDER BY updatedAt DESC LIMIT $LIMIT;"
        ;;
      *)
        has_table weeklyReport || { print -rn -- '[]'; print ""; exit 0; }
        query_json "SELECT weekStart, weekEnd, title, style, totalHours, content, extraNotes, updatedAt FROM weeklyReport ORDER BY weekStart DESC LIMIT $LIMIT;"
        ;;
    esac
    print ""
    ;;

  notes)
    require_db
    has_table scratchpadNote || { print -rn -- '[]'; print ""; exit 0; }
    LIMIT=20
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --limit) LIMIT="$(valid_int "${2:-20}" 20)"; shift 2 ;;
        *) shift ;;
      esac
    done
    query_json "SELECT id, title, content, colorTag, isPinned, updatedAt FROM scratchpadNote ORDER BY isPinned DESC, updatedAt DESC LIMIT $LIMIT;"
    print ""
    ;;

  snippets)
    require_db
    has_table clipboardHistory || { print -rn -- '[]'; print ""; exit 0; }
    LIMIT=20
    ONLY_SNIPPET=1
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --limit) LIMIT="$(valid_int "${2:-20}" 20)"; shift 2 ;;
        --recent) ONLY_SNIPPET=0; shift ;;
        *) shift ;;
      esac
    done
    WHERE_SQL="isSnippet = 1"
    [[ "$ONLY_SNIPPET" == "0" ]] && WHERE_SQL="1=1"
    query_json "SELECT id, snippetTitle, content, kind, sourceApp, copyCount, isSnippet, copiedAt FROM clipboardHistory WHERE $WHERE_SQL ORDER BY isSnippet DESC, copiedAt DESC LIMIT $LIMIT;"
    print ""
    ;;

  attendance)
    require_db
    DAYS=14
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --days) DAYS="$(valid_int "${2:-14}" 14)"; shift 2 ;;
        *) shift ;;
      esac
    done
    MIN_DAY="$(date -v-"${DAYS}"d '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')"
    has_table attendanceDailyRecord || { print -rn -- '[]'; print ""; exit 0; }
    query_json "SELECT a.date, a.clockIn, a.clockOut, a.onDutyResult, a.offDutyResult, COALESCE(o.hours, 0) AS overtimeHours FROM attendanceDailyRecord a LEFT JOIN dailyOvertime o ON o.date = a.date WHERE a.date >= '$MIN_DAY' ORDER BY a.date DESC;"
    print ""
    ;;

  search)
    require_db
    KEYWORD="${1:-}"
    [[ -n "$KEYWORD" ]] || { print -rn -- '{"error":"missing keyword"}'; print ""; exit 1; }
    ESC_KW="$(sql_escape "$KEYWORD")"
    PAT="%$ESC_KW%"
    TODOS_JSON="$(has_table todoItem && query_json "SELECT id, title, notes, dueDate, isCompleted FROM todoItem WHERE title LIKE '$PAT' OR notes LIKE '$PAT' LIMIT 15;" || print -rn '[]')"
    NOTES_JSON="$(has_table scratchpadNote && query_json "SELECT id, title, content, updatedAt FROM scratchpadNote WHERE title LIKE '$PAT' OR content LIKE '$PAT' LIMIT 15;" || print -rn '[]')"
    LOGS_JSON="$(has_table zentaoSubmission && query_json "SELECT id, date, taskID, hours, work FROM zentaoSubmission WHERE work LIKE '$PAT' ORDER BY date DESC LIMIT 15;" || print -rn '[]')"
    WEEKLY_JSON="$(has_table weeklyReport && query_json "SELECT weekStart, weekEnd, title, substr(content, 1, 240) AS preview FROM weeklyReport WHERE title LIKE '$PAT' OR content LIKE '$PAT' ORDER BY weekStart DESC LIMIT 10;" || print -rn '[]')"
    MONTHLY_JSON="$(has_table monthlyReport && query_json "SELECT monthKey, title, substr(content, 1, 240) AS preview FROM monthlyReport WHERE title LIKE '$PAT' OR content LIKE '$PAT' ORDER BY monthKey DESC LIMIT 10;" || print -rn '[]')"
    ESC_T="$(sql_escape "$TODOS_JSON")"
    ESC_N="$(sql_escape "$NOTES_JSON")"
    ESC_L="$(sql_escape "$LOGS_JSON")"
    ESC_W="$(sql_escape "$WEEKLY_JSON")"
    ESC_M="$(sql_escape "$MONTHLY_JSON")"
    sql_scalar "SELECT json_object('query', '$ESC_KW', 'todos', json('$ESC_T'), 'notes', json('$ESC_N'), 'logs', json('$ESC_L'), 'weeklyReports', json('$ESC_W'), 'monthlyReports', json('$ESC_M'));"
    ;;

  todo-add)
    require_db
    require_write
    has_table todoItem || { print -u2 '{"ok":false,"error":"todoItem table not found"}'; exit 1; }
    TITLE="${1:-}"
    [[ -n "$TITLE" ]] || { print -u2 '{"ok":false,"error":"missing todo title"}'; exit 1; }
    shift
    DUE=""
    PRIORITY=0
    HOURS="1.0"
    NOTES=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --due) DUE="${2:-}"; shift 2 ;;
        --priority) PRIORITY="$(valid_int "${2:-0}" 0)"; shift 2 ;;
        --hours) HOURS="$(valid_number "${2:-1.0}" 1.0)"; shift 2 ;;
        --notes) NOTES="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    UUID="$(/usr/bin/uuidgen)"
    NOW_UTC="$(/bin/date -u '+%Y-%m-%d %H:%M:%S.000')"
    ESC_TITLE="$(sql_escape "$TITLE")"
    ESC_NOTES="$(sql_escape "$NOTES")"
    if [[ -n "$DUE" ]]; then
      ESC_DUE="'"$(sql_escape "$DUE")"'"
    else
      ESC_DUE="NULL"
    fi
    sql_scalar "INSERT INTO todoItem(id, title, notes, dueDate, priority, estimatedHours, isCompleted, createdAt, updatedAt) VALUES ('$UUID', '$ESC_TITLE', '$ESC_NOTES', $ESC_DUE, $PRIORITY, CAST($HOURS AS REAL), 0, '$NOW_UTC', '$NOW_UTC');"
    sql_scalar "SELECT json_object('ok', json('true'), 'id', '$UUID', 'title', '$ESC_TITLE');"
    ;;

  todo-done)
    require_db
    require_write
    has_table todoItem || { print -u2 '{"ok":false,"error":"todoItem table not found"}'; exit 1; }
    PREFIX="${1:-}"
    [[ -n "$PREFIX" ]] || { print -u2 '{"ok":false,"error":"missing todo id prefix"}'; exit 1; }
    ESC_PRE="$(sql_escape "$PREFIX")"
    NOW_UTC="$(/bin/date -u '+%Y-%m-%d %H:%M:%S.000')"
    UPDATED="$(sql_scalar "UPDATE todoItem SET isCompleted = 1, completedAt = '$NOW_UTC', updatedAt = '$NOW_UTC' WHERE id LIKE '$ESC_PRE%' AND isCompleted = 0; SELECT changes();")"
    sql_scalar "SELECT json_object('ok', json('true'), 'updated', $UPDATED);"
    ;;

  note-add)
    require_db
    require_write
    has_table scratchpadNote || { print -u2 '{"ok":false,"error":"scratchpadNote table not found"}'; exit 1; }
    TITLE="${1:-}"
    CONTENT="${2:-}"
    [[ -n "$TITLE" || -n "$CONTENT" ]] || { print -u2 '{"ok":false,"error":"missing note title/content"}'; exit 1; }
    if [[ $# -ge 2 ]]; then
      shift 2
    else
      shift $#
    fi
    PIN=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --pin) PIN=1; shift ;;
        *) shift ;;
      esac
    done
    UUID="$(/usr/bin/uuidgen)"
    NOW_UTC="$(/bin/date -u '+%Y-%m-%d %H:%M:%S.000')"
    ESC_TITLE="$(sql_escape "$TITLE")"
    ESC_CONTENT="$(sql_escape "$CONTENT")"
    sql_scalar "INSERT INTO scratchpadNote(id, title, content, colorTag, isPinned, createdAt, updatedAt) VALUES ('$UUID', '$ESC_TITLE', '$ESC_CONTENT', 'amber', $PIN, '$NOW_UTC', '$NOW_UTC');"
    sql_scalar "SELECT json_object('ok', json('true'), 'id', '$UUID', 'title', '$ESC_TITLE');"
    ;;

  draft-add)
    require_db
    require_write
    has_table zentaoPendingDraft || { print -u2 '{"ok":false,"error":"禅道日志插件尚未初始化数据表"}'; exit 1; }
    WORK="${1:-}"
    [[ -n "$WORK" ]] || { print -u2 '{"ok":false,"error":"missing work content"}'; exit 1; }
    shift
    HOURS="1.0"
    TARGET_DATE="$(date '+%Y-%m-%d')"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --hours) HOURS="$(valid_number "${2:-1.0}" 1.0)"; shift 2 ;;
        --date) TARGET_DATE="${2:-$TARGET_DATE}"; shift 2 ;;
        *) shift ;;
      esac
    done
    UUID="$(/usr/bin/uuidgen)"
    NOW_UTC="$(/bin/date -u '+%Y-%m-%d %H:%M:%S.000')"
    ESC_WORK="$(sql_escape "$WORK")"
    ESC_DATE="$(sql_escape "$TARGET_DATE")"
    FALLBACK_ID="$(sql_scalar "SELECT COALESCE(json_extract(value, '$.v'), '') FROM setting WHERE key = 'zentao.fallbackTaskID';" || true)"
    if [[ "$FALLBACK_ID" =~ '^[0-9]+$' ]]; then
      ENTRY_SQL="json_object('id', '$UUID', 'taskID', $FALLBACK_ID, 'hours', CAST($HOURS AS REAL), 'left', 0.0, 'work', '$ESC_WORK', 'repoPaths', json('[]'), 'commitHashes', json('[]'), 'isFallback', json('true'), 'isOvertime', json('false'), 'isManual', json('true'), 'isRecorded', json('false'))"
    else
      ENTRY_SQL="json_object('id', '$UUID', 'hours', CAST($HOURS AS REAL), 'left', 0.0, 'work', '$ESC_WORK', 'repoPaths', json('[]'), 'commitHashes', json('[]'), 'isFallback', json('false'), 'isOvertime', json('false'), 'isManual', json('true'), 'isRecorded', json('false'))"
    fi
    sql_scalar "INSERT OR REPLACE INTO zentaoPendingDraft(date, payload, updatedAt) VALUES ('$ESC_DATE', json_insert(COALESCE((SELECT payload FROM zentaoPendingDraft WHERE date = '$ESC_DATE'), '[]'), '\$[#]', $ENTRY_SQL), '$NOW_UTC');"
    sql_scalar "SELECT json_object('ok', json('true'), 'date', '$ESC_DATE', 'hours', CAST($HOURS AS REAL), 'work', '$ESC_WORK');"
    ;;

  overtime-set)
    require_db
    require_write
    RAW_HOURS="${1:-}"
    [[ -n "$RAW_HOURS" ]] || { print -u2 '{"ok":false,"error":"missing hours"}'; exit 1; }
    shift
    HOURS="$(valid_number "$RAW_HOURS" 0)"
    TARGET_DATE="$(date '+%Y-%m-%d')"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --date) TARGET_DATE="${2:-$TARGET_DATE}"; shift 2 ;;
        *) shift ;;
      esac
    done
    NOW_UTC="$(/bin/date -u '+%Y-%m-%d %H:%M:%S.000')"
    ESC_DATE="$(sql_escape "$TARGET_DATE")"
    IS_POSITIVE="$(/usr/bin/awk "BEGIN { print ($HOURS > 0 ? 1 : 0) }")"
    if [[ "$IS_POSITIVE" == "1" ]]; then
      sql_scalar "INSERT OR REPLACE INTO dailyOvertime(date, hours, updatedAt) VALUES ('$ESC_DATE', CAST($HOURS AS REAL), '$NOW_UTC');"
    else
      sql_scalar "DELETE FROM dailyOvertime WHERE date = '$ESC_DATE';"
    fi
    sql_scalar "SELECT json_object('ok', json('true'), 'date', '$ESC_DATE', 'hours', CAST($HOURS AS REAL));"
    ;;

  *)
    print -u2 "{\"ok\":false,\"error\":\"unknown command\",\"command\":\"$(sql_escape "$SUBCMD")\"}"
    exit 1
    ;;
esac
"""#
}
