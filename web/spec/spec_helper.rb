ENV['RACK_ENV'] = 'test'
# Test auth config (must be set before app.rb reads them).
ENV['SESSION_SECRET']       ||= 'x' * 64
ENV['PLATFORM_USER']        ||= 'tester'
ENV['PLATFORM_PASS']        ||= 'testpass'
ENV['GITHUB_ALLOWED_USERS'] ||= 'Arawn-Davies'
ENV['GITHUB_CLIENT_ID']     ||= 'testid'
ENV['GITHUB_CLIENT_SECRET'] ||= 'testsecret'

require 'rack/test'
require 'omniauth'
require 'omniauth-github'
require_relative '../app'

OmniAuth.config.test_mode = true
OmniAuth.config.logger = Logger.new(File::NULL)

module AppHelper
  # Full Rack stack (session + OmniAuth) wrapping the Sinatra app, mirroring
  # config.ru so auth behaves in tests as it does in production.
  def app
    @app ||= Rack::Builder.app do
      use Rack::Session::Cookie, secret: ENV['SESSION_SECRET'], same_site: :lax
      use OmniAuth::Builder do
        provider :github, ENV['GITHUB_CLIENT_ID'], ENV['GITHUB_CLIENT_SECRET']
      end
      run BMC
    end
  end

  def login_local!
    post '/login', user: ENV['PLATFORM_USER'], pass: ENV['PLATFORM_PASS']
  end

  def mock_github(nickname)
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(info: { nickname: nickname })
  end
end

RSpec.configure do |c|
  c.include Rack::Test::Methods
  c.include AppHelper
  c.expect_with(:rspec) { |e| e.syntax = :expect }
  c.after { OmniAuth.config.mock_auth[:github] = nil }
end
