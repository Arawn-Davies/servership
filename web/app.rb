require 'sinatra/base'
require 'json'
require 'net/http'

# --- nodes (creds injected via .env / docker env_file) ----------------------
NODES = {
  'ilo'   => { key: 'ilo',   label: 'SQUIDBLADE', kind: 'iLO2 · HP DL320 G6',
               accent: 'sky',
               ip: ENV['ILO_IP'].to_s,   user: ENV['ILO_USER'].to_s,   pass: ENV['ILO_PASS'].to_s },
  'idrac' => { key: 'idrac', label: 'SQUIDBOAT',  kind: 'iDRAC6 · Dell R510',
               accent: 'emerald',
               ip: ENV['IDRAC_IP'].to_s, user: ENV['IDRAC_USER'].to_s, pass: ENV['IDRAC_PASS'].to_s },
}
CONSOLE_HOST = ENV['CONSOLE_HOST'] || 'console'   # compose service running the KVM engine

# --- platform auth (front door; BMC creds stay server-side regardless) -------
GITHUB_ALLOWED = ENV['GITHUB_ALLOWED_USERS'].to_s.split(',').map { |s| s.strip.downcase }.reject(&:empty?)
PLATFORM_USER  = ENV['PLATFORM_USER'].to_s
PLATFORM_PASS  = ENV['PLATFORM_PASS'].to_s

# --- IPMI (no shell: array exec, so a '!' in a password is safe) -------------
def ipmi(n, *args)
  return '' if n[:ip].empty?
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
    if    low.include?('degrees c') then s[:temps] << [name, reading, status]
    elsif low.include?('rpm')       then s[:fans]  << [name, reading, status]
    elsif low.include?('watt')      then s[:watts] = reading
    elsif low.include?('volt')      then s[:volts] << [name, reading, status]
    end
  end
  ipmi(n, 'sel', 'elist', 'last', '4').each_line { |l| s[:sel] << l.strip if l.include?('|') }
  s
end

def gather_all
  out = {}
  NODES.map { |k, n| Thread.new { out[k] = gather(n) } }.each(&:join)
  out
end

class BMC < Sinatra::Base
  set :environment, :production
  set :views,         File.expand_path('views',  __dir__)
  set :public_folder, File.expand_path('public', __dir__)   # serves /novnc/*

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
    def authed?      = !!session['auth']
    def current_user = session['user']
    def github_enabled? = !ENV['GITHUB_CLIENT_ID'].to_s.empty?
    def local_enabled?  = !PLATFORM_USER.empty?
    def auth_enabled?   = github_enabled? || local_enabled?
  end

  # Gate everything behind login once any auth method is configured. Static
  # /novnc/* assets are served before filters run, so they stay reachable
  # (inert without an authed WebSocket). /auth/* is OmniAuth's territory.
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

  # OmniAuth GitHub callback: allow only listed usernames.
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
    @nodes = gather_all
    erb :dashboard
  end

  get '/console/:key' do
    @node = NODES[params[:key]] or halt 404, 'unknown node'
    begin
      Net::HTTP.post(URI("http://#{CONSOLE_HOST}:9000/launch/#{@node[:key]}"), '')
    rescue StandardError
      # engine may be warming up; the embedded noVNC still shows the desktop
    end
    erb :console
  end

  post '/power' do
    body = (JSON.parse(request.body.read) rescue {})
    n = NODES[body['node']] or halt 400, 'unknown node'
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
