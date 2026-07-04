#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Tiny launch listener (internal only, port 9000): the Sinatra app POSTs
#   /launch/<node>    start the console if not already running
#   /kill/<node>      stop the console's browser
#   /relaunch/<node>  stop then start fresh (used by the Reload button)
# Each node runs on its OWN X display (:1 iLO2, :2 iDRAC6), fully isolated.
# python2 (stretch) -- uses BaseHTTPServer.
import BaseHTTPServer, subprocess, os, time

DEVNULL = open(os.devnull, 'w')

# key -> (display, browser-process-match, launch command)
LAUNCH = {
    'ilo':   (':1', '/opt/firefox52/firefox',
              ['/usr/local/bin/ilo2', os.environ.get('ILO_IP', '')]),
    'idrac': (':2', 'firefox-esr',
              ['/usr/local/bin/idrac6', os.environ.get('IDRAC_IP', ''),
               os.environ.get('IDRAC_USER', ''), os.environ.get('IDRAC_PASS', '')]),
}

def running(pattern):
    return subprocess.call(['pgrep', '-f', pattern], stdout=DEVNULL, stderr=DEVNULL) == 0

def kill(pattern):
    subprocess.call(['pkill', '-9', '-f', pattern], stdout=DEVNULL, stderr=DEVNULL)

def start(disp, cmd):
    subprocess.Popen(cmd, env=dict(os.environ, DISPLAY=disp))

class H(BaseHTTPServer.BaseHTTPRequestHandler):
    def do_POST(self):
        parts = self.path.strip('/').split('/')      # e.g. ['launch', 'ilo']
        action = parts[0] if parts else ''
        key = parts[-1] if len(parts) > 1 else ''
        item = LAUNCH.get(key)
        if not item or not item[2][1] or action not in ('launch', 'kill', 'relaunch'):
            self.send_response(404); self.end_headers(); self.wfile.write('unknown'); return
        disp, proc, cmd = item
        if action == 'launch':
            if not running(proc):
                start(disp, cmd)
        elif action == 'kill':
            kill(proc)
        elif action == 'relaunch':
            kill(proc); time.sleep(1); start(disp, cmd)
        self.send_response(200); self.end_headers(); self.wfile.write('ok')
    def log_message(self, *a):
        pass

BaseHTTPServer.HTTPServer(('0.0.0.0', 9000), H).serve_forever()
