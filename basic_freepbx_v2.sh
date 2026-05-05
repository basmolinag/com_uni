#!/bin/bash
# =============================================================================
#  basic_freepbx_v2.sh
#  Basado en la lógica original de install_pbx.sh
#  Asterisk 22 + FreePBX 17 + integración con ajustes de basic_asterisk.sh
#
#  Cambios mínimos respecto a la lógica original:
#    - Fix PHP 8.2: se elimina php8.2-xmlrpc
#    - Se agrega php-pear
#    - Se agregan extensiones 1001,1002,2003,2004 vía Bulk Handler si está disponible
#    - Se agregan 100 / 9999 / *60 en extensions_custom.conf
#    - Se crea nota final en HOME con archivos y filas relevantes
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOG_FILE="/var/log/basic_freepbx.log"
ASTERISK_VERSION="22"
FREEPBX_VERSION="17.0"
FREEPBX_URL="https://mirror.freepbx.org/modules/packages/freepbx/freepbx-${FREEPBX_VERSION}-latest.tgz"
ASTERISK_URL="https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}-current.tar.gz"
PHP_TARGET="8.2"

AUTO_YES=false
CURRENT_STEP="Inicializacion"
INSTALL_START="$(date '+%Y-%m-%d %H:%M:%S')"
UBUNTU_VERSION=""
PHP_DEFAULT=""
PRIVATE_IP=""
PUBLIC_IP=""
LOCAL_NET=""
ASTERISK_DIR=""

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
[[ -n "$TARGET_HOME" ]] || TARGET_HOME="/root"
NOTE_FILE="${TARGET_HOME}/basic_freepbx_info.txt"

if [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; then
  AUTO_YES=true
fi

_ts() { date '+%H:%M:%S'; }

log()   { echo -e "${NC}[$(_ts)] $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}[$(_ts)]  OK  $*${NC}" | tee -a "$LOG_FILE"; }
info()  { echo -e "${CYAN}[$(_ts)]  >>  $*${NC}" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[$(_ts)]  WW  $*${NC}" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[$(_ts)]  EE  $*${NC}" | tee -a "$LOG_FILE"; }

step() {
  CURRENT_STEP="$*"
  echo -e "\n${BOLD}${BLUE}[$(_ts)] === $* ===${NC}\n" | tee -a "$LOG_FILE"
}

run() {
  local desc="$1"; shift
  info "$desc"
  echo "  [CMD $(date '+%H:%M:%S')] $*" >> "$LOG_FILE"
  if ! "$@" >> "$LOG_FILE" 2>&1; then
    local rc=$?
    echo "  [FAIL $(date '+%H:%M:%S')] codigo=$rc  cmd=$*" >> "$LOG_FILE"
    return "$rc"
  fi
  echo "  [DONE $(date '+%H:%M:%S')] $*" >> "$LOG_FILE"
}

banner() {
  echo -e "${BOLD}${BLUE}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║                 basic_freepbx_v2.sh                         ║"
  echo "║  Basado en install_pbx.sh + ajustes de basic_asterisk.sh    ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

on_error() {
  local exit_code=$?
  local line_number=$1
  local failed_cmd="${BASH_COMMAND}"
  {
    echo
    echo "===================================================="
    echo "REPORTE DE ERROR - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "===================================================="
    echo "Paso donde fallo : $CURRENT_STEP"
    echo "Linea del script : $line_number"
    echo "Comando fallido  : $failed_cmd"
    echo "Codigo de salida : $exit_code"
    echo "Inicio instalac. : $INSTALL_START"
    echo "===================================================="
    echo "Ultimas 80 lineas del log"
    echo "===================================================="
    tail -80 "$LOG_FILE" 2>/dev/null || true
    echo
  } | tee -a "$LOG_FILE"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Este script debe ejecutarse como root: sudo bash basic_freepbx_v2.sh"
    exit 1
  fi
}

detect_ubuntu() {
  [[ -f /etc/os-release ]] || { error "No se puede detectar el SO."; exit 1; }
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "$ID" == "ubuntu" ]] || { error "Solo compatible con Ubuntu. SO detectado: $ID"; exit 1; }

  UBUNTU_VERSION="$VERSION_ID"
  case "$UBUNTU_VERSION" in
    "22.04") PHP_DEFAULT="8.1" ;;
    "24.04") PHP_DEFAULT="8.3" ;;
    *) PHP_DEFAULT="8.1"; warn "Ubuntu $UBUNTU_VERSION no verificado oficialmente. Continuando..." ;;
  esac

  ok "Sistema detectado: Ubuntu $UBUNTU_VERSION"
  info "PHP por defecto del sistema: $PHP_DEFAULT -> Se instalará PHP $PHP_TARGET"
}

