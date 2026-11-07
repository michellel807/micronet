# syntax=docker/dockerfile:1
FROM ghcr.io/astral-sh/uv:0.13.6 AS uv
FROM ruby:4.0.9-slim-trixie AS deps

WORKDIR /app
RUN apt-get update && apt-get -y upgrade && \
    apt-get install -y --no-install-recommends build-essential git ca-certificates \
      libpq-dev libyaml-dev fonts-dejavu-core && \
    rm -rf /var/lib/apt/lists/*
# RNA-seq differential expression (lib/scripts/rnaseq) runs DESeq2 in R. Debian's
# prebuilt Bioconductor packages need no compiler, so they survive the
# production stage's removal of build tools.
RUN apt-get update && \
    apt-get install -y --no-install-recommends r-base-core r-bioc-deseq2 r-cran-jsonlite && \
    rm -rf /var/lib/apt/lists/*
COPY --from=uv /uv /usr/local/bin/uv
# AMIGA requires Python <3.13. Use a maintained 3.12 patch release.
ENV UV_PYTHON_INSTALL_DIR=/opt/python UV_LINK_MODE=copy UV_NO_CACHE=1
RUN uv python install 3.12 && uv venv --python 3.12 /opt/uvenv
ENV PATH="/opt/uvenv/bin:${PATH}"

ENV RAILS_LOG_TO_STDOUT=1
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY requirements.txt ./
RUN uv pip sync --require-hashes requirements.txt
COPY . /app

FROM deps AS production
# Build tools and headers are unnecessary in the deployed container.
RUN apt-mark manual libpq5 libyaml-0-2 r-base-core r-bioc-deseq2 r-cran-jsonlite && \
    apt-get purge -y --auto-remove build-essential gcc g++ libpq-dev libyaml-dev git && \
    rm -rf /var/lib/apt/lists/*
# Fail the build if removing build tools took the RNA-seq R runtime with it.
RUN Rscript -e 'suppressPackageStartupMessages({library(DESeq2); library(jsonlite)})'
# The application does not need privileged OS helper executables.
RUN find / -xdev -type f -perm /6000 -exec chmod a-s {} +
# The locked json gem supersedes Ruby's vulnerable bundled default. Remove the
# obsolete implementation too, rather than leave a second copy in the image.
RUN ruby -rjson -rrbconfig -rfileutils -e 'abort "Upgrade the locked json gem" if Gem.loaded_specs.fetch("json").version < Gem::Version.new("2.19.2"); %w[json.rb json].each { |name| FileUtils.rm_rf(File.join(RbConfig::CONFIG.fetch("rubylibdir"), name)) }; FileUtils.rm_rf(File.join(RbConfig::CONFIG.fetch("archdir"), "json")); Dir[File.join(Gem.default_dir, "specifications/default/json-*.gemspec")].each { |path| FileUtils.rm_f(path) }'
# uv manages this environment; the interpreter's bundled pip/ensurepip is unused.
RUN python -c 'import pathlib, shutil, sys; base = pathlib.Path(sys.base_prefix); lib = base / "lib/python3.12"; [shutil.rmtree(p) for p in (lib / "site-packages").glob("pip*") if p.is_dir()]; shutil.rmtree(lib / "ensurepip", ignore_errors=True); [p.unlink() for p in (base / "bin").glob("pip*") if p.is_file()]'
ENV RAILS_ENV=production RAILS_LOG_TO_STDOUT=1 RAILS_SERVE_STATIC_FILES=1
RUN mkdir -p /okd_user_home tmp/pids tmp/cache private/uploads && \
    chgrp -R 0 /okd_user_home tmp private/uploads && \
    chmod -R g+rwX /okd_user_home tmp private/uploads
ENV HOME=/okd_user_home
RUN SKIP_VAULT=true SKIP_VALIDATION=true SECRET_KEY_BASE=fakeassetbuildersecret bundle exec rake assets:precompile
# Compatible with an arbitrary UID supplied by OpenShift, and non-root elsewhere.
USER 1001:0
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
