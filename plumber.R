# ============================================================
# plumber.R — R 코드 실행 + 채점 + 학습 추적 API
#
#  변경 요약 (v2)
#   1. /init      : 수강자별 R 세션 환경 생성(단계 간 객체 유지) + tracker 로드
#   2. /run       : 같은 환경에서 실행, 모든 최상위 표현식 자동 출력, 그래프 다중 캡처
#   3. /check     : tracker의 check("id")를 서버에서 실행해 정답 여부/힌트 반환
#   4. /reset     : 세션 환경 초기화
#   5. tracker가 없는 실습(예: ensemble)은 /check 가 available=FALSE 를 돌려주고
#      프런트엔드가 자체 채점으로 자동 전환합니다.
# ============================================================

library(plumber)
library(jsonlite)
library(DBI)
library(RSQLite)
library(evaluate)

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0 && !is.na(a[1])) a else b

DATA_DIR    <- Sys.getenv("DATA_DIR", "/app/data")
TRACKER_DIR <- file.path(DATA_DIR, "trackers")
DB_PATH     <- file.path(DATA_DIR, "tracking.db")
dir.create(DATA_DIR,    showWarnings = FALSE, recursive = TRUE)
dir.create(TRACKER_DIR, showWarnings = FALSE, recursive = TRUE)

MAX_SESSIONS <- as.integer(Sys.getenv("MAX_SESSIONS", "60"))
SESSION_TTL  <- as.integer(Sys.getenv("SESSION_TTL",  "5400"))   # 90분
TIME_LIMIT   <- as.numeric(Sys.getenv("RUN_TIME_LIMIT", "150"))  # 코드 1회 실행 제한(초)

# ── DB ───────────────────────────────────────────────────────
init_db <- function() {
  con <- dbConnect(SQLite(), DB_PATH)
  on.exit(dbDisconnect(con))
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS events (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      nickname    TEXT    NOT NULL,
      session     TEXT    NOT NULL,
      step_idx    INTEGER NOT NULL,
      step_title  TEXT,
      event_type  TEXT    NOT NULL,
      attempt     INTEGER DEFAULT 1,
      time_spent  REAL    DEFAULT 0,
      timestamp   TEXT    DEFAULT (datetime('now'))
    )
  ")
  # 기존 배포본에 없는 열은 여기서 추가 (재배포 시 데이터 유지)
  have <- dbGetQuery(con, "PRAGMA table_info(events)")$name
  for (col in c("sid", "check_id", "passed")) {
    if (!col %in% have) {
      type <- if (col == "passed") "INTEGER" else "TEXT"
      try(dbExecute(con, sprintf("ALTER TABLE events ADD COLUMN %s %s", col, type)), silent = TRUE)
    }
  }
}
init_db()
get_db <- function() dbConnect(SQLite(), DB_PATH)

# ── 수강자별 R 세션 환경 ─────────────────────────────────────
SESSIONS <- new.env(parent = emptyenv())

session_key <- function(sid, session) paste0(session, "::", sid)

gc_sessions <- function() {
  keys <- ls(SESSIONS)
  if (!length(keys)) return(invisible())
  now  <- as.numeric(Sys.time())
  for (k in keys) {
    if (now - SESSIONS[[k]]$touched > SESSION_TTL) rm(list = k, envir = SESSIONS)
  }
  keys <- ls(SESSIONS)
  if (length(keys) > MAX_SESSIONS) {
    ages <- vapply(keys, function(k) SESSIONS[[k]]$touched, numeric(1))
    rm(list = keys[order(ages)][seq_len(length(keys) - MAX_SESSIONS)], envir = SESSIONS)
  }
  invisible()
}

new_user_env <- function() {
  env <- new.env(parent = globalenv())
  # 실습 데이터 경로 헬퍼: 학생 코드에서 DATA("ohie_all6m.rds") 로 사용
  assign("DATA", function(file) file.path(DATA_DIR, file), envir = env)
  env
}

