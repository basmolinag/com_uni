#!/bin/bash
#
# basic_asterisk.sh
# Instalación básica de Asterisk para guía 2.1.2 / 2.2.2
# Basado en el script original del laboratorio, con cambios mínimos.
#
# Uso:
#   sudo bash basic_asterisk.sh
#   sudo bash basic_asterisk.sh -y
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

AUTO_YES=false
if [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; then
    AUTO_YES=true
fi

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ ERROR: $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

if [[ $EUID -ne 0 ]]; then
    print_error "Este script debe ejecutarse como root (usa sudo)"
    exit 1
fi

if ! grep -q "Ubuntu" /etc/os-release; then
    print_error "Este script está diseñado para Ubuntu"
    exit 1
fi

print_header "Instalación básica de Asterisk (Labs 2.1.2 / 2.2.2 / 2.3)"

PRIVATE_IP="$(hostname -I | awk '{print $1}')"
PUBLIC_IP="$(curl -4 -s ifconfig.me || true)"
if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(curl -4 -s https://checkip.amazonaws.com || true)"
fi
if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="REEMPLAZAR_IP_PUBLICA"
fi

LOCAL_NET="$(echo "$PRIVATE_IP" | awk -F. 'NF==4 {printf "%s.%s.0.0/16",$1,$2}')"
if [[ -z "$LOCAL_NET" ]]; then
    LOCAL_NET="172.31.0.0/16"
fi

echo ""
echo "Información de red detectada:"
echo "  IP Privada : $PRIVATE_IP"
echo "  IP Pública : $PUBLIC_IP"
echo "  Local Net  : $LOCAL_NET"
echo ""

print_header "Paso 1: Actualizando sistema"
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt upgrade -y
print_success "Sistema actualizado"

print_header "Paso 2: Instalando Asterisk"
apt install -y asterisk curl net-tools ca-certificates
print_success "Asterisk instalado"

if ! command -v asterisk >/dev/null 2>&1; then
    print_error "Asterisk no se instaló correctamente"
    exit 1
fi

ASTERISK_VERSION="$(asterisk -V || true)"
print_success "Versión instalada: $ASTERISK_VERSION"

print_header "Paso 3: Preparando configuración"
systemctl stop asterisk || true
print_success "Asterisk detenido para configuración"

print_header "Paso 4: Respaldo de configuraciones originales"
BACKUP_DIR="/etc/asterisk/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/asterisk/pjsip.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/asterisk/extensions.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/asterisk/rtp.conf "$BACKUP_DIR/" 2>/dev/null || true
print_success "Backup creado en: $BACKUP_DIR"

print_header "Paso 5: Configurando PJSIP"

cat > /etc/asterisk/pjsip.conf <<EOF
;
; Configuración PJSIP para laboratorios VoIP
; Guías 2.1.2 / 2.2.2 / 2.3
;

[global]
type=global
max_forwards=70
default_realm=voip.local

; ==============================================
; TRANSPORTS
; ==============================================

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
external_media_address=${PUBLIC_IP}
external_signaling_address=${PUBLIC_IP}
local_net=${LOCAL_NET}

; Descomentar para Lab 2.3 (TLS)
;[transport-tls]
;type=transport
;protocol=tls
;bind=0.0.0.0:5061
;cert_file=/etc/asterisk/keys/asterisk-cert.pem
;priv_key_file=/etc/asterisk/keys/asterisk-key.pem
;method=tlsv1_2

; ==============================================
; TEMPLATES
; ==============================================

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

; ==============================================
; EXTENSIONES
; ==============================================

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

print_success "Archivo /etc/asterisk/pjsip.conf creado"

print_header "Paso 6: Configurando dialplan"

cat > /etc/asterisk/extensions.conf <<'EOF'
;
; Dialplan para laboratorios VoIP
; Guías 2.1.2 / 2.2.2 / 2.3
;

[general]
static=yes
writeprotect=no
clearglobalvars=no

[globals]

[internal]
; Echo test solicitado en 2.1.2
exten => 100,1,NoOp(Test de Echo 100)
 same => n,Answer()
 same => n,Playback(demo-echotest)
 same => n,Echo()
 same => n,Hangup()

; Alias útil por compatibilidad con script original
exten => 9999,1,NoOp(Test de Echo 9999)
 same => n,Goto(100,1)

; Alias útil para 2.2.2
exten => *60,1,NoOp(Test de Echo *60)
 same => n,Goto(100,1)

; Llamadas entre extensiones configuradas
exten => _[12]XXX,1,NoOp(Llamada interna a ${EXTEN})
 same => n,Dial(PJSIP/${EXTEN},30)
 same => n,Hangup()
EOF

print_success "Archivo /etc/asterisk/extensions.conf creado"

print_header "Paso 7: Configurando RTP"

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

print_success "Archivo /etc/asterisk/rtp.conf creado"

print_header "Paso 8: Habilitando e iniciando Asterisk"
systemctl enable asterisk
systemctl start asterisk
sleep 3

if systemctl is-active --quiet asterisk; then
    print_success "Asterisk está corriendo"
else
    print_error "Asterisk no se inició correctamente"
    print_info "Ver logs: sudo journalctl -u asterisk -n 50"
    exit 1
fi

print_header "Paso 9: Verificación final"

if ss -ulpn | grep -q ":5060"; then
    print_success "Puerto 5060/UDP escuchando"
else
    print_warning "Puerto 5060/UDP no está escuchando"
fi

ENDPOINTS="$(asterisk -rx "pjsip show endpoints" 2>/dev/null | grep -E "1001|1002|2003|2004" | wc -l || true)"
if [[ "${ENDPOINTS:-0}" -ge 4 ]]; then
    print_success "Las 4 extensiones quedaron cargadas"
else
    print_warning "Revisa pjsip show endpoints; no se detectaron las 4 extensiones"
fi

print_header "RESUMEN FINAL"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║          ASTERISK BÁSICO INSTALADO CORRECTAMENTE          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Red detectada:"
echo "  ├─ IP privada servidor : $PRIVATE_IP"
echo "  ├─ IP pública servidor : $PUBLIC_IP"
echo "  └─ local_net           : $LOCAL_NET"
echo ""
echo "Extensiones configuradas:"
echo "  ├─ 1001 / pass1001"
echo "  ├─ 1002 / pass1002"
echo "  ├─ 2003 / pass2003"
echo "  └─ 2004 / pass2004"
echo ""
echo "Dialplan útil:"
echo "  ├─ 100   = Echo test"
echo "  ├─ 9999  = Alias a 100"
echo "  ├─ *60   = Alias a 100 (útil para guía 2.2.2)"
echo "  └─ _[12]XXX = llamadas internas"
echo ""
echo "Archivos clave:"
echo "  ├─ /etc/asterisk/pjsip.conf"
echo "  ├─ /etc/asterisk/extensions.conf"
echo "  ├─ /etc/asterisk/rtp.conf"
echo "  └─ Backup: $BACKUP_DIR"
echo ""
echo "IMPORTANTE para AWS:"
echo "  ├─ Si reinicias la instancia, la IP pública puede cambiar"
echo "  ├─ Si cambia, revisa /etc/asterisk/pjsip.conf"
echo "  │    external_media_address=$PUBLIC_IP"
echo "  │    external_signaling_address=$PUBLIC_IP"
echo "  └─ Si cambia la red privada/VPC, revisa local_net=$LOCAL_NET"
echo ""
echo "Para guía 2.1.2 (Kamailio):"
echo "  ├─ El softphone debe apuntar a la IP pública de Kamailio, no a esta PBX"
echo "  └─ En Kamailio debes usar la IP privada de este Asterisk como backend"
echo ""
echo "Para guía 2.2.2:"
echo "  ├─ No uses RTPProxy en Ubuntu 24.04"
echo "  ├─ Usa RTPEngine"
echo "  └─ La guía 2.2.2 pide socket 127.0.0.1:22222 en Kamailio/RTPEngine"
echo ""
echo "Para guía 2.3:"
echo "  ├─ Debes habilitar TLS en pjsip.conf"
echo "  ├─ Debes generar/instalar certificados"
echo "  └─ Debes abrir 5061/TCP si el diseño lo requiere"
echo ""
echo "Comandos útiles:"
echo "  ├─ sudo asterisk -rvvv"
echo "  ├─ asterisk -rx 'pjsip show endpoints'"
echo "  ├─ asterisk -rx 'pjsip show contacts'"
echo "  ├─ asterisk -rx 'dialplan show internal'"
echo "  └─ sudo systemctl restart asterisk"
echo ""
print_success "Instalación completada"
