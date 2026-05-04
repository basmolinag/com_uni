#!/bin/bash
# =============================================================================
#  basic_freepbx.sh
#  Instalador Asterisk + FreePBX para Ubuntu 24.04
#  Basado en el instalador LAMP/FreePBX anterior, con fix PHP y
#  alineado con basic_asterisk.sh:
#    - Extensiones 1001, 1002, 2003, 2004
#    - Echo test 100
#    - Alias 9999 y *60
#    - Nota final en HOME con archivos/filas relevantes
#
#  Uso:
#    sudo bash basic_freepbx.sh
#    sudo bash basic_freepbx.sh -y
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
ASTERISK_DIR=""
PRIVATE_IP=""
PUBLIC_IP=""
LOCAL_NET=""
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
if [[ -z "$TARGET_HOME" ]]; then
  TARGET_HOME="/root"
fi
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
  local desc="$1"
  shift
  info "$desc"
  echo "  [CMD $(date '+%H:%M:%S')] $*" >> "$LOG_FILE"
  if ! "$@" >> "$LOG_FILE" 2>&1; then
    local rc=$?
    echo "  [FAIL $(date '+%H:%M:%S')] codigo=$rc cmd=$*" >> "$LOG_FILE"
    return "$rc"
  fi
  echo "  [DONE $(date '+%H:%M:%S')] $*" >> "$LOG_FILE"
}

banner() {
  echo -e "${BOLD}${BLUE}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║              basic_freepbx.sh  Ubuntu 24.04                 ║"
  echo "║          Asterisk 22 + FreePBX 17 + extensiones             ║"
  echo "║          1001,1002,2003,2004 + echo 100/9999/*60           ║"
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
    echo "Ultimas 60 lineas del log"
    echo "===================================================="
    tail -60 "$LOG_FILE" 2>/dev/null || true
    echo
  } | tee -a "$LOG_FILE"

  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Este script debe ejecutarse con sudo o como root"
    exit 1
  fi
}

detect_ubuntu() {
  [[ -f /etc/os-release ]] || { error "No se puede detectar el sistema operativo"; exit 1; }
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || { error "Este script está pensado para Ubuntu"; exit 1; }
  UBUNTU_VERSION="${VERSION_ID:-}"
  case "$UBUNTU_VERSION" in
    "22.04") PHP_DEFAULT="8.1" ;;
    "24.04") PHP_DEFAULT="8.3" ;;
    *) PHP_DEFAULT="8.1" ;;
  esac
  ok "Sistema detectado: Ubuntu $UBUNTU_VERSION"
  info "PHP por defecto del sistema: $PHP_DEFAULT -> se instalará PHP $PHP_TARGET"
}

check_internet() {
  info "Verificando conectividad..."
  curl -fsSL --max-time 15 https://downloads.asterisk.org/ >/dev/null
  curl -fsSL --max-time 15 https://mirror.freepbx.org/ >/dev/null
  ok "Conectividad OK"
}

