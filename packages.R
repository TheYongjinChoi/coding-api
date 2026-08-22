# packages.R — 서버 시작 시 미리 로드해 두는 패키지
# (학생 코드의 library() 호출을 빠르게 만들기 위한 워밍업)

suppressPackageStartupMessages({
  # 공통
  library(dplyr)
  library(tidyr)
  library(tibble)
  library(ggplot2)
  library(stringr)
  library(purrr)
  library(broom)

  # 1강: 워크플로 + 정규화 회귀
  library(glmnet)

  # 3강: 트리 · 앙상블
  library(rpart)
  library(rpart.plot)
  library(ranger)
  library(randomForest)
  library(xgboost)

  # 인과 ML (기존 실습 유지)
  library(MatchIt)
  library(DoubleML)
  library(grf)
  library(mlr3)
  library(mlr3learners)

  # 그래프 캡처
  library(ragg)
})

# 2강: 신경망 (Keras). 이미지에 텐서플로가 포함된 경우에만 로드합니다.
if (nzchar(Sys.getenv("ENABLE_KERAS")) && requireNamespace("keras3", quietly = TRUE)) {
  suppressPackageStartupMessages(library(keras3))
}

# 그래프에서 한글이 깨지지 않도록 기본 폰트 지정
if (any(grepl("Nanum", systemfonts::system_fonts()$family))) {
  ggplot2::theme_set(ggplot2::theme_gray(base_family = "NanumGothic"))
  grDevices::pdf.options(family = "NanumGothic")
}
