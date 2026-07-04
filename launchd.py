#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Tiny launch listener (internal only, port 9000): the Sinatra app POSTs
# /launch/<ilo|idrac> and we fire the matching KVM script on its OWN X display
# (:1 for iLO2, :2 for iDRAC6) so the two consoles are fully isolated.
# Reuses an already-running console instead of stacking a second one.
# python2 (stretch) -- uses BaseHTTPServer.
import BaseHTTPServer, subprocess, os

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

class H(BaseHTTPServer.BaseHTTPRequestHandler):
    def do_POST(self):
        key = self.path.rstrip('/').split('/')[-1]
        item = LAUNCH.get(key)
        if item and item[2][1]:
            disp, proc, cmd = item
            if not running(proc):
                subprocess.Popen(cmd, env=dict(os.environ, DISPLAY=disp))
            self.send_response(200); self.end_headers(); self.wfile.write('ok')
        else:
            self.send_response(404); self.end_headers(); self.wfile.write('unknown')
    def log_message(self, *a):
        pass

BaseHTTPServer.HTTPServer(('0.0.0.0', 9000), H).serve_forever()
