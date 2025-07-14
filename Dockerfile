# Use the official Ruby image as base
FROM ruby:3.2.2 as deps

# Set the working directory
WORKDIR /app

# Install dependencies
RUN apt-get update && apt-get -y upgrade && \
    apt-get install -y nodejs && \
    apt-get install -y --no-install-recommends \
    git \
    wget \
    g++ \
    gcc \
    ca-certificates \
    ghostscript \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/miniconda3/bin:${PATH}"
ARG PATH="/miniconda3/bin:${PATH}"
RUN arch=$(uname -m) && \
    if [ "$arch" = "x86_64" ]; then \
      wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O miniconda.sh; \
    else \
      wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh -O miniconda.sh; \
    fi && \
    mkdir /root/.conda && \
    bash miniconda.sh -b -u -p /miniconda3 && \
    rm miniconda.sh && \
    echo "Running $(/miniconda3/bin/conda --version)"

COPY amigacondaenv.yml ./
RUN conda env create -f ./amigacondaenv.yml
ENV CONDA_DEFAULT_ENV=amiga
ENV PATH="/miniconda3/envs/amigacondaenv/bin:${PATH}"

RUN sed -i 's|<policy domain="coder" rights="none" pattern="PDF" />||' /etc/ImageMagick-6/policy.xml

ENV RAILS_LOG_TO_STDOUT=1

# Copy Gemfile and Gemfile.lock into the image and install dependencies
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Copy the rest of the application code into the image
COPY . /app

FROM deps

ENV RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=1 \
    RAILS_SERVE_STATIC_FILES=1

# Set a home directory to silence bundler in console warnings
RUN mkdir -p /okd_user_home \
    && chgrp -R 0 /okd_user_home \
    && chmod -R g+rwxs /okd_user_home
ENV HOME=/okd_user_home

# Allow writing to the Rails tmp directory
RUN mkdir -p tmp/pids \
    && mkdir -p tmp/cache \
    && chgrp -R 0 tmp \
    && chmod -R g+rwxs tmp

COPY . /app

RUN SKIP_VAULT=true SKIP_VALIDATION=true SECRET_KEY_BASE=fakeassetbuildersecret bundle exec rake assets:precompile

# Command to run the Rails server
CMD ["rails", "server", "-b", "0.0.0.0"]
