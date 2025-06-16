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
    python3.11 \
    python3.11-dev \
    python3.11-venv \
    python3-pip \
    gfortran \
    libopenblas-dev \
    liblapack-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Create and activate virtual environment
RUN python3.11 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Upgrade pip and install wheel
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel

# Set numpy build configuration
ENV OPENBLAS=/usr/lib/aarch64-linux-gnu/openblas
ENV NPY_NUM_BUILD_JOBS=4
ENV NPY_DISABLE_CPU_FEATURES=1
ENV CFLAGS="-fPIC"
ENV LDFLAGS="-L/usr/lib/aarch64-linux-gnu"

# Install Python packages
COPY requirements.txt ./
RUN pip3 install --no-cache-dir -r requirements.txt

# fix policy error with imagemagick and ghostscript
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

# Remove any existing server.pid file
RUN rm -f /app/tmp/pids/server.pid

# Command to run the Rails server
CMD ["rails", "server", "-b", "0.0.0.0"]
