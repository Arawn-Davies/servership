# Rack entrypoint: mounts the Sinatra app AND an in-process WebSocket->VNC proxy,
# so noVNC lives entirely inside our one framework/origin (no separate websockify).
# Runs under puma (Rack 3); the WS proxy uses faye's rack.hijack mode + a plain
# socket bridge, so no EventMachine reactor is needed. Session + OmniAuth
# middleware wrap BOTH maps, so login gates the app and the console stream alike.
require 'faye/websocket'
require 'securerandom'
require 'socket'
require 'rack/session'
require 'omniauth'
require 'omniauth-github'
require './app'

OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.silence_get_warning = true

CONSOLE = ENV['CONSOLE_HOST'] || 'console'
# Each BMC has its own Xvnc display/port so the consoles are fully isolated.
# noVNC connects to /websockify/<node>; we route to the matching port.
PORTS = { 'ilo' => 5901, 'idrac' => 5902 }

ws_proxy = lambda do |env|
  sess = env['rack.session']
  return [401, { 'Content-Type' => 'text/plain' }, ['unauthorized']] unless sess && sess['auth']
  node = env['PATH_INFO'].to_s.tr('/', '')     # 'ilo' | 'idrac'
  port = PORTS[node] || PORTS['ilo']
  ws = Faye::WebSocket.new(env)                # rack.hijack under puma; binary frames
  tcp = nil
  ws.on(:open) do
    begin
      tcp = TCPSocket.new(CONSOLE, port)
      # pump raw RFB bytes from Xvnc back to the browser
      Thread.new do
        begin
          loop { ws.send(tcp.readpartial(8192).bytes) }
        rescue StandardError
          ws.close rescue nil
        end
      end
    rescue StandardError
      ws.close rescue nil
    end
  end
  ws.on(:message) { |e| (tcp.write(e.data.is_a?(Array) ? e.data.pack('C*') : e.data) rescue nil) if tcp }
  ws.on(:close)   { tcp.close rescue nil }
  ws.rack_response
end

use Rack::Session::Cookie,
    secret: (ENV['SESSION_SECRET'].to_s.empty? ? SecureRandom.hex(64) : ENV['SESSION_SECRET']),
    same_site: :lax,
    expire_after: 60 * 60 * 12
use OmniAuth::Builder do
  provider :github, ENV['GITHUB_CLIENT_ID'], ENV['GITHUB_CLIENT_SECRET'], scope: 'read:user'
end

map('/websockify') { run ws_proxy }
map('/')           { run BMC }
