# Legacy BMC console appliance - launches iLO2 (HP) and iDRAC6 (Dell) Java
# KVM applets that modern OSes/browsers can no longer run. You view its
# desktop from a modern browser via noVNC; it does the dead-crypto handshake.
FROM debian:stretch

ENV DEBIAN_FRONTEND=noninteractive

# Stretch is archived - point apt at archive.debian.org and skip the stale
# Valid-Until check. Stretch is the last Debian carrying openjdk-8 +
# icedtea-netx + firefox-esr together - exactly the legacy stack these BMCs need.
RUN printf '%s\n' \
      'deb http://archive.debian.org/debian stretch main' \
      'deb http://archive.debian.org/debian-security stretch/updates main' \
      > /etc/apt/sources.list

RUN apt-get -o Acquire::Check-Valid-Until=false update && apt-get install -y --no-install-recommends \
      openjdk-8-jre icedtea-netx \
      tigervnc-standalone-server tigervnc-common \
      novnc websockify \
      matchbox-window-manager x11-utils dbus-x11 xdotool \
      firefox-esr \
      ca-certificates wget curl procps nano bzip2 \
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

# --- NPAPI Java plugin: stretch dropped IcedTeaPlugin.so (ships only
# plugin.jar). Graft the native .so AND both Java jars (plugin.jar + netx.jar)
# in from jessie's icedtea-web 1.5.3. ALL THREE must be the same version - the
# native .so, plugin.jar and netx.jar share a private ABI; a 1.5.3 plugin.jar
# against stretch's 1.6.2 netx.jar throws NoSuchMethodError on NetxPanel.<init>
# and the applet never starts.
RUN cd /tmp && \
    POOL=http://archive.debian.org/debian/pool/main/i/icedtea-web && \
    wget -q $POOL/icedtea-7-plugin_1.5.3-1_amd64.deb && \
    wget -q $POOL/icedtea-netx-common_1.5.3-1_all.deb && \
    dpkg-deb -x icedtea-7-plugin_1.5.3-1_amd64.deb /tmp/plug && \
    dpkg-deb -x icedtea-netx-common_1.5.3-1_all.deb /tmp/netxc && \
    mkdir -p /opt/icedtea-plugin && \
    cp "$(find /tmp/plug -name IcedTeaPlugin.so)" /opt/icedtea-plugin/IcedTeaPlugin.so && \
    cp "$(find /tmp/netxc -name plugin.jar)" /usr/share/icedtea-web/plugin.jar && \
    cp "$(find /tmp/netxc -name netx.jar)"   /usr/share/icedtea-web/netx.jar && \
    rm -rf /tmp/plug /tmp/netxc /tmp/*.deb && \
    ls -l /opt/icedtea-plugin/IcedTeaPlugin.so /usr/share/icedtea-web/plugin.jar /usr/share/icedtea-web/netx.jar

# The 1.5.3 plugin has /usr/lib/jvm/java-7-openjdk-amd64/{bin/java,lib/rt.jar}
# HARDCODED (it was a java-7 build). We only have java-8, so point that exact
# path at java-8's JRE - java 8 runs these applets fine. Without this the plugin
# loads but silently never spawns the JVM (blank applet, no "needs JVM" text).
RUN ln -sfn /usr/lib/jvm/java-8-openjdk-amd64/jre /usr/lib/jvm/java-7-openjdk-amd64 && \
    ls -l /usr/lib/jvm/java-7-openjdk-amd64/bin/java /usr/lib/jvm/java-7-openjdk-amd64/lib/rt.jar

# --- Firefox 52.9 ESR: the LAST release with NPAPI, needed for iLO2's Java
# applet (iLO2 embeds the console as an in-browser <applet>, not a JNLP, so
# javaws can't help - it must run inside an NPAPI-capable browser). Modern
# firefox-esr dropped NPAPI, hence "no JVM detected". Used ONLY for iLO2.
# Tarball is fetched host-side (stretch's wget can't do Mozilla's modern TLS)
# and COPYed in - see .gitignore / README.
COPY firefox-52.9.0esr.tar.bz2 /tmp/ff52.tar.bz2
RUN tar xjf /tmp/ff52.tar.bz2 -C /opt && rm /tmp/ff52.tar.bz2 && \
    mv /opt/firefox /opt/firefox52 && \
    mkdir -p /opt/firefox52/browser/plugins && \
    ln -sf /opt/icedtea-plugin/IcedTeaPlugin.so /opt/firefox52/browser/plugins/IcedTeaPlugin.so && \
    printf '%s\n' \
      'pref("general.config.filename", "firefox.cfg");' \
      'pref("general.config.obscure_value", 0);' \
      > /opt/firefox52/defaults/pref/autoconfig.js && \
    printf '%s\n' \
      '//' \
      'lockPref("plugin.load_flash_only", false);' \
      'lockPref("plugin.state.java", 2);' \
      'lockPref("plugin.scan.plid.all", false);' \
      'lockPref("security.tls.version.min", 1);' \
      'lockPref("security.tls.version.enable-deprecated", true);' \
      'lockPref("security.ssl3.rsa_des_ede3_sha", true);' \
      'lockPref("security.ssl3.deprecated.rc4_128_sha", true);' \
      'lockPref("security.ssl3.rsa_aes_128_sha", true);' \
      'lockPref("security.ssl3.rsa_aes_256_sha", true);' \
      'lockPref("security.ssl3.dhe_rsa_aes_128_sha", false);' \
      'lockPref("security.ssl3.dhe_rsa_aes_256_sha", false);' \
      'lockPref("xpinstall.signatures.required", false);' \
      'lockPref("app.update.enabled", false);' \
      'lockPref("browser.shell.checkDefaultBrowser", false);' \
      > /opt/firefox52/firefox.cfg

COPY start.sh /usr/local/bin/start.sh
COPY ilo2 /usr/local/bin/ilo2
COPY idrac6 /usr/local/bin/idrac6
COPY launchd.py /usr/local/bin/launchd.py
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/ilo2 /usr/local/bin/idrac6 /usr/local/bin/launchd.py

# Xvnc :5901 and the launcher :9000 are internal (compose network) only -
# the Ruby web container serves noVNC and proxies the VNC WebSocket.
CMD ["/usr/local/bin/start.sh"]