# tracker 스크립트를 받아 세션 환경에 source
load_tracker <- function(env, tracker_url) {
  if (is.null(tracker_url) || !nzchar(tracker_url)) return(FALSE)
  cache <- file.path(TRACKER_DIR, paste0(substr(digest_url(tracker_url), 1, 16), ".R"))
  if (!file.exists(cache)) {
    ok <- tryCatch({
      utils::download.file(tracker_url, cache, quiet = TRUE, mode = "wb"); TRUE
    }, error = function(e) FALSE)
    if (!ok) return(FALSE)
  }
  tryCatch({ sys.source(cache, envir = env); TRUE }, error = function(e) FALSE)
}

digest_url <- function(x) {
  # 외부 의존성 없이 URL을 파일명으로 바꾸는 간단한 해시
  paste0(sum(utf8ToInt(x)), "-", nchar(x), "-", gsub("[^A-Za-z0-9]", "", substr(basename(x), 1, 20)))
}

get_session <- function(sid, session, tracker = NULL, student = NULL, create = TRUE) {
  gc_sessions()
  k <- session_key(sid %||% "anonymous", session %||% "default")
  fresh <- FALSE
  if (!exists(k, envir = SESSIONS, inherits = FALSE)) {
    if (!create) return(NULL)
    env <- new_user_env()
    has_tracker <- load_tracker(env, tracker)
    if (has_tracker && !is.null(student) && exists("set_student", envir = env, inherits = FALSE)) {
      try(eval(call("set_student", as.character(student)), envir = env), silent = TRUE)
    }
    assign(k, list(env = env, tracker = isTRUE(has_tracker),
                   touched = as.numeric(Sys.time())), envir = SESSIONS)
    fresh <- TRUE
  }
  s <- SESSIONS[[k]]
  s$touched <- as.numeric(Sys.time())
  assign(k, s, envir = SESSIONS)
  list(env = s$env, tracker = s$tracker, fresh = fresh, key = k)
}

# 기록된 그래프를 PNG로 다시 그려 base64 문자열로 반환
render_plot <- function(p) {
  f <- tempfile(fileext = ".png")
  if (requireNamespace("ragg", quietly = TRUE)) {
    ragg::agg_png(f, width = 1000, height = 620, res = 130)
  } else {
    grDevices::png(f, width = 1000, height = 620, res = 130, type = "cairo")
  }
  ok <- tryCatch({ grDevices::replayPlot(p); TRUE }, error = function(e) FALSE)
  try(grDevices::dev.off(), silent = TRUE)
  if (!ok || !file.exists(f)) return(NULL)
  on.exit(unlink(f), add = TRUE)
  jsonlite::base64_enc(readBin(f, "raw", file.info(f)$size))
}

# ── CORS ─────────────────────────────────────────────────────
#* @filter cors
function(req, res) {
  res$setHeader("Access-Control-Allow-Origin",  "*")
  res$setHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
  res$setHeader("Access-Control-Allow-Headers", "Content-Type")
  if (req$REQUEST_METHOD == "OPTIONS") { res$status <- 200; return(list()) }
  plumber::forward()
}

# ── 헬스 체크 ────────────────────────────────────────────────
#* @get /health
#* @serializer unboxedJSON
function() {
  list(status = "ok", time = format(Sys.time()),
       sessions = length(ls(SESSIONS)),
       data = list.files(DATA_DIR, pattern = "\\.rds$"))
}

# ── 세션 시작 ────────────────────────────────────────────────
#* @post /init
#* @serializer unboxedJSON
function(req) {
  body <- tryCatch(fromJSON(req$postBody), error = function(e) NULL)
  if (is.null(body)) return(list(success = FALSE, error = "잘못된 요청입니다."))
  s <- get_session(body$sid, body$session, body$tracker, body$student)
  list(success = TRUE, tracker = s$tracker, fresh = s$fresh)
}

# ── 세션 초기화 ──────────────────────────────────────────────
#* @post /reset
#* @serializer unboxedJSON
function(req) {
  body <- tryCatch(fromJSON(req$postBody), error = function(e) NULL)
  k <- session_key(body$sid %||% "anonymous", body$session %||% "default")
  if (exists(k, envir = SESSIONS, inherits = FALSE)) rm(list = k, envir = SESSIONS)
  list(success = TRUE)
}

