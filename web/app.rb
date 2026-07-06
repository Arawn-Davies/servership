require 'sinatra/base'
require 'json'
require 'net/http'
require 'securerandom'
require 'fileutils'

CONSOLE_HOST = ENV['CONSOLE_HOST'] || 'console'   # compose service running the KVM engine
STORE_PATH   = ENV['SERVERS_PATH'] || '/data/servers.json'

# --- platform auth (front door; BMC creds stay server-side regardless) -------
GITHUB_ALLOWED = ENV['GITHUB_ALLOWED_USERS'].to_s.split(',').map { |s| s.strip.downcase }.reject(&:empty?)
PLATFORM_USER  = ENV['PLATFORM_USER'].to_s
PLATFORM_PASS  = ENV['PLATFORM_PASS'].to_s

# --- server store: BMC entries (CRUD), persisted to a JSON volume ------------
# Seeded on first run from the .env pair, which also own the two wired-up
# consoles (via :console => 'ilo' / 'idrac'). New entries are dashboard-only.
module Store
  MUTEX = Mutex.new

  def self.defaults
    [
      { id: 'ilo', label: 'SQUIDBLADE', kind: 'iLO2 · HP DL320 G6', vendor: 'hp',
        accent: 'sky', ip: ENV['ILO_IP'].to_s, user: ENV['ILO_USER'].to_s,
        pass: ENV['ILO_PASS'].to_s, fan_max: (ENV['FAN_MAX_ILO'] || 18000).to_i,
        console: 'ilo' },
      { id: 'idrac', label: 'SQUIDBOAT', kind: 'iDRAC6 · Dell R510', vendor: 'dell',
        accent: 'emerald', ip: ENV['IDRAC_IP'].to_s, user: ENV['IDRAC_USER'].to_s,
        pass: ENV['IDRAC_PASS'].to_s, fan_max: (ENV['FAN_MAX_IDRAC'] || 12000).to_i,
        console: 'idrac' },
    ]
  end

  def self.all
    MUTEX.synchronize { load! }
  end

  def self.find(id)
    all.find { |s| s[:id] == id.to_s }
  end

  def self.save(p)     # create (no matching id) or update (existing id)
    MUTEX.synchronize do
      list = load!
      i = list.index { |s| s[:id] == p['id'].to_s }
      attrs = {
        label:   p['label'].to_s.strip,
        ip:      p['ip'].to_s.strip,
        user:    p['user'].to_s,
        vendor:  (%w[hp dell other].include?(p['vendor']) ? p['vendor'] : 'other'),
        fan_max: (p['fan_max'].to_s.strip.empty? ? 12000 : p['fan_max'].to_i),
      }
      attrs[:pass] = p['pass'].to_s unless p['pass'].to_s.empty?  # keep existing pass if blank
      if i
        list[i] = list[i].merge(attrs)
      else
        attrs[:pass]  ||= ''
        attrs[:id]      = SecureRandom.hex(4)
        attrs[:accent]  = 'slate'
        attrs[:kind]    = "#{attrs[:vendor] == 'other' ? 'BMC' : attrs[:vendor].upcase}"
        list << attrs
      end
      write!(list)
    end
  end

  def self.delete(id)  = MUTEX.synchronize { write!(load!.reject { |s| s[:id] == id.to_s }) }

  # internal (caller holds MUTEX)
  def self.load!
    return write!(defaults) unless File.exist?(STORE_PATH)
    JSON.parse(File.read(STORE_PATH), symbolize_names: true)
  rescue StandardError
    []
  end

  def self.write!(list)
    FileUtils.mkdir_p(File.dirname(STORE_PATH))
    File.write(STORE_PATH, JSON.pretty_generate(list))
    list
  end
end

# --- IPMI (no shell: array exec, so a '!' in a password is safe) -------------
def ipmi(n, *args)
  return '' if n[:ip].to_s.empty?
  cmd = ['ipmitool', '-I', 'lanplus', '-H', n[:ip], '-U', n[:user], '-P', n[:pass],
         '-N', '2', '-R', '1', *args]
  out = ''
  begin
    IO.popen(cmd, err: File::NULL) { |io| out = io.read }
  rescue StandardError
    out = ''
  end
  out
end

def gather(n)
  s = { power: 'unreachable', ok: false, watts: nil, temps: [], fans: [], volts: [], sel: [] }
  ps = ipmi(n, 'chassis', 'power', 'status')
  unless ps.strip.empty?
    s[:power] = ps.strip.split.last
    s[:ok] = true
  end
  ipmi(n, 'sdr').each_line do |line|
    p = line.split('|').map(&:strip)
    next if p.size < 3
    name, reading, status = p[0], p[1], p[2]
    low = reading.downcase
    if low.include?('degrees c')
      s[:temps] << [name, reading, status]
    elsif low.include?('rpm') || (low.include?('percent') && name.downcase.start_with?('fan'))
      s[:fans] << [name, reading, status]
    elsif low.include?('watt')
      s[:watts] = reading if s[:watts].nil? || name =~ /meter|level|consumption|present|total/i
    elsif low.include?('volt')
      s[:volts] << [name, reading, status]
    end
  end
  ipmi(n, 'sel', 'elist', 'last', '4').each_line { |l| s[:sel] << l.strip if l.include?('|') }
  s
end

def gather_all
  out = {}
  Store.all.map { |n| Thread.new { out[n[:id]] = gather(n) } }.each(&:join)
  out
end

# Background poller: refresh the IPMI snapshot every ~12s so the dashboard serves
# a cached view instantly instead of blocking on ipmitool on every load.
STATUS = { data: {} }
unless ENV['RACK_ENV'] == 'test'
  Thread.new do
    loop do
      begin
        STATUS[:data] = gather_all
      rescue StandardError
        # keep serving the last good snapshot
      end
      sleep 12
    end
  end