check_internet() {
  info "Verificando conexión a internet..."
  curl -fsSL --max-time 15 https://downloads.asterisk.org/ >/dev/null
  curl -fsSL --max-time 15 https://mirror.freepbx.org/ >/dev/null
  ok "Conectividad disponible."
}

check_disk_space() {
  info "Verificando espacio en disco..."
  local free_gb
  free_gb=$(df /usr/src --output=avail -BG 2>/dev/null | tail -1 | tr -d 'G ' || true)
  if [[ -z "$free_gb" ]]; then
    free_gb=$(df / --output=avail -BG | tail -1 | tr -d 'G ')
  fi
  if [[ "$free_gb" -lt 5 ]]; then
    error "Espacio insuficiente. Se requieren al menos 5 GB libres."
    exit 1
  fi
  ok "Espacio suficiente: ${free_gb} GB libres."
}

detect_network() {
  PRIVATE_IP="$(hostname -I | awk '{print $1}')"
  PUBLIC_IP="$(curl -4 -s ifconfig.me || true)"
  [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(curl -4 -s https://checkip.amazonaws.com || true)"
  [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="REEMPLAZAR_IP_PUBLICA"
  LOCAL_NET="$(echo "$PRIVATE_IP" | awk -F. 'NF==4 {printf "%s.%s.0.0/16",$1,$2}')"
  [[ -n "$LOCAL_NET" ]] || LOCAL_NET="172.31.0.0/16"
  info "IP privada: $PRIVATE_IP"
  info "IP pública: $PUBLIC_IP"
  info "local_net : $LOCAL_NET"
}

check_previous_installation() {
  step "VERIFICACION - instalaciones previas"
  local found=false
  if command -v asterisk >/dev/null 2>&1; then
    warn "Asterisk detectado: $(asterisk -V 2>/dev/null || echo desconocida)"
    found=true
  fi
  if command -v fwconsole >/dev/null 2>&1 || [[ -d /var/www/html/admin ]]; then
    warn "FreePBX detectado en el sistema."
    found=true
  fi
  if [[ "$found" == false ]]; then
    ok "No se detectaron instalaciones previas."
    return 0
  fi
  warn "Se detectaron componentes previos."
  if [[ "$AUTO_YES" == true ]]; then
    warn "Modo -y: se continuará."
    return 0
  fi
  read -r -p "¿Deseas continuar de todos modos? [y/N]: " REPLY
  [[ "${REPLY:-N}" =~ ^[Yy]$ ]] || exit 0
}

install_dependencies() {
  step "PASO 1 - dependencias del sistema"
  export DEBIAN_FRONTEND=noninteractive
  run "Actualizando lista de paquetes..." apt-get update -y
  run "Instalando dependencias de compilación..." apt-get install -y \
    sox pkg-config libedit-dev unzip git gnupg2 curl \
    libnewt-dev libssl-dev libncurses5-dev subversion \
    libsqlite3-dev build-essential libjansson-dev libxml2-dev \
    uuid-dev software-properties-common wget ca-certificates lsb-release
  ok "Dependencias instaladas."
}

install_asterisk() {
  step "PASO 2 - descargando e instalando Asterisk $ASTERISK_VERSION"
  cd /usr/src
  info "Descargando Asterisk ${ASTERISK_VERSION}..."
  echo "  [CMD $(_ts)] wget $ASTERISK_URL" >> "$LOG_FILE"
  wget -q --show-progress "$ASTERISK_URL" -O "asterisk-${ASTERISK_VERSION}-current.tar.gz" 2>&1 | tee -a "$LOG_FILE"
  run "Extrayendo archivo..." tar -xzf "asterisk-${ASTERISK_VERSION}-current.tar.gz"

  ASTERISK_DIR=$(find /usr/src -maxdepth 1 -type d -name "asterisk-${ASTERISK_VERSION}.*" | head -1)
  [[ -n "$ASTERISK_DIR" ]] || { error "No se encontró directorio de Asterisk extraído."; exit 1; }
  info "Directorio de compilación: $ASTERISK_DIR"
  cd "$ASTERISK_DIR"

  run "Descargando fuentes MP3..." contrib/scripts/get_mp3_source.sh || true
  run "Instalando prerequisitos..." contrib/scripts/install_prereq install
  run "Ejecutando ./configure..." ./configure
  run "Generando menuselect.makeopts..." make menuselect.makeopts

  info "Configurando módulos base..."
  menuselect/menuselect \
    --enable format_mp3 \
    --enable CORE-SOUNDS-EN-WAV \
    --enable CORE-SOUNDS-EN-ULAW \
    --enable CORE-SOUNDS-EN-ALAW \
    --enable CORE-SOUNDS-EN-GSM \
    --enable MOH-OPSOUND-WAV \
    --enable MOH-OPSOUND-ULAW \
    --enable MOH-OPSOUND-ALAW \
    --enable MOH-OPSOUND-GSM \
    --enable EXTRA-SOUNDS-EN-WAV \
    --enable EXTRA-SOUNDS-EN-ULAW \
    --enable EXTRA-SOUNDS-EN-ALAW \
    --enable EXTRA-SOUNDS-EN-GSM \
    menuselect.makeopts >> "$LOG_FILE" 2>&1 || true

  info "Compilando Asterisk (puede tardar)..."
  echo "  [CMD $(_ts)] make -j$(nproc)" >> "$LOG_FILE"
  make -j"$(nproc)" >> "$LOG_FILE" 2>&1
  run "Instalando binarios..." make install
  run "Instalando configuraciones de muestra..." make samples
  run "Instalando script de inicio..." make config
  run "Actualizando librerías..." ldconfig
  ok "Asterisk instalado."
}

configure_asterisk() {
  step "PASO 3 - configurando Asterisk"
  getent group asterisk >/dev/null 2>&1 || groupadd asterisk
  id asterisk >/dev/null 2>&1 || useradd -r -d /var/lib/asterisk -g asterisk asterisk
  usermod -aG audio,dialout asterisk

  chown -R asterisk:asterisk /etc/asterisk
  chown -R asterisk:asterisk /var/{lib,log,spool}/asterisk
  chown -R asterisk:asterisk /usr/lib/asterisk || true

  if [[ -f /etc/default/asterisk ]]; then
    sed -i 's/^#*\s*AST_USER=.*/AST_USER="asterisk"/' /etc/default/asterisk
    sed -i 's/^#*\s*AST_GROUP=.*/AST_GROUP="asterisk"/' /etc/default/asterisk
  else
    printf 'AST_USER="asterisk"\nAST_GROUP="asterisk"\n' > /etc/default/asterisk
  fi

  sed -i 's/^;*\s*runuser\s*=.*/runuser = asterisk/' /etc/asterisk/asterisk.conf
  sed -i 's/^;*\s*rungroup\s*=.*/rungroup = asterisk/' /etc/asterisk/asterisk.conf

  sed -i 's|;;\[radius\]|;\[radius\]|g' /etc/asterisk/cdr.conf 2>/dev/null || true
  sed -i 's|;radiuscfg => /usr/local/etc/radiusclient-ng/radiusclient.conf|radiuscfg => /etc/radcli/radiusclient.conf|g' /etc/asterisk/cdr.conf 2>/dev/null || true
  sed -i 's|;radiuscfg => /usr/local/etc/radiusclient-ng/radiusclient.conf|radiuscfg => /etc/radcli/radiusclient.conf|g' /etc/asterisk/cel.conf 2>/dev/null || true

  run "Habilitando servicio Asterisk..." systemctl enable asterisk
  systemctl restart asterisk >> "$LOG_FILE" 2>&1
  sleep 4
  systemctl is-active --quiet asterisk || { error "Asterisk no está activo."; exit 1; }
  ok "Asterisk corriendo."
}

install_php82() {
  step "PASO 4 - instalando PHP $PHP_TARGET"
  run "Agregando PPA de Ondrej..." add-apt-repository ppa:ondrej/php -y
  run "Actualizando lista de paquetes..." apt-get update -y

  run "Instalando PHP $PHP_TARGET y extensiones..." apt-get install -y \
    php${PHP_TARGET} \
    libapache2-mod-php${PHP_TARGET} \
    php${PHP_TARGET}-intl \
    php${PHP_TARGET}-mysql \
    php${PHP_TARGET}-curl \
    php${PHP_TARGET}-cli \
    php${PHP_TARGET}-zip \
    php${PHP_TARGET}-xml \
    php${PHP_TARGET}-gd \
    php${PHP_TARGET}-common \
    php${PHP_TARGET}-mbstring \
    php${PHP_TARGET}-bcmath \
    php${PHP_TARGET}-sqlite3 \
    php${PHP_TARGET}-soap \
    php${PHP_TARGET}-ldap \
    php${PHP_TARGET}-imap \
    php-pear

  a2dismod "php${PHP_DEFAULT}" >> "$LOG_FILE" 2>&1 || true
  run "Habilitando PHP $PHP_TARGET en Apache..." a2enmod "php${PHP_TARGET}"
  run "Reiniciando Apache..." systemctl restart apache2

  update-alternatives --set php /usr/bin/php${PHP_TARGET} >> "$LOG_FILE" 2>&1 || true
  update-alternatives --set phar /usr/bin/phar${PHP_TARGET} >> "$LOG_FILE" 2>&1 || true
  update-alternatives --set phar.phar /usr/bin/phar.phar${PHP_TARGET} >> "$LOG_FILE" 2>&1 || true

  ok "PHP $PHP_TARGET instalado."
}

install_freepbx() {
  step "PASO 5 - instalando FreePBX $FREEPBX_VERSION"
  run "Instalando stack LAMP con PHP $PHP_TARGET..." apt-get install -y \
    mariadb-server apache2 \
    php${PHP_TARGET} libapache2-mod-php${PHP_TARGET} \
    php${PHP_TARGET}-intl php${PHP_TARGET}-mysql php${PHP_TARGET}-curl \
    php${PHP_TARGET}-cli php${PHP_TARGET}-zip php${PHP_TARGET}-xml \
    php${PHP_TARGET}-gd php${PHP_TARGET}-common php${PHP_TARGET}-mbstring \
    php${PHP_TARGET}-bcmath php${PHP_TARGET}-sqlite3 \
    php${PHP_TARGET}-soap php${PHP_TARGET}-ldap php${PHP_TARGET}-imap \
    php-pear \
    nodejs npm

  run "Habilitando MariaDB..." systemctl enable mariadb
  run "Iniciando MariaDB..." systemctl start mariadb

  cd /usr/src
  info "Descargando FreePBX $FREEPBX_VERSION..."
  echo "  [CMD $(_ts)] wget $FREEPBX_URL" >> "$LOG_FILE"
  wget -q --show-progress "$FREEPBX_URL" -O "freepbx-${FREEPBX_VERSION}-latest.tgz" 2>&1 | tee -a "$LOG_FILE"

  run "Extrayendo FreePBX..." tar -xzf "freepbx-${FREEPBX_VERSION}-latest.tgz"
  cd freepbx

  info "Configurando Apache (usuario asterisk + AllowOverride)..."
  sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf
  sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf

  info "Configurando upload_max_filesize en php.ini..."
  for ini_file in /etc/php/${PHP_TARGET}/apache2/php.ini /etc/php/${PHP_TARGET}/cli/php.ini; do
    if [[ -f "$ini_file" ]]; then
      sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 20M/' "$ini_file"
      echo "  [INFO] php.ini actualizado: $ini_file" >> "$LOG_FILE"
    else
      warn "No se encontró: $ini_file"
    fi
  done

  run "Habilitando mod_rewrite..." a2enmod rewrite
  run "Reiniciando Apache..." systemctl restart apache2

  info "Ejecutando instalador de FreePBX (puede tardar varios minutos)..."
  echo "  [CMD $(_ts)] ./install -n" >> "$LOG_FILE"
  ./install -n >> "$LOG_FILE" 2>&1 || true

  if command -v fwconsole >/dev/null 2>&1; then
    ok "FreePBX instalado exitosamente (fwconsole disponible)."
  else
    error "FreePBX no se instaló correctamente: fwconsole no encontrado."
    error "Revisa las últimas líneas del log: tail -120 $LOG_FILE"
    exit 1
  fi

  info "Instalando módulo pm2..."
  fwconsole ma install pm2 >> "$LOG_FILE" 2>&1 || warn "pm2 no se instaló automáticamente"
  fwconsole chown >> "$LOG_FILE" 2>&1 || true
  fwconsole reload >> "$LOG_FILE" 2>&1 || true
  ok "FreePBX configurado."
}

integrate_lab_settings() {
  step "PASO 6 - integrando ajustes de laboratorio"

  info "Instalando/activando Bulk Handler..."
  fwconsole ma install bulkhandler >> "$LOG_FILE" 2>&1 || true
  fwconsole ma downloadinstall bulkhandler >> "$LOG_FILE" 2>&1 || true
  fwconsole ma enable bulkhandler >> "$LOG_FILE" 2>&1 || true
  fwconsole reload >> "$LOG_FILE" 2>&1 || true

  local csv="/root/basic_freepbx_extensions.csv"
  cat > "$csv" <<'EOF'
extension,name,description,tech,secret
1001,Ext1001,Ext1001,pjsip,pass1001
1002,Ext1002,Ext1002,pjsip,pass1002
2003,Ext2003,Ext2003,pjsip,pass2003
2004,Ext2004,Ext2004,pjsip,pass2004
EOF

  if fwconsole bulkimport --type=extensions "$csv" --replace >> "$LOG_FILE" 2>&1; then
    ok "Extensiones importadas con fwconsole bulkimport."
  elif fwconsole bi --type=extensions "$csv" --replace >> "$LOG_FILE" 2>&1; then
    ok "Extensiones importadas con fwconsole bi."
  else
    warn "No se pudo importar automáticamente. CSV dejado en $csv"
  fi

  cat > /etc/asterisk/pjsip.transports_custom.conf <<EOF
; Ajustes persistentes para transportes PJSIP gestionados por FreePBX
[0.0.0.0-udp]
external_media_address=${PUBLIC_IP}
external_signaling_address=${PUBLIC_IP}
local_net=${LOCAL_NET}

; Preparado para guía 2.3 (TLS)
;[0.0.0.0-tls]
;external_media_address=${PUBLIC_IP}
;external_signaling_address=${PUBLIC_IP}
;local_net=${LOCAL_NET}
EOF

  cat > /etc/asterisk/extensions_custom.conf <<'EOF'
[from-internal-custom]
exten => 100,1,NoOp(Test de Echo 100)
 same => n,Answer()
 same => n,Playback(demo-echotest)
 same => n,Echo()
 same => n,Hangup()

exten => 9999,1,NoOp(Test de Echo 9999)
 same => n,Goto(100,1)

exten => *60,1,NoOp(Test de Echo *60)
 same => n,Goto(100,1)
EOF

  fwconsole chown >> "$LOG_FILE" 2>&1 || true
  fwconsole reload >> "$LOG_FILE" 2>&1 || true
  ok "Ajustes de laboratorio aplicados."
}

configure_firewall() {
  step "PASO 7 - firewall UFW"
  run "Instalando UFW..." apt-get install -y ufw
  ufw --force reset >> "$LOG_FILE" 2>&1 || true
  ufw default deny incoming >> "$LOG_FILE" 2>&1 || true
  ufw default allow outgoing >> "$LOG_FILE" 2>&1 || true
  ufw allow 22/tcp comment 'SSH' >> "$LOG_FILE" 2>&1 || true
  ufw allow 80/tcp comment 'HTTP' >> "$LOG_FILE" 2>&1 || true
  ufw allow 443/tcp comment 'HTTPS' >> "$LOG_FILE" 2>&1 || true
  ufw allow 5060/udp comment 'SIP' >> "$LOG_FILE" 2>&1 || true
  ufw allow 5061/tcp comment 'SIP TLS' >> "$LOG_FILE" 2>&1 || true
  ufw allow 10000:20000/udp comment 'RTP audio' >> "$LOG_FILE" 2>&1 || true
  ufw --force enable >> "$LOG_FILE" 2>&1 || true
  ok "Firewall configurado."
}

generate_note() {
  step "PASO 8 - generando nota en HOME"
  cat > "$NOTE_FILE" <<EOF
basic_freepbx_v2.sh - Resumen de instalación
===========================================

Fecha:
  $(date '+%Y-%m-%d %H:%M:%S')

Red detectada:
  IP privada servidor : ${PRIVATE_IP}
  IP pública servidor : ${PUBLIC_IP}
  local_net           : ${LOCAL_NET}

Acceso esperado a FreePBX:
  http://${PRIVATE_IP}/admin
  o bien http://${PUBLIC_IP}/admin si aplica

Extensiones integradas:
  1001 / pass1001
  1002 / pass1002
  2003 / pass2003
  2004 / pass2004

Pruebas añadidas:
  100   -> echo test
  9999  -> alias a 100
  *60   -> alias a 100 (útil para 2.2.2)

Archivos relevantes y qué mirar
===============================

1) /etc/asterisk/pjsip.transports_custom.conf
   Para revisar si cambia la IP pública o la VPC.
   Filas relevantes:
     external_media_address=${PUBLIC_IP}
     external_signaling_address=${PUBLIC_IP}
     local_net=${LOCAL_NET}

2) /etc/asterisk/extensions_custom.conf
   Para revisar o cambiar:
     exten => 100
     exten => 9999
     exten => *60

3) /root/basic_freepbx_extensions.csv
   CSV usado para importar extensiones visibles en FreePBX.

4) /var/log/basic_freepbx.log
   Log completo de instalación.

