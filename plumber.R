# plumber.R — R 코드 실행 API 서버

library(plumber)
library(jsonlite)

# ── CORS 설정 (GitHub Pages에서 호출 허용) ──────────────────
#* @filter cors
function(req, res) {
  res$setHeader("Access-Control-Allow-Origin", "*")
  res$setHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
  res$setHeader("Access-Control-Allow-Headers", "Content-Type")
  if (req$REQUEST_METHOD == "OPTIONS") {
    res$status <- 200
    return(list())
  }
  plumber::forward()
}

# ── 헬스 체크 ────────────────────────────────────────────────
#* @get /health
function() {
  list(status = "ok", time = Sys.time())
}

# ── R 코드 실행 엔드포인트 ───────────────────────────────────
#* @post /run
#* @param code R 코드 문자열
function(req) {

  body <- jsonlite::fromJSON(req$postBody)
  code <- body$code

  # 위험한 명령어 차단
  blocked <- c(
    "system\\(", "shell\\(", "system2\\(",
    "unlink\\(", "file\\.remove\\(",
    "Sys\\.setenv\\(", "Sys\\.getenv\\(",
    "readLines\\(.*http", "download\\.file\\(",
    "source\\(", "eval\\(parse"
  )
  for (pattern in blocked) {
    if (grepl(pattern, code, ignore.case = TRUE)) {
      return(list(
        success = FALSE,
        output  = "",
        error   = paste0("보안 정책상 허용되지 않는 함수가 포함되어 있어요: ", pattern)
      ))
    }
  }

  # 실행 시간 제한: 30초
  output_text <- ""
  error_text  <- ""
  success     <- TRUE

  tryCatch({
    # stdout/stderr 캡처
    output_text <- paste(
      capture.output(
        withCallingHandlers(
          eval(parse(text = code), envir = new.env(parent = globalenv())),
          message = function(m) {
            output_text <<- paste0(output_text, conditionMessage(m))
            invokeRestart("muffleMessage")
          }
        )
      ),
      collapse = "\n"
    )
  }, error = function(e) {
    success    <<- FALSE
    error_text <<- conditionMessage(e)
  }, warning = function(w) {
    output_text <<- paste0(output_text, "\n경고: ", conditionMessage(w))
  })

  list(
    success = success,
    output  = output_text,
    error   = error_text
  )
}