detect_network() {
  PRIVATE_IP="$(hostname -I | awk '{print $1}')"
  PUBLIC_IP="$(curl -4 -s ifconfig.me || true)"
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(curl -4 -s https://checkip.amazonaws.com || true)"
  fi
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="REEMPLAZAR_IP_PUBLICA"
    warn "No se pudo detectar IP pública automáticamente. Se dejará marcador."
  fi

  LOCAL_NET="$(echo "$PRIVATE_IP" | awk -F. 'NF==4 {printf "%s.%s.0.0/16",$1,$2}')"
  if [[ -z "$LOCAL_NET" ]]; then
    LOCAL_NET="172.31.0.0/16"
  fi

  info "IP privada detectada: $PRIVATE_IP"
  info "IP pública detectada: $PUBLIC_IP"
  info "local_net detectada : $LOCAL_NET"
}

check_previous_installation() {
  step "VERIFICACION - instalaciones previas"
  local found=false

  if command -v asterisk >/dev/null 2>&1; then
    warn "Asterisk ya existe en el sistema"
    found=true
  fi
  if command -v fwconsole >/dev/null 2>&1 || [[ -d /var/www/html/admin ]]; then
    warn "FreePBX ya parece existir en el sistema"
    found=true
  fi

  if [[ "$found" == false ]]; then
    ok "No se detectaron instalaciones previas"
    return 0
  fi

  echo
  warn "Se detectaron componentes previos. Este script NO borra automáticamente toda la instalación."
  warn "Si sigues, podría superponerse con lo existente."
  if [[ "$AUTO_YES" == true ]]; then
    warn "Modo -y: se continuará sin más preguntas"
    return 0
  fi
  read -r -p "¿Deseas continuar de todos modos? [y/N]: " REPLY
  if [[ ! "${REPLY:-N}" =~ ^[Yy]$ ]]; then
    exit 0
  fi
}

install_dependencies() {
  step "PASO 1 - dependencias del sistema"
  export DEBIAN_FRONTEND=noninteractive
  run "Actualizando repositorios..." apt-get update -y
  run "Instalando dependencias base..." apt-get install -y \
    build-essential git curl wget vim unzip sox pkg-config gnupg2 \
    software-properties-common ca-certificates lsb-release \
    libedit-dev libnewt-dev libssl-dev libncurses5-dev subversion \
    libsqlite3-dev libjansson-dev libxml2-dev uuid-dev \
    default-libmysqlclient-dev htop sngrep lame ffmpeg mpg123 \
    unixodbc-dev uuid uuid-dev libasound2-dev libogg-dev libvorbis-dev \
    libicu-dev libcurl4-openssl-dev odbc-mariadb libical-dev libneon27-dev \
    libsrtp2-dev libspandsp-dev libtool-bin automake autoconf expect \
    ipset iptables fail2ban net-tools
  ok "Dependencias instaladas"
}

install_asterisk() {
  step "PASO 2 - compilar e instalar Asterisk $ASTERISK_VERSION"
  cd /usr/src
  run "Descargando Asterisk..." wget -q --show-progress "$ASTERISK_URL" -O "asterisk-${ASTERISK_VERSION}-current.tar.gz"
  run "Extrayendo Asterisk..." tar -xzf "asterisk-${ASTERISK_VERSION}-current.tar.gz"
  ASTERISK_DIR="$(find /usr/src -maxdepth 1 -type d -name "asterisk-${ASTERISK_VERSION}.*" | head -1)"
  [[ -n "$ASTERISK_DIR" ]] || { error "No se encontró el directorio extraído de Asterisk"; exit 1; }
  cd "$ASTERISK_DIR"

  run "Descargando fuentes mp3..." contrib/scripts/get_mp3_source.sh || true
  run "Instalando prerequisitos de Asterisk..." contrib/scripts/install_prereq install
  run "Ejecutando configure..." ./configure
  run "Generando menuselect.makeopts..." make menuselect.makeopts
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

  info "Compilando Asterisk (esto tarda)..."
  echo "  [CMD $(date '+%H:%M:%S')] make -j$(nproc)" >> "$LOG_FILE"
  make -j"$(nproc)" >> "$LOG_FILE" 2>&1
  run "Instalando binarios Asterisk..." make install
  run "Instalando samples..." make samples
  run "Instalando init config..." make config
  run "Actualizando linker cache..." ldconfig
  ok "Asterisk instalado"
}

configure_asterisk_runtime() {
  step "PASO 3 - usuario y permisos Asterisk"
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

  systemctl enable asterisk >> "$LOG_FILE" 2>&1 || true
  systemctl restart asterisk >> "$LOG_FILE" 2>&1 || true
  sleep 4
  systemctl is-active --quiet asterisk || { error "Asterisk no levantó correctamente"; exit 1; }
  ok "Asterisk corriendo"
}

install_php82() {
  step "PASO 4 - instalar PHP $PHP_TARGET (fix sin xmlrpc)"
  run "Agregando PPA Ondrej..." add-apt-repository ppa:ondrej/php -y
  run "Actualizando repositorios..." apt-get update -y
  run "Instalando PHP $PHP_TARGET..." apt-get install -y \
    php${PHP_TARGET} libapache2-mod-php${PHP_TARGET} \
    php${PHP_TARGET}-intl php${PHP_TARGET}-mysql php${PHP_TARGET}-curl \
    php${PHP_TARGET}-cli php${PHP_TARGET}-zip php${PHP_TARGET}-xml \
    php${PHP_TARGET}-gd php${PHP_TARGET}-common php${PHP_TARGET}-mbstring \
    php${PHP_TARGET}-bcmath php${PHP_TARGET}-sqlite3 \
    php${PHP_TARGET}-soap php${PHP_TARGET}-ldap php${PHP_TARGET}-imap \
    php-pear

  a2dismod "php${PHP_DEFAULT}" >> "$LOG_FILE" 2>&1 || true
  run "Habilitando PHP $PHP_TARGET en Apache..." a2enmod "php${PHP_TARGET}"
  run "Reiniciando Apache..." systemctl restart apache2
  update-alternatives --set php "/usr/bin/php${PHP_TARGET}" >> "$LOG_FILE" 2>&1 || true
  ok "PHP $PHP_TARGET instalado"
}

install_lamp() {
  step "PASO 5 - instalar LAMP/Node"
  run "Instalando Apache/MariaDB/Node..." apt-get install -y \
    apache2 mariadb-server mariadb-client nodejs npm bison flex openssh-server
  systemctl enable mariadb >> "$LOG_FILE" 2>&1 || true
  systemctl start mariadb >> "$LOG_FILE" 2>&1 || true

  sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf
  sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf
  sed -i 's/^\(upload_max_filesize = \).*/\120M/' /etc/php/8.2/apache2/php.ini || true
  sed -i 's/^\(memory_limit = \).*/\1256M/' /etc/php/8.2/apache2/php.ini || true
  a2enmod rewrite >> "$LOG_FILE" 2>&1 || true
  rm -f /var/www/html/index.html >> "$LOG_FILE" 2>&1 || true
  systemctl restart apache2 >> "$LOG_FILE" 2>&1 || true
  ok "LAMP base preparada"
}

configure_odbc() {
  step "PASO 6 - configurar ODBC"
  cat > /etc/odbcinst.ini <<'EOF'
[MySQL]
Description = ODBC for MySQL (MariaDB)
Driver      = /usr/lib/x86_64-linux-gnu/odbc/libmaodbc.so
FileUsage   = 1
EOF

  cat > /etc/odbc.ini <<'EOF'
[MySQL-asteriskcdrdb]
Description = MySQL connection to 'asteriskcdrdb' database
Driver      = MySQL
Server      = localhost
Database    = asteriskcdrdb
Port        = 3306
Socket      = /var/run/mysqld/mysqld.sock
Option      = 3
EOF
  ok "ODBC configurado"
}

install_freepbx() {
  step "PASO 7 - instalar FreePBX $FREEPBX_VERSION"
  cd /usr/local/src
  run "Descargando FreePBX..." wget -q --show-progress "$FREEPBX_URL" -O "freepbx-${FREEPBX_VERSION}-latest.tgz"
  run "Extrayendo FreePBX..." tar -xzf "freepbx-${FREEPBX_VERSION}-latest.tgz"
  cd freepbx

  info "Iniciando Asterisk para instalador FreePBX..."
  ./start_asterisk start >> "$LOG_FILE" 2>&1 || true

  info "Ejecutando ./install -n (esto tarda bastante)..."
  echo "  [CMD $(date '+%H:%M:%S')] ./install -n" >> "$LOG_FILE"
  ./install -n >> "$LOG_FILE" 2>&1 || true

  command -v fwconsole >/dev/null 2>&1 || { error "FreePBX no quedó instalado (fwconsole no existe)"; exit 1; }

  fwconsole chown >> "$LOG_FILE" 2>&1 || true
  fwconsole reload >> "$LOG_FILE" 2>&1 || true
  ok "FreePBX instalado"
}

install_bulkhandler() {
  step "PASO 8 - preparar Bulk Handler para importar extensiones"
  if fwconsole ma list 2>/dev/null | grep -qi bulkhandler; then
    info "Bulk Handler ya aparece en módulos"
  fi

  fwconsole ma install bulkhandler >> "$LOG_FILE" 2>&1 || true
  fwconsole ma downloadinstall bulkhandler >> "$LOG_FILE" 2>&1 || true
  fwconsole ma enable bulkhandler >> "$LOG_FILE" 2>&1 || true
  fwconsole reload >> "$LOG_FILE" 2>&1 || true

  if fwconsole bulkimport --help >> "$LOG_FILE" 2>&1; then
    ok "Bulk Handler CLI disponible"
  else
    warn "No se pudo confirmar fwconsole bulkimport. La importación podría fallar."
  fi
}

import_extensions() {
  step "PASO 9 - importar extensiones visibles en FreePBX"
  local csv="/root/basic_freepbx_extensions.csv"
  cat > "$csv" <<'EOF'
extension,name,description,tech,secret,callwaiting_enable,findmefollow_enabled,findmefollow_grplist,voicemail_enable,voicemail_vmpwd,voicemail_email,voicemail_options
1001,Ext1001,Ext1001,pjsip,pass1001,,,,,,,
1002,Ext1002,Ext1002,pjsip,pass1002,,,,,,,
2003,Ext2003,Ext2003,pjsip,pass2003,,,,,,,
2004,Ext2004,Ext2004,pjsip,pass2004,,,,,,,
EOF

  if fwconsole bulkimport --type=extensions "$csv" --replace >> "$LOG_FILE" 2>&1; then
    ok "Extensiones importadas con fwconsole bulkimport"
  elif fwconsole bi --type=extensions "$csv" --replace >> "$LOG_FILE" 2>&1; then
    ok "Extensiones importadas con fwconsole bi"
  else
    warn "No se pudo importar automáticamente con Bulk Handler."
    warn "Se dejó el CSV en $csv para importarlo manualmente desde FreePBX > Admin > Bulk Handler."
  fi

  fwconsole reload >> "$LOG_FILE" 2>&1 || true
}

apply_custom_files() {
  step "PASO 10 - aplicar custom files alineados con basic_asterisk"

  cat > /etc/asterisk/pjsip.transports_custom.conf <<EOF
; Ajustes persistentes para transportes PJSIP gestionados por FreePBX
[0.0.0.0-udp]
external_media_address=${PUBLIC_IP}
external_signaling_address=${PUBLIC_IP}
local_net=${LOCAL_NET}

; Preparado para guía 2.3 (TLS), descomentar cuando corresponda
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
  ok "Custom files aplicados"
}

configure_firewall() {
  step "PASO 11 - UFW básico"
  apt-get install -y ufw >> "$LOG_FILE" 2>&1 || true
  ufw --force reset >> "$LOG_FILE" 2>&1 || true
  ufw default deny incoming >> "$LOG_FILE" 2>&1 || true
  ufw default allow outgoing >> "$LOG_FILE" 2>&1 || true
  ufw allow 22/tcp comment 'SSH' >> "$LOG_FILE" 2>&1 || true
  ufw allow 80/tcp comment 'HTTP' >> "$LOG_FILE" 2>&1 || true
  ufw allow 443/tcp comment 'HTTPS' >> "$LOG_FILE" 2>&1 || true
  ufw allow 5060/udp comment 'SIP' >> "$LOG_FILE" 2>&1 || true
  ufw allow 5061/tcp comment 'SIP TLS' >> "$LOG_FILE" 2>&1 || true
  ufw allow 10000:20000/udp comment 'RTP' >> "$LOG_FILE" 2>&1 || true
  ufw --force enable >> "$LOG_FILE" 2>&1 || true
  ok "UFW configurado"
}

generate_note() {
  step "PASO 12 - generar nota informativa en HOME"
  cat > "$NOTE_FILE" <<EOF
basic_freepbx.sh - Resumen de instalación
=========================================

Fecha:
  $(date '+%Y-%m-%d %H:%M:%S')

Red detectada:
  IP privada servidor : ${PRIVATE_IP}
  IP pública servidor : ${PUBLIC_IP}
  local_net           : ${LOCAL_NET}

Acceso esperado a FreePBX:
  URL:
    http://${PRIVATE_IP}/admin
    o bien http://${PUBLIC_IP}/admin si la red lo permite

Extensiones alineadas con basic_asterisk.sh:
  1001 / pass1001
  1002 / pass1002
  2003 / pass2003
  2004 / pass2004

Pruebas útiles:
  100   -> echo test
  9999  -> alias a 100
  *60   -> alias a 100 (útil luego para 2.2.2)

Archivos relevantes a futuro
============================

1) /etc/asterisk/pjsip.transports_custom.conf
   Para revisar cuando cambie la IP pública o la red privada de AWS.
   Filas importantes:
     external_media_address=${PUBLIC_IP}
     external_signaling_address=${PUBLIC_IP}
     local_net=${LOCAL_NET}

2) /etc/asterisk/extensions_custom.conf
   Para revisar o cambiar:
     exten => 100
     exten => 9999
     exten => *60

