source "https://rubygems.org"

ruby "4.0.9"

gem "rails", "~> 8.1.4"
gem "sprockets-rails"
gem "pg"
gem "puma", "~> 8.0"
gem "bcrypt"
gem "daemons"
gem "delayed_job"
gem "delayed_job_active_record"
gem "hashids"
gem "activerecord-session_store"
gem "csv"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "jbuilder"
gem "tzinfo-data", platforms: %i[windows jruby]

group :development, :test do
  gem "debug", platforms: %i[mri windows]
  gem "brakeman", require: false
  gem "bundler-audit", require: false
end

group :development do
  gem "web-console"
end

group :test do
  gem "minitest-mock"
  gem "capybara"
  gem "selenium-webdriver"
end
