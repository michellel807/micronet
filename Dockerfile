# Use the official Ruby image as base
FROM ruby:3.2.2

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
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/miniconda3/bin:${PATH}"
ARG PATH="/miniconda3/bin:${PATH}"
RUN wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh \
    && mkdir /root/.conda \
    && bash Miniconda3-latest-Linux-x86_64.sh -b -u -p /miniconda3 \
    && rm -f Miniconda3-latest-Linux-x86_64.sh \
    && echo "Running $(conda --version)" 


COPY amigacondaenv.yml ./
RUN conda env create -f ./amigacondaenv.yml


# Copy Gemfile and Gemfile.lock into the image and install dependencies
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Copy the rest of the application code into the image
COPY . /app

# Expose port 3000
EXPOSE 3000

# Command to run the Rails server
CMD ["rails", "server", "-b", "0.0.0.0"]