3) /root/basic_freepbx_extensions.csv
   CSV usado para importar extensiones con Bulk Handler.
   Si necesitas volver a importar:
     fwconsole bulkimport --type=extensions /root/basic_freepbx_extensions.csv --replace

4) /var/log/basic_freepbx.log
   Log de instalación completo.

5) /etc/asterisk/pjsip.conf
   Archivo gestionado por FreePBX.
   Evita editarlo directo si puedes hacerlo desde GUI.
   Si lo revisas, úsalo más para observar que para intervenir.

Qué deberías preferir editar
============================
- Extensiones visibles en GUI:
  Admin > Bulk Handler
  Applications > Extensions

- Ajustes de transporte/NAT:
  /etc/asterisk/pjsip.transports_custom.conf

- Dialplan de pruebas:
  /etc/asterisk/extensions_custom.conf

Qué debes tener presente en AWS
===============================
- Si reinicias la instancia y cambia la IP pública:
  revisa pjsip.transports_custom.conf

- Si cambia la subred privada/VPC:
  revisa local_net

Asociación con guías futuras
============================
Guía 2.1.2:
  FreePBX instalado, pero si vas a trabajar con Kamailio:
  el softphone debe apuntar a Kamailio, no a esta PBX directo.

Guía 2.2.2:
  No usar RTPProxy.
  Usar RTPEngine en la VM de Kamailio.
  Puedes probar audio con *60.

