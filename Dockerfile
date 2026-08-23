# ============================================================
#  coding-api — R 실습 실행 서버
#  build:  docker build -t coding-api .
#  Keras까지 포함하려면:  docker build --build-arg ENABLE_KERAS=true .
#  (Keras/TensorFlow는 이미지가 3GB 이상으로 커지고 메모리를 많이 씁니다.
#   Render 무료 플랜(512MB)에서는 동작하지 않으니 별도 인스턴스를 권장합니다.)
# ============================================================
FROM rocker/r-ver:4.4.2

ARG ENABLE_KERAS=false

RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev libssl-dev libxml2-dev libgit2-dev \
    libpng-dev libjpeg-dev libtiff5-dev \
    libfreetype6-dev libfribidi-dev libharfbuzz-dev \
    libfontconfig1-dev libcairo2-dev \
    fonts-nanum fontconfig \
    && fc-cache -f \
    && rm -rf /var/lib/apt/lists/*

# ── R 패키지 ────────────────────────────────────────────────
#  repos 를 지정하지 않습니다. rocker 이미지가 자기 OS(noble)에 맞는
#  P3M 바이너리 저장소를 기본 CRAN 으로 이미 설정해 두기 때문입니다.
#  여기에 jammy 등 다른 배포판을 직접 적으면 stringi 가 libicui18n.so.70 을
#  찾다가 실행 시점에 죽습니다.
RUN R -q -e "install.packages(c( \
      'plumber','jsonlite','DBI','RSQLite', \
      'dplyr','tidyr','tibble','ggplot2','stringr','purrr','broom', \
      'glmnet', \
      'rpart','rpart.plot','ranger','randomForest','xgboost', \
      'MatchIt','DoubleML','grf','mlr3','mlr3learners', \
      'ragg','systemfonts','evaluate','httr2' \
    ))" \
 && R -q -e "pkgs <- c('plumber','jsonlite','DBI','RSQLite','dplyr','ggplot2','stringr','glmnet','rpart','ranger','randomForest','xgboost','ragg','evaluate','httr2'); \
             miss <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]; \
             if (length(miss)) stop('설치 실패: ', paste(miss, collapse=', ')); \
             invisible(lapply(pkgs, library, character.only = TRUE)); \
             cat('모든 패키지 로드 확인 완료\n')"

# ── (선택) Keras / TensorFlow ────────────────────────────────
RUN if [ "$ENABLE_KERAS" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends python3 python3-pip python3-venv && \
      rm -rf /var/lib/apt/lists/* && \
      R -q -e "install.packages(c('keras3','reticulate'))" && \
      python3 -m venv /opt/venv && \
      /opt/venv/bin/pip install --no-cache-dir 'tensorflow-cpu==2.16.*' ; \
    fi
ENV RETICULATE_PYTHON=/opt/venv/bin/python
ENV ENABLE_KERAS=${ENABLE_KERAS}

WORKDIR /app
RUN mkdir -p /app/data/trackers

# ── 실습 데이터를 이미지에 미리 넣어 둡니다 ─────────────────
#  학생 코드에서는 DATA("ohie_all6m.rds") 로 접근합니다.
ADD https://raw.githubusercontent.com/TheYongjinChoi/kapae2026-exercise/main/ohie_all6m.rds /app/data/ohie_all6m.rds
RUN chmod 644 /app/data/ohie_all6m.rds

COPY plumber.R .
COPY packages.R .

ENV DATA_DIR=/app/data
ENV LANG=C.UTF-8
EXPOSE 8000

CMD ["Rscript", "-e", "source('packages.R'); pr <- plumber::plumb('plumber.R'); pr$run(host='0.0.0.0', port=as.integer(Sys.getenv('PORT','8000')))"]
