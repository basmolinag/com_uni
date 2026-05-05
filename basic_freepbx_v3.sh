#!/bin/bash
# =============================================================================
#  basic_freepbx_v3.sh
#  Basado en la lógica del script original de FreePBX/Asterisk
#  + fix PHP 8.2
#  + integración de ajustes del lab:
#      - extensiones 1001, 1002, 2003, 2004
#      - echo test 100
#      - alias 9999 y *60
#      - nota final en HOME con rutas relevantes
#
#  Uso:
#    sudo bash basic_freepbx_v3.sh
#    sudo bash basic_freepbx_v3.sh -y
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
    echo "  [FAIL $(date '+%H:%M:%S')] codigo=$rc cmd=$*" >> "$LOG_FILE"
    return "$rc"
  fi
  echo "  [DONE $(date '+%H:%M:%S')] $*" >> "$LOG_FILE"
}

banner() {
  echo -e "${BOLD}${BLUE}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║                   basic_freepbx_v3.sh                       ║"
  echo "║        Base original FreePBX + ajustes de laboratorio       ║"
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
    echo "ULTIMAS 100 LINEAS DEL LOG"
    echo "===================================================="
    tail -100 "$LOG_FILE" 2>/dev/null || true
    echo
  } | tee -a "$LOG_FILE"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Este script debe ejecutarse con sudo o root"
    exit 1
  fi
}

detect_ubuntu() {
  [[ -f /etc/os-release ]] || { error "No se puede detectar el sistema operativo"; exit 1; }
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || { error "Solo compatible con Ubuntu"; exit 1; }

  UBUNTU_VERSION="${VERSION_ID:-}"
  case "$UBUNTU_VERSION" in
    "22.04") PHP_DEFAULT="8.1" ;;
    "24.04") PHP_DEFAULT="8.3" ;;
    *) PHP_DEFAULT="8.1"; warn "Ubuntu $UBUNTU_VERSION no verificado oficialmente" ;;
  esac

  ok "Sistema detectado: Ubuntu $UBUNTU_VERSION"
  info "PHP por defecto: $PHP_DEFAULT -> objetivo: $PHP_TARGET"
}

check_internet() {
  info "Verificando conectividad..."
  curl -fsSL --max-time 15 https://downloads.asterisk.org/ >/dev/null
  curl -fsSL --max-time 15 https://mirror.freepbx.org/ >/dev/null
  ok "Conectividad OK"
}

check_disk_space() {
  info "Verificando espacio..."
  local free_gb
  free_gb="$(df /usr/src --output=avail -BG 2>/dev/null | tail -1 | tr -d 'G ' || true)"
  [[ -n "$free_gb" ]] || free_gb="$(df / --output=avail -BG | tail -1 | tr -d 'G ')"
  if [[ "$free_gb" -lt 5 ]]; then
    error "Espacio insuficiente. Se requieren al menos 5 GB libres"
    exit 1
  fi
  ok "Espacio suficiente: ${free_gb} GB"
}

