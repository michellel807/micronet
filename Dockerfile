# Use the official Ruby image as base
FROM image-mirror-prod-registry.cloud.duke.edu/library/ruby:3.2.2 as deps

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
    python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Create a Python virtual environment and install uv inside it
RUN python3 -m venv /opt/python-base && \
    /opt/python-base/bin/pip install --upgrade pip && \
    /opt/python-base/bin/pip install uv

# Ensure uv is on PATH for all following commands
ENV PATH="/opt/python-base/bin:${PATH}"

# Create virtual environment with uv and install amiga
RUN uv venv /opt/uvenv && \
    cp /opt/python-base/bin/uv /opt/uvenv/bin/ && \
    /opt/uvenv/bin/uv pip install amiga==3.0.4

ENV PATH="/opt/uvenv/bin:${PATH}"

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
