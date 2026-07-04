# Rack entrypoint: mounts the Sinatra app AND an in-process WebSocket->VNC
# proxy, so noVNC lives entirely inside our one framework/origin (no separate
# websockify). Runs under thin (EventMachine) so the bridge is fully async.
require 'faye/websocket'
require 'eventmachine'
require './app'

# Hook thin's async socket, otherwise thin writes its own (bogus, accept-less)
# 101 before faye's real handshake -> browsers reject the doubled response.
Faye::WebSocket.load_adapter('thin')

CONSOLE = ENV['CONSOLE_HOST'] || 'console'
# Each BMC has its own Xvnc display/port so the consoles are fully isolated.
# noVNC connects to /websockify/<node>; we route to the matching port.
PORTS = { 'ilo' => 5901, 'idrac' => 5902 }

# EM connection to the KVM engine's Xvnc; pumps raw RFB bytes back to the browser.
class VNCBridge < EM::Connection
  def initialize(ws) = (@ws = ws)
  def receive_data(data) = @ws.send(data.bytes)
  def unbind = (@ws.close rescue nil)
end

ws_proxy = lambda do |env|
  node = env['PATH_INFO'].to_s.tr('/', '')     # 'ilo' | 'idrac'
  port = PORTS[node] || PORTS['ilo']
  ws = Faye::WebSocket.new(env)                # modern noVNC uses binary frames
  conn = nil
  ws.on(:open)    { conn = EM.connect(CONSOLE, port, VNCBridge, ws) }
  ws.on(:message) { |e| conn&.send_data(e.data.is_a?(Array) ? e.data.pack('C*') : e.data) }
  ws.on(:close)   { conn&.close_connection_after_writing }
  ws.rack_response
end

map('/websockify') { run ws_proxy }
map('/')           { run BMC }