detect_network() {
  PRIVATE_IP="$(hostname -I | awk '{print $1}')"
  PUBLIC_IP="$(curl -4 -s ifconfig.me || true)"
  [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(curl -4 -s https://checkip.amazonaws.com || true)"
  [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="REEMPLAZAR_IP_PUBLICA"

  LOCAL_NET="$(echo "$PRIVATE_IP" | awk -F. 'NF==4 {printf "%s.%s.0.0/16",$1,$2}')"
  [[ -n "$LOCAL_NET" ]] || LOCAL_NET="172.31.0.0/16"

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

  warn "Se detectaron componentes previos. Para una prueba real del instalador, parte desde VM limpia."
  if [[ "$AUTO_YES" == true ]]; then
    warn "Modo -y: se continuará"
    return 0
  fi
  read -r -p "¿Deseas continuar de todos modos? [y/N]: " REPLY
  [[ "${REPLY:-N}" =~ ^[Yy]$ ]] || exit 0
}

install_dependencies() {
  step "PASO 1 - dependencias del sistema"
  export DEBIAN_FRONTEND=noninteractive
  run "Actualizando repositorios..." apt-get update -y
  run "Instalando dependencias base..." apt-get install -y \
    sox pkg-config libedit-dev unzip git gnupg2 curl \
    libnewt-dev libssl-dev libncurses5-dev subversion \
    libsqlite3-dev build-essential libjansson-dev libxml2-dev \
    uuid-dev software-properties-common wget ca-certificates lsb-release \
    build-essential git curl wget vim unzip sox pkg-config \
    net-tools htop sngrep fail2ban iptables ipset
  ok "Dependencias instaladas"
}

install_asterisk() {
  step "PASO 2 - Asterisk $ASTERISK_VERSION"
  cd /usr/src

  info "Descargando Asterisk..."
  echo "  [CMD $(_ts)] wget $ASTERISK_URL" >> "$LOG_FILE"
  wget -q --show-progress "$ASTERISK_URL" -O "asterisk-${ASTERISK_VERSION}-current.tar.gz" 2>&1 | tee -a "$LOG_FILE"

  run "Extrayendo Asterisk..." tar -xzf "asterisk-${ASTERISK_VERSION}-current.tar.gz"
  ASTERISK_DIR="$(find /usr/src -maxdepth 1 -type d -name "asterisk-${ASTERISK_VERSION}.*" | head -1)"
  [[ -n "$ASTERISK_DIR" ]] || { error "No se encontró el directorio extraído de Asterisk"; exit 1; }
  cd "$ASTERISK_DIR"

  run "Descargando fuentes MP3..." contrib/scripts/get_mp3_source.sh || true
  run "Instalando prerequisitos..." contrib/scripts/install_prereq install
  run "Ejecutando configure..." ./configure
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

  info "Compilando Asterisk (esto tarda)..."
  echo "  [CMD $(_ts)] make -j$(nproc)" >> "$LOG_FILE"
  make -j"$(nproc)" >> "$LOG_FILE" 2>&1
  run "Instalando binarios..." make install
  run "Instalando samples..." make samples
  run "Instalando init config..." make config
  run "Actualizando linker cache..." ldconfig
  ok "Asterisk instalado"
}

configure_asterisk_runtime() {
  step "PASO 3 - runtime Asterisk"
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
  systemctl is-active --quiet asterisk || { error "Asterisk no levantó correctamente"; exit 1; }
  ok "Asterisk corriendo"
}

install_php82() {
  step "PASO 4 - PHP $PHP_TARGET"
  run "Agregando PPA Ondrej..." add-apt-repository ppa:ondrej/php -y
  run "Actualizando repositorios..." apt-get update -y

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
  update-alternatives --set php "/usr/bin/php${PHP_TARGET}" >> "$LOG_FILE" 2>&1 || true
  update-alternatives --set phar "/usr/bin/phar${PHP_TARGET}" >> "$LOG_FILE" 2>&1 || true
  update-alternatives --set phar.phar "/usr/bin/phar.phar${PHP_TARGET}" >> "$LOG_FILE" 2>&1 || true
  ok "PHP $PHP_TARGET instalado"
}

ensure_apache_layout() {
  if [[ -f /etc/apache2/apache2.conf ]]; then
    return 0
  fi

  warn "No existe /etc/apache2/apache2.conf. Intentando reinstalar Apache..."
  apt-get install --reinstall -y apache2 >> "$LOG_FILE" 2>&1 || true

  if [[ ! -f /etc/apache2/apache2.conf ]]; then
    error "Apache no dejó /etc/apache2/apache2.conf. El sistema no está en estado sano para seguir."
    error "Esto apunta a un problema de paquetes o a una VM ya contaminada."
    exit 1
  fi
}

install_freepbx() {
  step "PASO 5 - FreePBX $FREEPBX_VERSION"

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
  run "Habilitando Apache..." systemctl enable apache2
  run "Iniciando Apache..." systemctl start apache2

  ensure_apache_layout

  cd /usr/src
  info "Descargando FreePBX..."
  echo "  [CMD $(_ts)] wget $FREEPBX_URL" >> "$LOG_FILE"
  wget -q --show-progress "$FREEPBX_URL" -O "freepbx-${FREEPBX_VERSION}-latest.tgz" 2>&1 | tee -a "$LOG_FILE"

  run "Extrayendo FreePBX..." tar -xzf "freepbx-${FREEPBX_VERSION}-latest.tgz"
  cd freepbx

  info "Configurando Apache (usuario asterisk + AllowOverride)..."
  sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf
  sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf
  ok "Apache configurado"

  info "Configurando php.ini si existe..."
  for ini_file in "/etc/php/${PHP_TARGET}/apache2/php.ini" "/etc/php/${PHP_TARGET}/cli/php.ini"; do
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
    ok "FreePBX instalado (fwconsole disponible)"
  else
    error "FreePBX no se instaló correctamente: fwconsole no encontrado"
    error "Revisa desde la primera aparición de ./install -n en el log"
    exit 1
  fi

  info "Instalando módulo pm2..."
  fwconsole ma install pm2 >> "$LOG_FILE" 2>&1 || warn "pm2 no se instaló automáticamente"
  fwconsole chown >> "$LOG_FILE" 2>&1 || true
  fwconsole reload >> "$LOG_FILE" 2>&1 || true
  ok "FreePBX configurado"
}

integrate_lab_settings() {
  step "PASO 6 - ajustes de laboratorio"

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
    ok "Extensiones importadas con fwconsole bulkimport"
  elif fwconsole bi --type=extensions "$csv" --replace >> "$LOG_FILE" 2>&1; then
    ok "Extensiones importadas con fwconsole bi"
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
  ok "Ajustes de laboratorio aplicados"
}

configure_firewall() {
  step "PASO 7 - UFW"
  run "Instalando UFW..." apt-get install -y ufw
  info "Aplicando reglas VoIP..."
  ufw --force reset >> "$LOG_FILE" 2>&1
  ufw default deny incoming >> "$LOG_FILE" 2>&1
  ufw default allow outgoing >> "$LOG_FILE" 2>&1
  ufw allow 22/tcp comment 'SSH' >> "$LOG_FILE" 2>&1
  ufw allow 80/tcp comment 'HTTP' >> "$LOG_FILE" 2>&1
  ufw allow 443/tcp comment 'HTTPS' >> "$LOG_FILE" 2>&1
  ufw allow 5060/udp comment 'SIP' >> "$LOG_FILE" 2>&1
  ufw allow 5061/tcp comment 'SIP TLS' >> "$LOG_FILE" 2>&1
  ufw allow 10000:20000/udp comment 'RTP Audio' >> "$LOG_FILE" 2>&1
  ufw --force enable >> "$LOG_FILE" 2>&1
  ok "Firewall configurado"
}

generate_note() {
  step "PASO 8 - nota final en HOME"
  cat > "$NOTE_FILE" <<EOF
basic_freepbx_v3.sh - Resumen de instalación
===========================================

Fecha:
  $(date '+%Y-%m-%d %H:%M:%S')

Red detectada:
  IP privada servidor : ${PRIVATE_IP}
  IP pública servidor : ${PUBLIC_IP}
  local_net           : ${LOCAL_NET}

Acceso esperado a FreePBX:
  http://${PRIVATE_IP}/admin
  o http://${PUBLIC_IP}/admin

Extensiones alineadas:
  1001 / pass1001
  1002 / pass1002
  2003 / pass2003
  2004 / pass2004

Pruebas:
  100   -> echo test
  9999  -> alias a 100
  *60   -> alias a 100

Archivos relevantes:
  /etc/asterisk/pjsip.transports_custom.conf
  /etc/asterisk/extensions_custom.conf
  /root/basic_freepbx_extensions.csv
  /var/log/basic_freepbx.log

Filas que te conviene revisar:
  En /etc/asterisk/pjsip.transports_custom.conf:
    external_media_address=${PUBLIC_IP}
    external_signaling_address=${PUBLIC_IP}
    local_net=${LOCAL_NET}

  En /etc/asterisk/extensions_custom.conf:
    exten => 100
    exten => 9999
    exten => *60

Qué recordar en AWS:
  - Si cambia la IP pública, revisa external_media_address/external_signaling_address
  - Si cambia la subred privada/VPC, revisa local_net

Relación con laboratorios:
  - 2.1.2: si usas Kamailio, los softphones deben apuntar a Kamailio, no a la PBX
  - 2.2.2: usar RTPEngine, no RTPProxy
  - 2.3: esta base ya deja 5061/TCP abierto para que luego habilites TLS/SRTP
EOF
  chown "${TARGET_USER}:${TARGET_USER}" "$NOTE_FILE" 2>/dev/null || true
  ok "Nota creada en $NOTE_FILE"
}

show_summary() {
  step "RESUMEN FINAL"
  echo
  echo "URL sugerida: http://${PRIVATE_IP}/admin"
  echo "Extensiones esperadas: 1001,1002,2003,2004"
  echo "Echo tests: 100,9999,*60"
  echo "Nota final: $NOTE_FILE"
  echo
  ok "Log completo: $LOG_FILE"
  warn "Si quieres probar el instalador de verdad, usa VM nueva."
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

  if [[ "$AUTO_YES" != true ]]; then
    echo -e "${YELLOW}Se instalarán Asterisk 22, PHP 8.2, Apache, MariaDB, FreePBX 17 y ajustes de laboratorio.${NC}"
    read -r -p "¿Deseas continuar? [y/N]: " REPLY
    [[ "${REPLY:-N}" =~ ^[Yy]$ ]] || exit 0
  fi

  install_dependencies
  install_asterisk
  configure_asterisk_runtime
  install_php82
  install_freepbx
  integrate_lab_settings
  configure_firewall
  generate_note
  show_summary
}

main "$@"
