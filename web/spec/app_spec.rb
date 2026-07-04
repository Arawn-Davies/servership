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
