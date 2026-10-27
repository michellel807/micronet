require_relative "boot"


require 'rails/all'


# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module HannahsGrowthModelWebApp
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.0
    config.assets.compile = true
    config.active_storage.variant_processor = :disabled
    # Delayed Job configuration (added by me)
    config.active_job.queue_adapter = :delayed_job
    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end


# DEAD? Nothing reads python_conda_location; runtime uses /opt/uvenv/bin/python
# (see app/models/python.rb) and /miniconda3 exists in neither Docker nor the cluster.
Rails.configuration.python_conda_location="/miniconda3/envs/amigacondaenv/"
