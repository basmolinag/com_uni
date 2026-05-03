#!/bin/bash
#
# basic_asterisk_aws.sh
# Versión no interactiva para AWS User Data.
# Sin prompts yes/no y con ajustes para cloud-init.
#
# Uso:
#   En AWS User Data como script bash
#

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/basic_asterisk_aws.log"
exec > >(tee -a "$LOG_FILE" | logger -t basic_asterisk_aws -s 2>/dev/console) 2>&1

echo "==== INICIO $(date '+%F %T') ===="

wait_for_apt() {
  local retries=60
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ||         fuser /var/lib/apt/lists/lock >/dev/null 2>&1 ||         fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    echo "[INFO] Esperando liberación de locks de apt..."
    sleep 5
    retries=$((retries - 1))
    if [[ $retries -le 0 ]]; then
      echo "[ERROR] Timeout esperando locks de apt"
      exit 1
    fi
  done
}

fetch_public_ip() {
  local ip=""
  ip="$(curl -4 -s ifconfig.me || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4 -s https://checkip.amazonaws.com || true)"
  fi
  echo "$ip"
}

wait_for_apt
apt-get update -y
wait_for_apt
apt-get upgrade -y
wait_for_apt
apt-get install -y asterisk curl net-tools ca-certificates

PRIVATE_IP="$(hostname -I | awk '{print $1}')"
PUBLIC_IP="$(fetch_public_ip)"
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="REEMPLAZAR_IP_PUBLICA"
fi

LOCAL_NET="$(echo "$PRIVATE_IP" | awk -F. 'NF==4 {printf "%s.%s.0.0/16",$1,$2}')"
if [[ -z "$LOCAL_NET" ]]; then
  LOCAL_NET="172.31.0.0/16"
fi

systemctl stop asterisk || true

mkdir -p /etc/asterisk
BACKUP_DIR="/etc/asterisk/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/asterisk/pjsip.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/asterisk/extensions.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/asterisk/rtp.conf "$BACKUP_DIR/" 2>/dev/null || true

cat > /etc/asterisk/pjsip.conf <<EOF
;
; Configuración PJSIP para laboratorios VoIP
; AWS User Data
;

[global]
type=global
max_forwards=70
default_realm=voip.local

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
external_media_address=${PUBLIC_IP}
external_signaling_address=${PUBLIC_IP}
local_net=${LOCAL_NET}

; TLS para guía 2.3 (descomentado manualmente cuando corresponda)
;[transport-tls]
;type=transport
;protocol=tls
;bind=0.0.0.0:5061
;cert_file=/etc/asterisk/keys/asterisk-cert.pem
;priv_key_file=/etc/asterisk/keys/asterisk-key.pem
;method=tlsv1_2

[endpoint_template](!)
type=endpoint
transport=transport-udp
context=internal
disallow=all
allow=ulaw
allow=alaw
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
;media_encryption=sdes
;media_encryption_optimistic=no

[auth_template](!)
type=auth
auth_type=userpass

[aor_template](!)
type=aor
max_contacts=1
remove_existing=yes

[1001](endpoint_template)
auth=auth1001
aors=1001

[auth1001](auth_template)
username=1001
password=pass1001

[1001](aor_template)

[1002](endpoint_template)
auth=auth1002
aors=1002

[auth1002](auth_template)
username=1002
password=pass1002

[1002](aor_template)

[2003](endpoint_template)
auth=auth2003
aors=2003

[auth2003](auth_template)
username=2003
password=pass2003

[2003](aor_template)

[2004](endpoint_template)
auth=auth2004
aors=2004

[auth2004](auth_template)
username=2004
password=pass2004

[2004](aor_template)
EOF

cat > /etc/asterisk/extensions.conf <<'EOF'
;
; Dialplan para laboratorios VoIP
; AWS User Data
;

[general]
static=yes
writeprotect=no
clearglobalvars=no

[globals]

[internal]
exten => 100,1,NoOp(Test de Echo 100)
 same => n,Answer()
 same => n,Playback(demo-echotest)
 same => n,Echo()
 same => n,Hangup()

exten => 9999,1,NoOp(Test de Echo 9999)
 same => n,Goto(100,1)

exten => *60,1,NoOp(Test de Echo *60)
 same => n,Goto(100,1)

exten => _[12]XXX,1,NoOp(Llamada interna a ${EXTEN})
 same => n,Dial(PJSIP/${EXTEN},30)
 same => n,Hangup()
EOF

cat > /etc/asterisk/rtp.conf <<'EOF'
;
; RTP Configuration
;

[general]
rtpstart=10000
rtpend=20000
strictrtp=yes
icesupport=yes
stunaddr=stun.l.google.com:19302
EOF

systemctl enable asterisk
systemctl restart asterisk
sleep 5

echo ""
echo "================ RESUMEN FINAL ================"
echo "IP privada servidor    : $PRIVATE_IP"
echo "IP pública servidor    : $PUBLIC_IP"
echo "local_net configurada  : $LOCAL_NET"
echo ""
echo "Extensiones:"
echo "  1001 / pass1001"
echo "  1002 / pass1002"
echo "  2003 / pass2003"
echo "  2004 / pass2004"
echo ""
echo "Dialplan:"
echo "  100  -> echo"
echo "  9999 -> alias echo"
echo "  *60  -> alias echo (útil para 2.2.2)"
echo ""
echo "Archivos:"
echo "  /etc/asterisk/pjsip.conf"
echo "  /etc/asterisk/extensions.conf"
echo "  /etc/asterisk/rtp.conf"
echo "  Backup: $BACKUP_DIR"
echo ""
echo "IMPORTANTE AWS:"
echo "  - Si cambia la IP pública, actualiza external_media_address y external_signaling_address"
echo "  - Si cambia la subred/VPC, revisa local_net"
echo ""
echo "Para Kamailio 2.1.2:"
echo "  - Softphones contra IP pública de Kamailio"
echo "  - Kamailio debe apuntar a la IP privada de este Asterisk"
echo ""
echo "Para 2.2.2:"
echo "  - Usar RTPEngine, no RTPProxy"
echo "  - Socket esperado: 127.0.0.1:22222"
echo ""
echo "Para 2.3:"
echo "  - TLS/SRTP queda comentado y se habilita después"
echo "  - Puerto TLS previsto: 5061/TCP"
echo ""
echo "Comandos útiles:"
echo "  systemctl status asterisk"
echo "  asterisk -rx 'pjsip show endpoints'"
echo "  asterisk -rx 'pjsip show contacts'"
echo "  asterisk -rx 'dialplan show internal'"
echo "==============================================="
echo "==== FIN $(date '+%F %T') ===="