end

class BMC < Sinatra::Base
  set :environment, :production
  set :views,         File.expand_path('views',  __dir__)
  set :public_folder, File.expand_path('public', __dir__)   # serves /novnc/*
  # Auto HTML-escape all <%= %> output (via Erubi); intentional HTML uses <%== %>.
  set :erb, escape_html: true

  CONSOLE_KEYS = %w[ilo idrac].freeze   # the two wired-up KVM consoles

  helpers do
    def status_class(power, ok)
      return 'unreachable' unless ok
      power.to_s.downcase == 'on' ? 'on' : 'off'
    end
    def ambient(temps)
      (temps.find { |t| t[0] =~ /ambient|inlet/i } || temps.first || ['-', '-', ''])[1]
    end
    def fans_ok(fans)
      fans.count { |f| f[2].to_s.downcase.include?('ok') }
    end
    def fan_bits(reading)
      m = reading.to_s.match(/([\d.]+)\s*(percent|rpm)/i)
      m ? [m[1], m[2].downcase] : ['', '']
    end
    def authed?      = !!session['auth']
    def current_user = session['user']
    def github_enabled? = !ENV['GITHUB_CLIENT_ID'].to_s.empty?
    def local_enabled?  = !PLATFORM_USER.empty?
    def auth_enabled?   = github_enabled? || local_enabled?
  end

  before do
    next unless auth_enabled?
    p = request.path_info
    next if p == '/login' || p == '/logout' || p.start_with?('/auth/')
    redirect '/login' unless session['auth']
  end

  get '/login' do
    redirect '/' if session['auth']
    erb :login
  end

  post '/login' do
    if local_enabled? &&
       Rack::Utils.secure_compare(PLATFORM_USER, params['user'].to_s) &&
       Rack::Utils.secure_compare(PLATFORM_PASS, params['pass'].to_s)
      session['auth'] = true
      session['user'] = PLATFORM_USER
      redirect '/'
    else
      @error = 'Invalid credentials'
      status 401
      erb :login
    end
  end

  get '/auth/github/callback' do
    login = request.env.dig('omniauth.auth', 'info', 'nickname').to_s
    if !login.empty? && GITHUB_ALLOWED.include?(login.downcase)
      session['auth'] = true
      session['user'] = login
      redirect '/'
    else
      @error = login.empty? ? 'GitHub sign-in failed' : "#{login} is not authorised"
      status 403
      erb :login
    end
  end

  get '/auth/failure' do
    @error = "GitHub sign-in failed: #{params['message']}"
    status 401
    erb :login
  end

  get '/logout' do
    session.clear
    redirect '/login'
  end

  get('/') { erb :landing }

  get '/dashboard' do
    @servers = Store.all
    @nodes   = STATUS[:data].empty? ? gather_all : STATUS[:data]
    erb :dashboard
  end

  # --- server CRUD (dashboard entries) --------------------------------------
  post '/servers' do        # create (blank id) or update (existing id)
    Store.save(params)
    redirect '/dashboard'
  end

  post '/servers/:id/delete' do
    Store.delete(params[:id])
    redirect '/dashboard'
  end

  # --- consoles (the two wired-up KVM engines) ------------------------------
  get '/console/:key' do
    halt 404, 'unknown console' unless CONSOLE_KEYS.include?(params[:key])
    @ckey = params[:key]
    @node = Store.all.find { |s| s[:console] == @ckey } ||
            { label: @ckey.upcase, kind: 'BMC console', console: @ckey }
    begin
      Net::HTTP.post(URI("http://#{CONSOLE_HOST}:9000/launch/#{@ckey}"), '')
    rescue StandardError
      # engine may be warming up; the embedded noVNC still shows the desktop
    end
    erb :console
  end

  post '/console/:key/:action' do
    halt 404 unless CONSOLE_KEYS.include?(params[:key])
    ep = { 'reload' => 'relaunch', 'exit' => 'kill' }[params[:action]] or halt 400, 'unknown action'
    begin
      Net::HTTP.post(URI("http://#{CONSOLE_HOST}:9000/#{ep}/#{params[:key]}"), '')
    rescue StandardError
      # engine momentarily unreachable; the button just no-ops
    end
    content_type :text
    'ok'
  end

  # --- serial console hub (server picker + xterm.js shell + power) ----------
  # /serial       -> the picker with nothing selected
  # /serial/:id   -> same page with that server's shell + controls loaded
  get '/serial' do
    @servers = Store.all
    @status  = STATUS[:data]
    @node    = nil
    erb :serial
  end

  get '/serial/:id' do
    @servers = Store.all
    @status  = STATUS[:data]
    @node    = Store.find(params[:id]) or halt 404, 'unknown node'
    halt 400, 'node has no BMC ip' if @node[:ip].to_s.empty?
    erb :serial
  end

  post '/power' do
    body = (JSON.parse(request.body.read) rescue {})
    n = Store.find(body['node'].to_s) or halt 400, 'unknown node'
    cmd = {
      'on'    => %w[chassis power on],    'off'   => %w[chassis power off],
      'cycle' => %w[chassis power cycle], 'reset' => %w[chassis power reset],
      'soft'  => %w[chassis power soft],  'identify' => %w[chassis identify 15],
      'selclear' => %w[sel clear],
    }[body['action']] or halt 400, 'unknown action'
    out = ipmi(n, *cmd).strip
    content_type :text
    "#{n[:label]} → #{body['action']}: #{out.empty? ? 'done' : out}"
  end
end