Guía 2.3:
  Ya está abierto 5061/TCP en UFW.
  Falta habilitar TLS/SRTP según la guía.
EOF

  chown "${TARGET_USER}:${TARGET_USER}" "$NOTE_FILE" 2>/dev/null || true
  ok "Nota creada en $NOTE_FILE"
}

show_summary() {
  step "RESUMEN FINAL"
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║                 basic_freepbx.sh completado                 ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "FreePBX URL sugerida:"
  echo "  http://${PRIVATE_IP}/admin"
  echo ""
  echo "Extensiones esperadas en GUI:"
  echo "  1001 / pass1001"
  echo "  1002 / pass1002"
  echo "  2003 / pass2003"
  echo "  2004 / pass2004"
  echo ""
  echo "Archivos que te conviene recordar:"
  echo "  /etc/asterisk/pjsip.transports_custom.conf"
  echo "  /etc/asterisk/extensions_custom.conf"
  echo "  ${NOTE_FILE}"
  echo ""
  echo "IMPORTANTE:"
  echo "  - Este script sigue tu ruta custom sobre Ubuntu 24.04."
  echo "  - Si quieres máxima compatibilidad oficial de FreePBX 17, la base soportada es Debian 12."
  echo ""
  ok "Log completo: $LOG_FILE"
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
  detect_network
  check_previous_installation

  if [[ "$AUTO_YES" != true ]]; then
    echo -e "${YELLOW}Se instalarán Asterisk 22, PHP 8.2, Apache, MariaDB, FreePBX 17, Bulk Handler y extensiones predefinidas.${NC}"
    read -r -p "¿Deseas continuar? [y/N]: " REPLY
    if [[ ! "${REPLY:-N}" =~ ^[Yy]$ ]]; then
      exit 0
    fi
  fi

  install_dependencies
  install_asterisk
  configure_asterisk_runtime
  install_php82
  install_lamp
  configure_odbc
  install_freepbx
  install_bulkhandler
  import_extensions
  apply_custom_files
  configure_firewall
  generate_note
  show_summary
}

main "$@"
