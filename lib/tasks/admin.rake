namespace :admin do
  desc 'Reset admin password from ADMIN_RESET_PASSWORD environment variable'
  task reset_password: :environment do
    reset_password = ENV['ADMIN_RESET_PASSWORD']

    unless reset_password.present?
      puts 'ERROR: ADMIN_RESET_PASSWORD environment variable not set'
      puts 'Usage: ADMIN_RESET_PASSWORD=newpassword rails admin:reset_password'
      exit 1
    end

    admin = Admin.find_by(username: 'admin')
    unless admin
      puts 'ERROR: Admin user with username "admin" not found'
      puts 'Run rails db:seed first to create the default admin user'
      exit 1
    end

    if admin.update(password: reset_password)
      puts "✓ Admin password reset successfully"
      puts "  Username: admin"
      puts "  Password: #{reset_password}"
    else
      puts "ERROR: Failed to reset admin password"
      puts admin.errors.full_messages.join(', ')
      exit 1
    end
  end
end
