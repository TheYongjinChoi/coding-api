FROM rocker/r-ver:4.3.2

RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libgit2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN R -e "install.packages('pak', repos='https://r-lib.github.io/p/pak/stable/')"

RUN R -e "pak::pkg_install(c(\
    'plumber', \
    'dplyr', \
    'tidyr', \
    'ggplot2', \
    'stringr', \
    'purrr', \
    'broom', \
    'MatchIt', \
    'DoubleML', \
    'grf', \
    'glmnet', \
    'ranger', \
    'xgboost', \
    'mlr3', \
    'mlr3learners', \
    'jsonlite' \
))"

WORKDIR /app
COPY plumber.R .
COPY packages.R .

EXPOSE 8000

CMD ["Rscript", "-e", "pr <- plumber::plumb('plumber.R'); pr$run(host='0.0.0.0', port=8000)"]
