# Legacy BMC console appliance — launches iLO2 (HP) and iDRAC6 (Dell) Java
# KVM applets that modern OSes/browsers can no longer run. You view its
# desktop from a modern browser via noVNC; it does the dead-crypto handshake.
FROM debian:stretch

ENV DEBIAN_FRONTEND=noninteractive

# Stretch is archived — point apt at archive.debian.org and skip the stale
# Valid-Until check. Stretch is the last Debian carrying openjdk-8 +
# icedtea-netx + firefox-esr together — exactly the legacy stack these BMCs need.
RUN printf '%s\n' \
      'deb http://archive.debian.org/debian stretch main' \
      'deb http://archive.debian.org/debian-security stretch/updates main' \
      > /etc/apt/sources.list

RUN apt-get -o Acquire::Check-Valid-Until=false update && apt-get install -y --no-install-recommends \
      openjdk-8-jre icedtea-netx \
      tigervnc-standalone-server tigervnc-common \
      novnc websockify \
      fluxbox xterm x11-utils dbus-x11 \
      firefox-esr \
      ca-certificates wget curl procps nano \
    && rm -rf /var/lib/apt/lists/*

# --- Re-enable the dead crypto the BMCs still speak -------------------------
# Blank these two lists so OpenJDK 8 stops refusing TLSv1/old ciphers/small keys.
RUN JS=/etc/java-8-openjdk/security/java.security && \
    sed -i 's/^jdk.tls.disabledAlgorithms=.*/jdk.tls.disabledAlgorithms=/' $JS && \
    sed -i 's/^jdk.certpath.disabledAlgorithms=.*/jdk.certpath.disabledAlgorithms=/' $JS && \
    sed -i 's/^jdk.jar.disabledAlgorithms=.*/jdk.jar.disabledAlgorithms=/' $JS

# --- Make IcedTea-Web run unsigned/expired applets without nagging ----------
RUN mkdir -p /root/.config/icedtea-web && \
    printf '%s\n' \
      'deployment.security.level=ALLOW_UNSIGNED' \
      'deployment.security.notinca.warning=false' \
      'deployment.security.validation.crl=false' \
      'deployment.security.validation.ocsp=false' \
      'deployment.security.https.crl=false' \
      'deployment.security.expired.warning=false' \
      'deployment.security.jsse.https.certrevocation.check=false' \
      > /root/.config/icedtea-web/deployment.properties

# --- noVNC client: distro ships 2013-era 0.4 (too old for Firefox), but the
# distro websockify 0.8 REQUIRES the client send the 'binary' WS sub-protocol,
# which noVNC >=1.2 dropped. v1.1.0 is the sweet spot: modern enough for
# current Firefox, still sends 'binary' so websockify 0.8 accepts it.
RUN mkdir -p /opt/novnc && \
    wget -qO /tmp/novnc.tgz https://github.com/novnc/noVNC/archive/refs/tags/v1.1.0.tar.gz && \
    tar xzf /tmp/novnc.tgz -C /opt/novnc --strip-components=1 && rm /tmp/novnc.tgz

# --- Let Firefox reach the BMCs' ancient TLS (for clicking the web UI) ------
RUN FF=/etc/firefox-esr && mkdir -p $FF && \
    printf '%s\n' \
      'pref("security.tls.version.min", 1);' \
      'pref("security.tls.version.enable-deprecated", true);' \
      'pref("security.ssl3.rsa_des_ede3_sha", true);' \
      'pref("security.ssl3.deprecated.rc4_128_sha", true);' \
      'pref("browser.aboutConfig.showWarning", false);' \
      > $FF/autoconfig.js 2>/dev/null || true

COPY start.sh /usr/local/bin/start.sh
COPY ilo2 /usr/local/bin/ilo2
COPY idrac6 /usr/local/bin/idrac6
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/ilo2 /usr/local/bin/idrac6

EXPOSE 8080
CMD ["/usr/local/bin/start.sh"]
