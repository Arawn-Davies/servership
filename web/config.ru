# Rack entrypoint: mounts the Sinatra app AND an in-process WebSocket->VNC proxy,
# so noVNC lives entirely inside our one framework/origin (no separate websockify).
# Runs under puma (Rack 3); the WS proxy uses faye's rack.hijack mode + a plain
# socket bridge, so no EventMachine reactor is needed. Session + OmniAuth
# middleware wrap BOTH maps, so login gates the app and the console stream alike.
require 'faye/websocket'
require 'securerandom'
require 'socket'
require 'pty'
require 'io/console'
require 'rack/session'
require 'omniauth'
require 'omniauth-github'
require './app'

OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.silence_get_warning = true

# Behind a TLS-terminating reverse proxy (e.g. Nginx Proxy Manager) the app only
# ever sees plain HTTP, so without this the OAuth redirect_uri and any absolute
# URL come out as http:// and Secure cookies would never be set. Opt in by
# setting TRUST_PROXY=1 - only enable it when the app is actually reached solely
# through a proxy you control that sets X-Forwarded-Proto.
TRUST_PROXY = ENV['TRUST_PROXY'] == '1'

class TrustProxy
  def initialize(app) = @app = app

  def call(env)
    proto = env['HTTP_X_FORWARDED_PROTO'].to_s.split(',').first.to_s.strip
    unless proto.empty?
      env['rack.url_scheme'] = proto
      env['HTTPS']           = (proto == 'https' ? 'on' : 'off')
      fport = env['HTTP_X_FORWARDED_PORT'].to_s.split(',').first.to_s.strip
      env['SERVER_PORT'] = fport.empty? ? (proto == 'https' ? '443' : '80') : fport
    end
    @app.call(env)
  end
end

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

# --- Serial/text console: browser xterm.js <-> a console process on a PTY ---
# Two transports, switchable per connection (?via=):
#   ssh: log into the BMC's SSH CLI and auto-type its text-console command at
#     the CLI prompt (as a one-shot ssh command the BMC exits immediately,
#     hence the interactive login). Per vendor (SSH_CONSOLE):
#       HP iLO2   - `textcons` at `hpiLO->`, mirrors the VGA text buffer
#                   (repaints on attach); exit key ESC (
#       Dell iDRAC6 - `console -h com2` at `/admin1->`, the COM2 serial stream
#                   with history-buffer replay on attach; exit key Ctrl-\
#     Needs the BMC's ancient SSH crypto re-enabled.
#   sol: IPMI Serial-over-LAN via `ipmitool sol activate` (raw serial, UDP 623).
# One live session per node (the BMC only allows one anyway); a new connection
# takes over by killing the previous one. SOL sessions get `sol deactivate` on
# open (clears stale payloads) and close (frees it for the next connect).
SOL_SESSIONS = {}   # node id -> console pid
SOL_MUTEX    = Mutex.new

# vendor -> [CLI prompt to wait for, command to start the console]
SSH_CONSOLE = {
  'hp'   => ['hpiLO->',  'textcons'],
  'dell' => ['/admin1->', 'console -h com2'],
}.freeze

def sol_cmd(n, *args)
  ['ipmitool', '-I', 'lanplus', '-H', n[:ip], '-U', n[:user], '-P', n[:pass], *args]
end

def console_cmd(n, via)
  if via == 'ssh'
    ['sshpass', '-p', n[:pass], 'ssh', '-tt',
     '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
     '-o', 'LogLevel=ERROR',
     '-o', 'KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1',
     '-o', 'HostKeyAlgorithms=+ssh-rsa',
     '-o', 'PubkeyAcceptedAlgorithms=+ssh-rsa',
     '-o', 'Ciphers=+aes128-cbc,3des-cbc', '-o', 'MACs=+hmac-sha1',
     "#{n[:user]}@#{n[:ip]}"]
  else
    sol_cmd(n, 'sol', 'activate')
  end
end

sol_ws = lambda do |env|
  sess = env['rack.session']
  return [401, { 'Content-Type' => 'text/plain' }, ['unauthorized']] unless sess && sess['auth']
  node = Store.find(env['PATH_INFO'].to_s.tr('/', ''))
  return [404, { 'Content-Type' => 'text/plain' }, ['unknown node']] unless node && !node[:ip].to_s.empty?
  via = Rack::Utils.parse_query(env['QUERY_STRING'].to_s)['via']
  via = 'sol' unless via == 'ssh' && SSH_CONSOLE.key?(node[:vendor])   # ssh only where we know the CLI
  ssh_prompt, ssh_start = SSH_CONSOLE[node[:vendor]]
  ws = Faye::WebSocket.new(env)
  pty_r = pty_w = pid = nil
  ws.on(:open) do
    # setup runs in its own thread: deactivate takes a second or two and must
    # not block puma's reactor
    Thread.new do
      begin
        SOL_MUTEX.synchronize do
          old = SOL_SESSIONS[node[:id]]
          Process.kill('TERM', old) if old rescue nil
        end
        # clear any stale/abandoned SOL payload on the BMC, then attach
        if via == 'sol'
          system(*sol_cmd(node, 'sol', 'deactivate'), out: File::NULL, err: File::NULL)
        end
        # advertise a capable terminal (xterm.js is one) - with plain vt100
        # textcons falls back to repainting whole lines on every change
        pty_r, pty_w, pid = PTY.spawn({ 'TERM' => 'xterm' }, *console_cmd(node, via))
        pty_r.winsize = [25, 80] rescue nil
        SOL_MUTEX.synchronize { SOL_SESSIONS[node[:id]] = pid }
        typed = false
        loop do
          data = pty_r.readpartial(4096)
          # ssh transport: wait for the BMC's CLI prompt, then start its console
          # (as a one-shot ssh command the BMC would just exit at the prompt)
          if via == 'ssh' && !typed && data.include?(ssh_prompt)
            pty_w.write "#{ssh_start}\r"
            typed = true
          end
          ws.send(data.bytes)
        end
      rescue StandardError
        ws.close rescue nil
      end
    end
  end
  ws.on(:message) { |e| (pty_w.write(e.data.is_a?(Array) ? e.data.pack('C*') : e.data) rescue nil) if pty_w }
  ws.on(:close) do
    Thread.new do
      begin
        SOL_MUTEX.synchronize { SOL_SESSIONS.delete(node[:id]) if SOL_SESSIONS[node[:id]] == pid }
        if pid
          Process.kill('TERM', pid) rescue nil
          Process.wait(pid) rescue nil
        end
        pty_r.close rescue nil
        pty_w.close rescue nil
        # free the SOL payload on the BMC so the next session can attach
        if via == 'sol'
          system(*sol_cmd(node, 'sol', 'deactivate'), out: File::NULL, err: File::NULL)
        end
      rescue StandardError
      end
    end
  end
  ws.rack_response
end

use TrustProxy if TRUST_PROXY
use Rack::Session::Cookie,
    secret: (ENV['SESSION_SECRET'].to_s.empty? ? SecureRandom.hex(64) : ENV['SESSION_SECRET']),
    same_site: :lax,
    secure: TRUST_PROXY,          # only mark Secure when we know we're behind TLS
    expire_after: 60 * 60 * 12
use OmniAuth::Builder do
  provider :github, ENV['GITHUB_CLIENT_ID'], ENV['GITHUB_CLIENT_SECRET'], scope: 'read:user'
end

map('/websockify') { run ws_proxy }
map('/solws')      { run sol_ws }
map('/')           { run BMC }
