# Initial setup never overwrites an existing administrator's password.
username = ENV.fetch("ADMIN_INITIAL_USERNAME", "admin")
unless Admin.exists?(username: username)
  password = ENV.fetch("ADMIN_INITIAL_PASSWORD") do
    raise "Set ADMIN_INITIAL_PASSWORD to a unique password of at least 12 characters before seeding."
  end
  Admin.create!(username: username, password: password, password_confirmation: password)
end
