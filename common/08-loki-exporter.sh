#!/bin/sh

#
# Adds logs dumps to loki via a local promtail install
#

HOSTNAME=$(uci get system.@system[0].hostname)
LOKI_AUTH_USERNAME="LokiAuthUsername"
LOKI_AUTH_PASSWORD="LokiAuthPassword"

# Install
cd /tmp
wget https://github.com/grafana/loki/releases/download/v2.9.10/promtail-linux-arm64.zip
unzip -o promtail-linux-arm64.zip
mv promtail-linux-arm64 /usr/bin/promtail
chmod +x /usr/bin/promtail
rm promtail-linux-arm64.zip

# Creting the config
mkdir -p /etc/promtail
cat > /etc/promtail/config.yml << EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki.homelab:3100/loki/api/v1/push
    basic_auth:
      username: ${LOKI_AUTH_USERNAME}
      password: ${LOKI_AUTH_PASSWORD}

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: ${HOSTNAME}
          __path__: /var/log/messages

  - job_name: kernel
    static_configs:
      - targets:
          - localhost
        labels:
          job: ${HOSTNAME}
          __path__: /var/log/kern.log
EOF

# Getting the service going
cat > /etc/init.d/promtail << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/promtail -config.file=/etc/promtail/config.yml
    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-5}
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF

chmod +x /etc/init.d/promtail

/etc/init.d/promtail enable
/etc/init.d/promtail start
sleep 2

