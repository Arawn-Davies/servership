require 'spec_helper'
require 'json'

# Stubbed IPMI results so specs never touch a real BMC.
STUB = {
  'ilo' => { power: 'on', ok: true, watts: '40 Watts',
             temps: [['Ambient Temp', '24 degrees C', 'ok']],
             fans:  [['FAN 1', '3000 RPM', 'ok']], volts: [], sel: [] },
  'idrac' => { power: 'on', ok: true, watts: '168 Watts',
               temps: [['Ambient Temp', '24 degrees C', 'ok']],
               fans:  [['FAN MOD 1A', '3360 RPM', 'ok']], volts: [], sel: [] },
}.freeze

def json_post(node, action)
  post '/power', { node: node, action: action }.to_json,
       'CONTENT_TYPE' => 'application/json'
end

RSpec.describe BMC do
  # Auth is enforced (PLATFORM_* set in spec_helper), so the app is gated.
  describe 'authentication' do
    it 'redirects an unauthenticated request to /login' do
      get '/dashboard'
      expect(last_response.status).to eq(302)
      expect(last_response.headers['Location']).to include('/login')
    end

    it 'serves the login page' do
      get '/login'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Sign in')
    end

    it 'grants access with correct local credentials' do
      login_local!
      expect(last_response.status).to eq(302)
      get '/'
      expect(last_response).to be_ok
      expect(last_response.body).to include('iLO2 Console')
    end

    it 'rejects wrong local credentials' do
      post '/login', user: 'tester', pass: 'nope'
      expect(last_response.status).to eq(401)
      get '/dashboard'
      expect(last_response.status).to eq(302)
    end

    it 'admits an allowlisted GitHub user' do
      mock_github('Arawn-Davies')
      get '/auth/github/callback'
      expect(last_response.status).to eq(302)
      get '/'
      expect(last_response).to be_ok
    end

    it 'denies a non-allowlisted GitHub user' do
      mock_github('someone-else')
      get '/auth/github/callback'
      expect(last_response.status).to eq(403)
    end

    it 'logs out' do
      login_local!
      get '/logout'
      expect(last_response.status).to eq(302)
      get '/dashboard'
      expect(last_response.headers['Location']).to include('/login')
    end
  end

  context 'when authenticated' do
    before { login_local! }

    describe 'GET /' do
      it 'renders the landing page with all three entry points' do
        get '/'
        expect(last_response).to be_ok
        expect(last_response.body).to include('iLO2 Console', 'iDRAC6 Console', 'IPMI Dashboard')
      end
    end

    describe 'GET /dashboard' do
      before { allow_any_instance_of(BMC).to receive(:gather_all).and_return(STUB) }

      it 'renders both nodes with live readings and controls' do
        get '/dashboard'
        expect(last_response).to be_ok
        expect(last_response.body).to include('SQUIDBLADE', 'SQUIDBOAT',
                                              '40 Watts', '168 Watts',
                                              'Power On', 'Force Off')
      end
    end

    describe 'POST /power' do
      it 'runs a valid power action' do
        allow_any_instance_of(BMC).to receive(:ipmi).and_return('Chassis Power Control: Cycle')
        json_post('idrac', 'cycle')
        expect(last_response).to be_ok
        expect(last_response.body).to include('SQUIDBOAT', 'cycle')
      end

      it 'rejects an unknown node' do
        json_post('nope', 'on')
        expect(last_response.status).to eq(400)
      end

      it 'rejects an unknown action' do
        json_post('idrac', 'explode')
        expect(last_response.status).to eq(400)
      end
    end

    describe 'GET /console/:key' do
      before { allow(Net::HTTP).to receive(:post) } # do not fire a real launch

      it 'embeds noVNC for a known node' do
        get '/console/ilo'
        expect(last_response).to be_ok
        expect(last_response.body).to include('/novnc/vnc.html', 'SQUIDBLADE')
      end

      it 'fires the launch on the engine for a known node' do
        get '/console/idrac'
        expect(Net::HTTP).to have_received(:post)
      end

      it '404s an unknown node' do
        get '/console/bogus'
        expect(last_response.status).to eq(404)
      end
    end
  end
end
