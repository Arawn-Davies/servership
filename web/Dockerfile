# bmc-web - Sinatra + Tailwind control panel with an in-process noVNC proxy.
# IPMI needs no legacy crypto, so a modern Ruby base is fine.
FROM ruby:3-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ipmitool ca-certificates wget \
      openssh-client sshpass \
      build-essential libssl-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install

# Modern noVNC 1.4 served straight from Sinatra (our own WS proxy has none of
# the websockify-0.8 sub-protocol limitation, so no version pinning needed).
RUN mkdir -p public/novnc && \
    wget -qO /tmp/novnc.tgz https://github.com/novnc/noVNC/archive/refs/tags/v1.4.0.tar.gz && \
    tar xzf /tmp/novnc.tgz -C public/novnc --strip-components=1 && rm /tmp/novnc.tgz

# xterm.js (vendored, served from /xterm) for the Serial-over-LAN terminal.
RUN mkdir -p public/xterm && cd /tmp && \
    wget -qO xterm.tgz https://registry.npmjs.org/@xterm/xterm/-/xterm-5.5.0.tgz && \
    tar xzf xterm.tgz && \
    cp package/lib/xterm.js package/css/xterm.css /app/public/xterm/ && rm -rf package xterm.tgz && \
    wget -qO fit.tgz https://registry.npmjs.org/@xterm/addon-fit/-/addon-fit-0.10.0.tgz && \
    tar xzf fit.tgz && cp package/lib/addon-fit.js /app/public/xterm/ && rm -rf package fit.tgz

COPY app.rb config.ru .rspec ./
COPY views ./views
COPY spec ./spec
EXPOSE 8088
# -E production drops Rack::Lint/ShowExceptions, which otherwise reject
# faye-websocket's async hijack response and 500 the /websockify upgrade.
CMD ["bundle", "exec", "rackup", "-s", "puma", "-E", "production", "-o", "0.0.0.0", "-p", "8088"]