5) /etc/php/${PHP_TARGET}/apache2/php.ini
   Línea importante:
     upload_max_filesize = 20M

Qué preferir tocar a futuro
===========================
- Extensiones:
  GUI de FreePBX (Applications/Extensions o Admin/Bulk Handler)
- Transporte/NAT:
  /etc/asterisk/pjsip.transports_custom.conf
- Dialplan de prueba:
  /etc/asterisk/extensions_custom.conf

Asociación con guías futuras
============================
2.1.2:
  Con FreePBX, las extensiones deberían quedar visibles en GUI.

2.2.2:
  No usar RTPProxy.
  Usar RTPEngine en la VM de Kamailio.
  Puedes probar audio con *60.

2.3:
  Ya quedó contemplado 5061/TCP en firewall.
  Falta habilitar TLS/SRTP según la guía.
EOF

  chown "${TARGET_USER}:${TARGET_USER}" "$NOTE_FILE" 2>/dev/null || true
  ok "Nota creada en $NOTE_FILE"
}

show_summary() {
  step "RESUMEN FINAL"
  echo ""
  echo "URL sugerida: http://${PRIVATE_IP}/admin"
  echo "Extensiones esperadas en GUI: 1001, 1002, 2003, 2004"
  echo "Pruebas: 100 / 9999 / *60"
  echo "Nota final: $NOTE_FILE"
  echo ""
  ok "Log completo: $LOG_FILE"
  warn "Ruta custom sobre Ubuntu 24.04. La base oficial de FreePBX 17 sigue siendo Debian 12."
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"

  banner
  {
    echo "===================================================="
    echo "INICIO DE INSTALACION: $INSTALL_START"
    echo "Usuario objetivo nota : $TARGET_USER"
    echo "Home objetivo nota    : $TARGET_HOME"
    echo "===================================================="
  } | tee -a "$LOG_FILE"

  check_root
  detect_ubuntu
  check_internet
  check_disk_space
  detect_network
  check_previous_installation

  echo -e "\n${BOLD}Se instalarán:${NC}"
  echo -e "  * Dependencias del sistema"
  echo -e "  * Asterisk $ASTERISK_VERSION (compilado desde fuente)"
  echo -e "  * PHP $PHP_TARGET (fix sin xmlrpc)"
  echo -e "  * FreePBX $FREEPBX_VERSION"
  echo -e "  * Integración de extensiones 1001/1002/2003/2004"
  echo -e "  * Dialplan 100 / 9999 / *60"
  echo -e "  * Nota final en HOME"
  echo -e "\nPara seguir el log: ${CYAN}tail -f $LOG_FILE${NC}\n"

  if [[ "$AUTO_YES" != true ]]; then
    read -r -p "¿Deseas continuar? [y/N]: " REPLY
    [[ "${REPLY:-N}" =~ ^[Yy]$ ]] || exit 0
  fi

  install_dependencies
  install_asterisk
  configure_asterisk
  install_php82
  install_freepbx
  integrate_lab_settings
  configure_firewall
  generate_note
  show_summary
}

main "$@"
