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

# ── R 패키지 (P3M 바이너리 사용: 설치가 훨씬 빠릅니다) ──────
RUN R -q -e "install.packages(c( \
      'plumber','jsonlite','DBI','RSQLite', \
      'dplyr','tidyr','tibble','ggplot2','stringr','purrr','broom', \
      'glmnet', \
      'rpart','rpart.plot','ranger','randomForest','xgboost', \
      'MatchIt','DoubleML','grf','mlr3','mlr3learners', \
      'ragg','systemfonts','evaluate' \
    ), repos = 'https://packagemanager.posit.co/cran/__linux__/jammy/latest')"

# ── (선택) Keras / TensorFlow ────────────────────────────────
RUN if [ "$ENABLE_KERAS" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends python3 python3-pip python3-venv && \
      rm -rf /var/lib/apt/lists/* && \
      R -q -e "install.packages(c('keras3','reticulate'), repos='https://packagemanager.posit.co/cran/__linux__/jammy/latest')" && \
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
