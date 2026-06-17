# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Examples:
#
#   movies = Movie.create([{ name: "Star Wars" }, { name: "Lord of the Rings" }])
#   Character.create(name: "Luke", movie: movies.first)

# ============================================================================
# DEFAULT ADMIN CREDENTIALS
# ============================================================================
# Default username: admin
# Default password: admin123
#
# These credentials are ONLY used during initial setup (first db:seed).
# After setup, credentials are stored in the database and updated through the web UI.
#
# RESETTING FORGOTTEN CREDENTIALS:
# If the admin password is forgotten in production:
#   1. Set environment variable: ADMIN_RESET_PASSWORD=<new_password>
#   2. Run: rails admin:reset_password
#   3. Username remains 'admin' unless changed via the web UI
#
# For local development:
#   1. Edit .env and set: ADMIN_RESET_PASSWORD=<new_password>
#   2. Run: rails admin:reset_password
#
# ============================================================================

DEFAULT_ADMIN_USERNAME = 'admin'
DEFAULT_ADMIN_PASSWORD = 'admin123'

Admin.create(
  username: DEFAULT_ADMIN_USERNAME,
  password: DEFAULT_ADMIN_PASSWORD
) unless Admin.exists?(username: DEFAULT_ADMIN_USERNAME)
