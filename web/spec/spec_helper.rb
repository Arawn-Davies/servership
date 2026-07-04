ENV['RACK_ENV'] = 'test'
require 'rack/test'
require_relative '../app'

module AppHelper
  def app
    BMC
  end
end

RSpec.configure do |c|
  c.include Rack::Test::Methods
  c.include AppHelper
  c.expect_with(:rspec) { |e| e.syntax = :expect }
end
