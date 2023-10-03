class HealthcheckController < ActionController::Base
  def index
    render plain: 'OK'
  end
end