# ── 허용되지 않는 코드 ───────────────────────────────────────
BLOCKED <- c("system\\(", "shell\\(", "system2\\(", "unlink\\(", "file\\.remove\\(",
             "Sys\\.setenv\\(", "download\\.file\\(", "source\\(", "eval\\(parse",
             "install\\.packages\\(", "file\\.rename\\(", "q\\(\\)", "quit\\(")

# ── R 코드 실행 ──────────────────────────────────────────────
#* @post /run
#* @serializer unboxedJSON
function(req) {
  body <- tryCatch(fromJSON(req$postBody), error = function(e) NULL)
  if (is.null(body) || is.null(body$code))
    return(list(success = FALSE, output = "", error = "코드가 비어 있습니다.", plots = list()))

  # 서버 내부에서 예상치 못한 오류가 나도 500 대신 메시지를 돌려줍니다.
  tryCatch(do_run(body), error = function(e) {
    msg <- conditionMessage(e)
    message("[/run 내부 오류] ", msg)
    list(success = FALSE, output = "", plots = list(),
         error = paste0("서버 내부 오류: ", msg))
  })
}

do_run <- function(body) {
  code <- body$code
  for (p in BLOCKED) {
    if (grepl(p, code)) {
      return(list(success = FALSE, output = "", plots = list(),
                  error = paste0("허용되지 않는 함수입니다: ", gsub("\\\\", "", p))))
    }
  }
  if (grepl("_____", code, fixed = TRUE)) {
    return(list(success = FALSE, output = "", plots = list(),
                error = "빈칸(_____)이 남아 있습니다. 모두 채운 뒤 실행하세요."))
  }

  s   <- get_session(body$sid, body$session, body$tracker, body$student)
  env <- s$env

  old <- options(width = 100)
  setTimeLimit(elapsed = TIME_LIMIT, transient = TRUE)
  on.exit({
    options(old)
    setTimeLimit(elapsed = Inf, transient = TRUE)
    try(while (grDevices::dev.cur() > 1) grDevices::dev.off(), silent = TRUE)
  }, add = TRUE)

  # evaluate: 표현식마다 출력·경고·그래프를 순서대로 잡아 줍니다.
  # 중간에 오류가 나도 그 전까지의 출력은 그대로 학생에게 보여 줍니다.
  res <- evaluate::evaluate(
    code, envir = env, stop_on_error = 1L,
    new_device = TRUE, keep_message = TRUE, keep_warning = TRUE
  )

  output_text <- character()
  error_text  <- ""
  success     <- TRUE
  plots       <- list()

  for (item in res) {
    if (is.character(item)) {
      output_text <- c(output_text, item)
    } else if (inherits(item, "recordedplot")) {
      img <- render_plot(item)
      if (!is.null(img)) plots[[length(plots) + 1]] <- img
    } else if (inherits(item, "error")) {
      success <- FALSE
      error_text <- conditionMessage(item)
    } else if (inherits(item, "warning")) {
      output_text <- c(output_text, paste0("경고: ", conditionMessage(item), "\n"))
    } else if (inherits(item, "message")) {
      output_text <- c(output_text, conditionMessage(item))
    }
  }

  list(success = success,
       output  = paste(output_text, collapse = ""),
       error   = error_text,
       plots   = plots,
       fresh   = s$fresh)
}

# ── 정답 확인 (tracker 연동) ─────────────────────────────────
#* @post /check
#* @serializer unboxedJSON
function(req) {
  body <- tryCatch(fromJSON(req$postBody), error = function(e) NULL)
  if (is.null(body) || is.null(body$check_id))
    return(list(available = FALSE))

  s <- get_session(body$sid, body$session, body$tracker, body$student, create = FALSE)
  if (is.null(s) || !exists("check", envir = s$env, inherits = FALSE))
    return(list(available = FALSE))

  txt <- tryCatch(
    paste(utils::capture.output(eval(call("check", as.character(body$check_id)), envir = s$env)),
          collapse = "\n"),
    error = function(e) paste0("채점 함수 오류: ", conditionMessage(e))
  )

  passed <- grepl("\u2705", txt) || grepl("정답입니다", txt)
  failed <- grepl("\u274c", txt) || grepl("다시 확인", txt)
  list(available = TRUE,
       passed    = isTRUE(passed) && !isTRUE(failed),
       feedback  = txt)
}

