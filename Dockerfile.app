# Use the official Ruby image as base
FROM ruby:3.2.2

# Set the working directory
WORKDIR /app

# Install dependencies
RUN apt-get update && \
    apt-get install -y nodejs

# Copy Gemfile and Gemfile.lock into the image and install dependencies
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Copy the rest of the application code into the image
COPY . /app

# Expose port 3000
EXPOSE 3000

# Command to run the Rails server
CMD ["rails", "server", "-b", "0.0.0.0"]
