# plumber.R — R 코드 실행 + 학습 추적 API

library(plumber)
library(jsonlite)
library(DBI)
library(RSQLite)

# ── DB 초기화 ────────────────────────────────────────────────
DB_PATH <- "/app/data/tracking.db"
dir.create("/app/data", showWarnings = FALSE, recursive = TRUE)

init_db <- function() {
  con <- dbConnect(SQLite(), DB_PATH)
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
  dbDisconnect(con)
}
init_db()

get_db <- function() dbConnect(SQLite(), DB_PATH)

# ── CORS ─────────────────────────────────────────────────────
#* @filter cors
function(req, res) {
  res$setHeader("Access-Control-Allow-Origin", "*")
  res$setHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
  res$setHeader("Access-Control-Allow-Headers", "Content-Type")
  if (req$REQUEST_METHOD == "OPTIONS") { res$status <- 200; return(list()) }
  plumber::forward()
}

# ── 헬스 체크 ────────────────────────────────────────────────
#* @get /health
function() list(status = "ok", time = format(Sys.time()))

# ── R 코드 실행 ──────────────────────────────────────────────
#* @post /run
function(req) {
  body <- jsonlite::fromJSON(req$postBody)
  code <- body$code

  blocked <- c("system\\(","shell\\(","system2\\(","unlink\\(","file\\.remove\\(",
               "Sys\\.setenv\\(","readLines\\(.*http","download\\.file\\(",
               "source\\(","eval\\(parse")
  for (p in blocked) {
    if (grepl(p, code, ignore.case = TRUE))
      return(list(success = FALSE, output = "", error = paste0("허용되지 않는 함수: ", p)))
  }

  output_text <- ""; error_text <- ""; success <- TRUE
  tryCatch({
    output_text <- paste(
      capture.output(
        withCallingHandlers(
          eval(parse(text = code), envir = new.env(parent = globalenv())),
          message = function(m) {
            output_text <<- paste0(output_text, conditionMessage(m))
            invokeRestart("muffleMessage")
          }
        )
      ), collapse = "\n")
  }, error   = function(e) { success <<- FALSE; error_text <<- conditionMessage(e) },
     warning = function(w) { output_text <<- paste0(output_text, "\n경고: ", conditionMessage(w)) })

  list(success = success, output = output_text, error = error_text)
}

# ── 학습 이벤트 추적 ─────────────────────────────────────────
#* @post /track
function(req) {
  body <- tryCatch(jsonlite::fromJSON(req$postBody), error = function(e) NULL)
  if (is.null(body)) return(list(success = FALSE))

  con <- get_db()
  on.exit(dbDisconnect(con))

  dbExecute(con,
    "INSERT INTO events (nickname, session, step_idx, step_title, event_type, attempt, time_spent)
     VALUES (?, ?, ?, ?, ?, ?, ?)",
    params = list(
      body$nickname   %||% "anonymous",
      body$session    %||% "default",
      body$step_idx   %||% 0L,
      body$step_title %||% "",
      body$event_type %||% "attempt",
      body$attempt    %||% 1L,
      body$time_spent %||% 0
    )
  )
  list(success = TRUE)
}

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0) a else b

# ── 대시보드 데이터 ──────────────────────────────────────────
#* @get /dashboard/data
#* @param session 세션명 (optional)
function(session = NULL) {
  con <- get_db()
  on.exit(dbDisconnect(con))

  where <- if (!is.null(session) && nchar(session) > 0)
    paste0("WHERE session = '", gsub("'", "''", session), "'") else ""

  # 전체 참여 학생 수
  total_students <- dbGetQuery(con,
    paste("SELECT COUNT(DISTINCT nickname) as n FROM events", where))$n

  # 단계별 완료율
  step_completion <- dbGetQuery(con, paste("
    SELECT step_idx, step_title,
           COUNT(DISTINCT nickname) as completed,
           AVG(attempt) as avg_attempts,
           AVG(time_spent) as avg_time
    FROM events
    WHERE event_type = 'complete'", if (nchar(where) > 0) paste("AND", sub("WHERE ", "", where)) else "", "
    GROUP BY step_idx, step_title
    ORDER BY step_idx
  "))

  # 전체 진척도 상위 10명
  leaderboard <- dbGetQuery(con, paste("
    SELECT nickname,
           COUNT(DISTINCT step_idx) as steps_completed,
           MIN(timestamp) as first_seen,
           MAX(timestamp) as last_seen
    FROM events
    WHERE event_type = 'complete'", if (nchar(where) > 0) paste("AND", sub("WHERE ", "", where)) else "", "
    GROUP BY nickname
    ORDER BY steps_completed DESC, last_seen ASC
    LIMIT 10
  "))

  # 현재 접속 중 (최근 3분 이내 이벤트)
  active_now <- dbGetQuery(con, paste("
    SELECT COUNT(DISTINCT nickname) as n FROM events
    WHERE timestamp >= datetime('now', '-3 minutes')",
    if (nchar(where) > 0) paste("AND", sub("WHERE ", "", where)) else ""
  ))$n

  list(
    total_students  = total_students,
    active_now      = active_now,
    step_completion = step_completion,
    leaderboard     = leaderboard,
    updated_at      = format(Sys.time())
  )
}

# ── CSV 내보내기 ─────────────────────────────────────────────
#* @get /export
#* @serializer csv
function() {
  con <- get_db()
  on.exit(dbDisconnect(con))
  dbGetQuery(con, "SELECT * FROM events ORDER BY timestamp")
}