# ── 학습 이벤트 추적 ─────────────────────────────────────────
#* @post /track
#* @serializer unboxedJSON
function(req) {
  body <- tryCatch(fromJSON(req$postBody), error = function(e) NULL)
  if (is.null(body)) return(list(success = FALSE))

  con <- get_db(); on.exit(dbDisconnect(con))
  dbExecute(con,
    "INSERT INTO events (nickname, session, step_idx, step_title, event_type,
                         attempt, time_spent, sid, check_id, passed)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    params = list(
      body$nickname   %||% "anonymous",
      body$session    %||% "default",
      body$step_idx   %||% 0L,
      body$step_title %||% "",
      body$event_type %||% "attempt",
      body$attempt    %||% 1L,
      body$time_spent %||% 0,
      body$sid        %||% "",
      body$check_id   %||% "",
      as.integer(isTRUE(body$passed))
    )
  )
  list(success = TRUE)
}

# ── 대시보드 데이터 ──────────────────────────────────────────
#* @get /dashboard/data
#* @serializer unboxedJSON
#* @param session 세션명 (optional)
function(session = NULL) {
  con <- get_db(); on.exit(dbDisconnect(con))

  filt <- if (!is.null(session) && nchar(session) > 0)
    paste0(" AND session = '", gsub("'", "''", session), "'") else ""

  total_students <- dbGetQuery(con, paste0(
    "SELECT COUNT(DISTINCT nickname) AS n FROM events WHERE 1=1", filt))$n

  step_completion <- dbGetQuery(con, paste0("
    SELECT session, step_idx, step_title,
           COUNT(DISTINCT nickname) AS completed,
           AVG(attempt)             AS avg_attempts,
           AVG(time_spent)          AS avg_time
    FROM events WHERE event_type = 'complete'", filt, "
    GROUP BY session, step_idx, step_title
    ORDER BY session, step_idx"))

  leaderboard <- dbGetQuery(con, paste0("
    SELECT nickname,
           COUNT(DISTINCT session || '-' || step_idx) AS steps_completed,
           MIN(timestamp) AS first_seen,
           MAX(timestamp) AS last_seen
    FROM events WHERE event_type = 'complete'", filt, "
    GROUP BY nickname
    ORDER BY steps_completed DESC, last_seen ASC
    LIMIT 20"))

  active_now <- dbGetQuery(con, paste0("
    SELECT COUNT(DISTINCT nickname) AS n FROM events
    WHERE timestamp >= datetime('now', '-3 minutes')", filt))$n

  list(total_students  = total_students,
       active_now      = active_now,
       step_completion = step_completion,
       leaderboard     = leaderboard,
       updated_at      = format(Sys.time()))
}

# ── CSV 내보내기 ─────────────────────────────────────────────
#  plumber 의 @serializer csv 는 readr 을 요구합니다. 그 패키지 하나를
#  더 넣으면 이미지 빌드가 길어지므로 base R 의 write.csv 로 직접 만듭니다.
#* @get /export
#* @serializer contentType list(type="text/csv; charset=UTF-8")
function(res) {
  con <- get_db(); on.exit(dbDisconnect(con))
  d <- dbGetQuery(con, "SELECT * FROM events ORDER BY timestamp")

  out <- character()
  tc <- textConnection("out", "w", local = TRUE)
  utils::write.csv(d, tc, row.names = FALSE)
  close(tc)

  res$setHeader("Content-Disposition", "attachment; filename=events.csv")
  charToRaw(paste0(paste(out, collapse = "\n"), "\n"))
}
