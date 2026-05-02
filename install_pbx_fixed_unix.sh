#!/bin/bash
# =============================================================================
#  install_pbx.sh
#  Instalador automático de Asterisk 22 + FreePBX 17
#  Compatible con Ubuntu 22.04 LTS y Ubuntu 24.04 LTS
#
#  Autor:   CUY5132 — Comunicaciones Unificadas y VoIP — DUOC UC
#  Versión: 4.2
#  Uso:     sudo bash install_pbx.sh
# =============================================================================

set -euo pipefail

# ─── Colores ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Configuración ────────────────────────────────────────────────────────────
LOG_FILE="/var/log/install_pbx.log"
ASTERISK_VERSION="22"
FREEPBX_VERSION="17.0"
FREEPBX_URL="https://mirror.freepbx.org/modules/packages/freepbx/freepbx-${FREEPBX_VERSION}-latest.tgz"
ASTERISK_URL="https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}-current.tar.gz"
PHP_TARGET="8.2"

CURRENT_STEP="Inicializacion"
INSTALL_START="$(date '+%Y-%m-%d %H:%M:%S')"
UBUNTU_VERSION=""
PHP_DEFAULT=""
ASTERISK_DIR=""

# ─── Funciones de logging ─────────────────────────────────────────────────────
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
    echo "  [FAIL $(date '+%H:%M:%S')] codigo=$rc  cmd=$*" >> "$LOG_FILE"
    return "$rc"
  fi
  echo "  [DONE $(date '+%H:%M:%S')] $*" >> "$LOG_FILE"
}

banner() {
  echo -e "${BOLD}${BLUE}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║        Instalador PBX — Asterisk 22 + FreePBX 17            ║"
  echo "║        CUY5132 — DUOC UC  |  Ubuntu 22.04 / 24.04           ║"
  echo "║        Version 4.2  —  Log: /var/log/install_pbx.log        ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ─── Manejador de errores ─────────────────────────────────────────────────────
on_error() {
  local exit_code=$?
  local line_number=$1
  local failed_cmd="${BASH_COMMAND}"

  {
    echo
    echo "===================================================="
    echo "  REPORTE DE ERROR  —  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "===================================================="
    echo "  Paso donde fallo : $CURRENT_STEP"
    echo "  Linea del script : $line_number"
    echo "  Comando fallido  : $failed_cmd"
    echo "  Codigo de salida : $exit_code"
    echo "  Inicio instalac. : $INSTALL_START"
    echo "===================================================="
    echo "  INFORMACION DEL SISTEMA"
    echo "===================================================="
    echo "  Hostname     : $(hostname)"
    echo "  SO           : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
    echo "  Kernel       : $(uname -r)"
    echo "  Arquitectura : $(uname -m)"
    echo
    echo "  Memoria RAM:"
    free -h | awk 'NR==2{printf "    Total: %-8s  Usado: %-8s  Libre: %s\n", $2, $3, $4}'
    echo
    echo "  Espacio en disco:"
    df -h /usr/src / 2>/dev/null | awk 'NR>1{printf "    %-12s Total: %-8s  Usado: %-8s  Libre: %s (%s)\n", $6, $2, $3, $4, $5}'
    echo "===================================================="
    echo "  ESTADO DE SERVICIOS"
    echo "===================================================="
    for svc in asterisk apache2 mariadb; do
      printf "  %-12s : %s\n" "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo 'no instalado')"
    done
    echo "===================================================="
    echo "  VERSIONES DETECTADAS"
    echo "===================================================="
    echo "  PHP activo : $(php -v 2>/dev/null | head -1 || echo 'no instalado')"
    echo "  Node.js    : $(node -v 2>/dev/null || echo 'no instalado')"
    echo "  MariaDB    : $(mysql --version 2>/dev/null || echo 'no instalado')"
    echo "===================================================="
    echo "  ULTIMAS 50 LINEAS DEL LOG"
    echo "===================================================="
    tail -50 "$LOG_FILE" 2>/dev/null || true
    echo
  } | tee -a "$LOG_FILE"

  exit "$exit_code"
}

trap 'on_error $LINENO' ERR

# ─── Verificaciones previas ───────────────────────────────────────────────────
check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Este script debe ejecutarse como root: sudo bash install_pbx.sh"
    exit 1
  fi
}

detect_ubuntu() {
  [[ -f /etc/os-release ]] || { error "No se puede detectar el SO."; exit 1; }
  # shellcheck disable=SC1091
  source /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || {
    error "Solo compatible con Ubuntu. SO detectado: ${ID:-desconocido}"
    exit 1
  }

  UBUNTU_VERSION="${VERSION_ID:-}"
  case "$UBUNTU_VERSION" in
    "22.04") PHP_DEFAULT="8.1" ;;
    "24.04") PHP_DEFAULT="8.3" ;;
    *)
      PHP_DEFAULT="8.1"
      warn "Ubuntu $UBUNTU_VERSION no verificado oficialmente. Continuando..."
      ;;
  esac

  ok "Sistema detectado: Ubuntu $UBUNTU_VERSION"
  info "PHP por defecto del sistema: $PHP_DEFAULT  ->  Se instalara PHP $PHP_TARGET"
}

check_internet() {
  info "Verificando conexion a internet..."
  if ! curl -fsSL --max-time 15 https://downloads.asterisk.org/ > /dev/null; then
    error "Sin conexion a internet o el servidor de Asterisk no responde."
    exit 1
  fi
  ok "Conexion a internet disponible."
}

check_disk_space() {
  info "Verificando espacio en disco..."
  local free_gb
  free_gb="$(df /usr/src --output=avail -BG 2>/dev/null | tail -1 | tr -d 'G ' || true)"
  [[ -n "$free_gb" ]] || free_gb="$(df / --output=avail -BG | tail -1 | tr -d 'G ')"

  if [[ "$free_gb" -lt 5 ]]; then
    error "Espacio insuficiente. Se requieren al menos 5 GB libres."
    error "Espacio disponible: ${free_gb} GB"
    exit 1
  fi
  ok "Espacio en disco suficiente: ${free_gb} GB libres."
}

# ─── Detección y limpieza de instalaciones previas ────────────────────────────
check_previous_installation() {
  step "VERIFICACION — Detectando instalaciones previas"

  local has_asterisk=false
  local has_freepbx=false
  local has_partial_src=false
  local needs_cleanup=false

  if command -v asterisk > /dev/null 2>&1; then
    warn "Asterisk detectado en el sistema: $(asterisk -V 2>/dev/null || echo 'desconocida')"
    has_asterisk=true
    needs_cleanup=true
  fi

  if command -v fwconsole > /dev/null 2>&1 || [[ -d /var/www/html/admin ]]; then
    warn "FreePBX detectado en el sistema."
    has_freepbx=true
    needs_cleanup=true
  fi

  if compgen -G "/usr/src/asterisk-${ASTERISK_VERSION}.*" > /dev/null; then
    warn "Directorio de compilacion de Asterisk encontrado en /usr/src."
    has_partial_src=true
    needs_cleanup=true
  fi

  if [[ -f "/usr/src/freepbx-${FREEPBX_VERSION}-latest.tgz" || -d /usr/src/freepbx ]]; then
    warn "Archivos de FreePBX encontrados en /usr/src."
    has_partial_src=true
    needs_cleanup=true
  fi

  if [[ "$needs_cleanup" == false ]]; then
    ok "No se detectaron instalaciones previas. Continuando instalacion limpia."
    return 0
  fi

  echo -e "\n${YELLOW}${BOLD}Se detectaron componentes previos:${NC}"
  [[ "$has_asterisk" == true ]] && echo -e "${YELLOW}  * Asterisk instalado${NC}"
  [[ "$has_freepbx" == true ]] && echo -e "${YELLOW}  * FreePBX instalado${NC}"
  [[ "$has_partial_src" == true ]] && echo -e "${YELLOW}  * Archivos de compilacion en /usr/src${NC}"
  echo

  echo -e "${YELLOW}Desea limpiar la instalacion previa y continuar? [s/N]: ${NC}"
  read -r -t 20 CLEAN_CONFIRM || CLEAN_CONFIRM="s"

  if [[ "$CLEAN_CONFIRM" =~ ^[sS]$ ]]; then
    cleanup_previous "$has_asterisk" "$has_freepbx" "$has_partial_src"
  else
    warn "Se omitio la limpieza. La instalacion continuara sobre el estado actual."
    warn "Si falla, ejecute el script nuevamente y acepte la limpieza."
  fi
}

cleanup_previous() {
  local do_asterisk="$1"
  local do_freepbx="$2"
  local do_src="$3"

  step "LIMPIEZA — Eliminando instalacion previa"

  info "Deteniendo servicios activos..."
  for svc in asterisk apache2 mariadb; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      systemctl stop "$svc" >> "$LOG_FILE" 2>&1 || true
      info "  Servicio $svc detenido."
    fi
  done

  if [[ "$do_asterisk" == true ]]; then
    info "Eliminando Asterisk..."
    local ast_src=""
    ast_src="$(find /usr/src -maxdepth 1 -type d -name "asterisk-${ASTERISK_VERSION}.*" 2>/dev/null | head -1 || true)"
    if [[ -n "$ast_src" ]]; then
      (
        cd "$ast_src"
        make uninstall >> "$LOG_FILE" 2>&1 || true
      )
    fi

    rm -f /usr/sbin/asterisk >> "$LOG_FILE" 2>&1 || true
    rm -rf /etc/asterisk >> "$LOG_FILE" 2>&1 || true
    rm -rf /var/lib/asterisk >> "$LOG_FILE" 2>&1 || true
    rm -rf /var/log/asterisk >> "$LOG_FILE" 2>&1 || true
    rm -rf /var/spool/asterisk >> "$LOG_FILE" 2>&1 || true
    rm -rf /usr/lib/asterisk >> "$LOG_FILE" 2>&1 || true
    rm -f /etc/init.d/asterisk >> "$LOG_FILE" 2>&1 || true
    rm -f /etc/default/asterisk >> "$LOG_FILE" 2>&1 || true
    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
    id asterisk > /dev/null 2>&1 && userdel asterisk >> "$LOG_FILE" 2>&1 || true
    getent group asterisk > /dev/null 2>&1 && groupdel asterisk >> "$LOG_FILE" 2>&1 || true
    ok "Asterisk eliminado."
  fi

  if [[ "$do_freepbx" == true ]]; then
    info "Eliminando FreePBX..."
    if command -v fwconsole > /dev/null 2>&1; then
      fwconsole stop >> "$LOG_FILE" 2>&1 || true
    fi

    rm -rf /var/www/html/admin >> "$LOG_FILE" 2>&1 || true
    rm -f /var/www/html/index.php >> "$LOG_FILE" 2>&1 || true
    rm -f /etc/freepbx.conf >> "$LOG_FILE" 2>&1 || true
    rm -rf /etc/asterisk/freepbx_* >> "$LOG_FILE" 2>&1 || true
    rm -f /usr/sbin/fwconsole >> "$LOG_FILE" 2>&1 || true

    if systemctl is-active --quiet mariadb 2>/dev/null || systemctl start mariadb >> "$LOG_FILE" 2>&1; then
      mysql -e "DROP DATABASE IF EXISTS asterisk;" >> "$LOG_FILE" 2>&1 || true
      mysql -e "DROP DATABASE IF EXISTS asteriskcdrdb;" >> "$LOG_FILE" 2>&1 || true
      info "  Bases de datos de FreePBX eliminadas."
    fi
    ok "FreePBX eliminado."
  fi

  if [[ "$do_src" == true ]]; then
    info "Limpiando archivos de compilacion en /usr/src..."
    rm -rf /usr/src/asterisk-${ASTERISK_VERSION}* >> "$LOG_FILE" 2>&1 || true
    rm -rf /usr/src/freepbx* >> "$LOG_FILE" 2>&1 || true
    ok "Archivos de /usr/src eliminados."
  fi

  ok "Limpieza completada. Continuando con instalacion limpia."
}

# ─── Paso 1: Dependencias ─────────────────────────────────────────────────────
install_dependencies() {
  step "PASO 1 — Instalando dependencias del sistema"
  run "Actualizando lista de paquetes..." apt-get update -y
  run "Instalando dependencias de compilacion..." apt-get install -y \
    sox pkg-config libedit-dev unzip git gnupg2 curl \
    libnewt-dev libssl-dev libncurses5-dev subversion \
    libsqlite3-dev build-essential libjansson-dev libxml2-dev \
    uuid-dev software-properties-common wget ca-certificates lsb-release
  ok "Dependencias instaladas correctamente."
}

# ─── Paso 2: Instalar Asterisk ────────────────────────────────────────────────
install_asterisk() {
  step "PASO 2 — Descargando e instalando Asterisk $ASTERISK_VERSION"

  cd /usr/src

  info "Descargando Asterisk ${ASTERISK_VERSION}..."
  echo "  [CMD $(_ts)] wget $ASTERISK_URL" >> "$LOG_FILE"
  wget -q --show-progress "$ASTERISK_URL" -O "asterisk-${ASTERISK_VERSION}-current.tar.gz" 2>&1 | tee -a "$LOG_FILE"

  run "Extrayendo archivo..." tar -xzf "asterisk-${ASTERISK_VERSION}-current.tar.gz"

  ASTERISK_DIR="$(find /usr/src -maxdepth 1 -type d -name "asterisk-${ASTERISK_VERSION}.*" | head -1)"
  [[ -n "$ASTERISK_DIR" ]] || {
    error "No se encontro el directorio de Asterisk extraido."
    exit 1
  }

  info "Directorio de compilacion: $ASTERISK_DIR"
  cd "$ASTERISK_DIR"

  run "Descargando fuentes MP3..." contrib/scripts/get_mp3_source.sh || \
    warn "get_mp3_source.sh tuvo advertencias (no es critico)."

  run "Instalando prerequisitos de Asterisk..." contrib/scripts/install_prereq install
  run "Ejecutando ./configure..." ./configure
  run "Generando menuselect.makeopts..." make menuselect.makeopts

  info "Configurando modulos (menuselect automatico)..."
  menuselect/menuselect \
    --enable format_mp3 \
    --enable res_config_mysql \
    --enable chan_ooh323 \
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
    menuselect.makeopts >> "$LOG_FILE" 2>&1
  ok "Modulos configurados."

  info "Compilando Asterisk con $(nproc) nucleos (puede tardar varios minutos)..."
  echo "  [CMD $(_ts)] make -j$(nproc)" >> "$LOG_FILE"
  make -j"$(nproc)" >> "$LOG_FILE" 2>&1
  ok "Compilacion exitosa."

  run "Instalando binarios..." make install
  run "Instalando configuraciones de muestra..." make samples
  run "Instalando script de inicio..." make config
  run "Actualizando librerias del sistema..." ldconfig

  ok "Asterisk $ASTERISK_VERSION instalado correctamente."
}

# ─── Paso 3: Configurar Asterisk ──────────────────────────────────────────────
configure_asterisk() {
  step "PASO 3 — Configurando Asterisk"

  info "Creando usuario y grupo 'asterisk'..."
  getent group asterisk > /dev/null 2>&1 || groupadd asterisk
  id asterisk > /dev/null 2>&1 || useradd -r -d /var/lib/asterisk -g asterisk asterisk
  usermod -aG audio,dialout asterisk
  ok "Usuario y grupo creados."

  info "Aplicando permisos de directorios..."
  chown -R asterisk:asterisk /etc/asterisk
  chown -R asterisk:asterisk /var/{lib,log,spool}/asterisk
  chown -R asterisk:asterisk /usr/lib/asterisk
  ok "Permisos aplicados."

  info "Configurando /etc/default/asterisk..."
  if [[ -f /etc/default/asterisk ]]; then
    sed -i 's/^#*\s*AST_USER=.*/AST_USER="asterisk"/' /etc/default/asterisk
    sed -i 's/^#*\s*AST_GROUP=.*/AST_GROUP="asterisk"/' /etc/default/asterisk
  else
    {
      echo 'AST_USER="asterisk"'
      echo 'AST_GROUP="asterisk"'
    } > /etc/default/asterisk
  fi

  info "Configurando runuser/rungroup en asterisk.conf..."
  sed -i 's/^;*\s*runuser\s*=.*/runuser = asterisk/' /etc/asterisk/asterisk.conf
  sed -i 's/^;*\s*rungroup\s*=.*/rungroup = asterisk/' /etc/asterisk/asterisk.conf

  info "Corrigiendo error de radiusclient..."
  sed -i 's|;;\[radius\]|;\[radius\]|g' /etc/asterisk/cdr.conf 2>/dev/null || true
  sed -i 's|;radiuscfg => /usr/local/etc/radiusclient-ng/radiusclient.conf|radiuscfg => /etc/radcli/radiusclient.conf|g' /etc/asterisk/cdr.conf 2>/dev/null || true
  sed -i 's|;radiuscfg => /usr/local/etc/radiusclient-ng/radiusclient.conf|radiuscfg => /etc/radcli/radiusclient.conf|g' /etc/asterisk/cel.conf 2>/dev/null || true
  ok "Correccion radiusclient aplicada."

  run "Habilitando servicio Asterisk en systemd..." systemctl enable asterisk

  info "Iniciando servicio Asterisk..."
  systemctl restart asterisk >> "$LOG_FILE" 2>&1
  sleep 4

  if systemctl is-active --quiet asterisk; then
    ok "Asterisk esta corriendo correctamente."
    echo "  [INFO] PID: $(systemctl show asterisk --property=MainPID --value)" >> "$LOG_FILE"
  else
    warn "Asterisk no levanto correctamente. Volcando journalctl al log..."
    journalctl -u asterisk -n 40 --no-pager >> "$LOG_FILE" 2>&1 || true
    error "Asterisk no esta activo. Revise el log para mas detalles."
    exit 1
  fi
}

# ─── Paso 4: PHP 8.2 ──────────────────────────────────────────────────────────
install_php82() {
  step "PASO 4 — Instalando PHP $PHP_TARGET (requerido por FreePBX 17)"

  run "Agregando repositorio PPA de Ondrej..." add-apt-repository ppa:ondrej/php -y
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

  info "Deshabilitando PHP $PHP_DEFAULT en Apache..."
  a2dismod "php${PHP_DEFAULT}" >> "$LOG_FILE" 2>&1 || \
    warn "php${PHP_DEFAULT} no estaba activo en Apache (es normal)."

  run "Habilitando PHP $PHP_TARGET en Apache..." a2enmod "php${PHP_TARGET}"
  run "Reiniciando Apache..." systemctl restart apache2

  info "Estableciendo PHP $PHP_TARGET como version por defecto..."
  update-alternatives --set php /usr/bin/php${PHP_TARGET} >> "$LOG_FILE" 2>&1 || true
  update-alternatives --set phar /usr/bin/phar${PHP_TARGET} >> "$LOG_FILE" 2>&1 || true
  update-alternatives --set phar.phar /usr/bin/phar.phar${PHP_TARGET} >> "$LOG_FILE" 2>&1 || true

  local active_php
  active_php="$(php -v 2>/dev/null | head -1 | awk '{print $2}' | cut -d. -f1,2 || true)"
  echo "  [INFO] php -v -> $active_php" >> "$LOG_FILE"

  if [[ "$active_php" == "$PHP_TARGET" ]]; then
    ok "PHP $PHP_TARGET activo correctamente."
  else
    warn "Version activa de PHP: '$active_php' (se esperaba '$PHP_TARGET')."
    warn "Intente: update-alternatives --set php /usr/bin/php${PHP_TARGET}"
  fi
}

# ─── Paso 5: FreePBX ──────────────────────────────────────────────────────────
install_freepbx() {
  step "PASO 5 — Instalando FreePBX $FREEPBX_VERSION"

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
  ok "Apache configurado."

  info "Configurando upload_max_filesize en php.ini..."
  for ini_file in /etc/php/${PHP_TARGET}/apache2/php.ini /etc/php/${PHP_TARGET}/cli/php.ini; do
    if [[ -f "$ini_file" ]]; then
      sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 20M/' "$ini_file"
      echo "  [INFO] php.ini actualizado: $ini_file" >> "$LOG_FILE"
    else
      warn "No se encontro: $ini_file"
    fi
  done

  run "Habilitando mod_rewrite..." a2enmod rewrite
  run "Reiniciando Apache..." systemctl restart apache2

  info "Ejecutando instalador de FreePBX (puede tardar varios minutos)..."
  echo "  [CMD $(_ts)] ./install -n" >> "$LOG_FILE"
  ./install -n >> "$LOG_FILE" 2>&1 || true

  if command -v fwconsole > /dev/null 2>&1; then
    ok "FreePBX instalado exitosamente (fwconsole disponible)."
    echo "  [INFO] fwconsole ubicado en: $(command -v fwconsole)" >> "$LOG_FILE"
  else
    error "FreePBX no se instalo correctamente: fwconsole no encontrado."
    error "Revise las ultimas lineas del log: tail -80 $LOG_FILE"
    exit 1
  fi

  info "Instalando modulo pm2..."
  fwconsole ma install pm2 >> "$LOG_FILE" 2>&1 || \
    warn "pm2 no se instalo automaticamente. Ejecute: fwconsole ma install pm2"

  fwconsole chown >> "$LOG_FILE" 2>&1 || true
  fwconsole reload >> "$LOG_FILE" 2>&1 || true

  ok "FreePBX $FREEPBX_VERSION configurado correctamente."
}

# ─── Paso 6: Firewall ─────────────────────────────────────────────────────────
configure_firewall() {
  step "PASO 6 — Configurando Firewall (UFW)"

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

  echo "  [INFO] Reglas UFW activas:" >> "$LOG_FILE"
  ufw status >> "$LOG_FILE" 2>&1

  ok "Firewall UFW activo con reglas VoIP."
}

# ─── Resumen final ────────────────────────────────────────────────────────────
show_summary() {
  local server_ip
  local end_time
  server_ip="$(hostname -I | awk '{print $1}')"
  end_time="$(date '+%Y-%m-%d %H:%M:%S')"

  {
    echo
    echo "===================================================="
    echo "  RESUMEN DE INSTALACION EXITOSA"
    echo "  Inicio : $INSTALL_START"
    echo "  Fin    : $end_time"
    echo "  Ubuntu   : $UBUNTU_VERSION"
    echo "  Asterisk : $ASTERISK_VERSION"
    echo "  FreePBX  : $FREEPBX_VERSION"
    echo "  PHP      : $PHP_TARGET (reemplazo PHP $PHP_DEFAULT)"
    echo "  URL      : http://$server_ip/admin"
    echo "===================================================="
  } >> "$LOG_FILE"

  echo -e "\n${BOLD}${GREEN}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║                  OK  INSTALACION COMPLETA                   ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "${BOLD}Resumen:${NC}"
  echo -e "  Ubuntu   : ${CYAN}$UBUNTU_VERSION${NC}"
  echo -e "  Asterisk : ${CYAN}$ASTERISK_VERSION${NC}"
  echo -e "  FreePBX  : ${CYAN}$FREEPBX_VERSION${NC}"
  echo -e "  PHP      : ${CYAN}$PHP_TARGET${NC}  (reemplazo PHP $PHP_DEFAULT)"
  echo
  echo -e "${BOLD}Acceso a FreePBX:${NC}"
  echo -e "  URL     : ${CYAN}http://$server_ip/admin${NC}"
  echo -e "  Usuario : ${CYAN}asterisk${NC}  (o el que configure en el primer acceso)"
  echo
  echo -e "${BOLD}Log completo:${NC} ${CYAN}$LOG_FILE${NC}"
  echo -e "${BOLD}CLI Asterisk:${NC} ${CYAN}asterisk -rvv${NC}"
  echo
  echo -e "${YELLOW}PROXIMO PASO: Abra el navegador en http://$server_ip/admin${NC}"
  echo -e "${YELLOW}y complete la configuracion inicial del administrador.${NC}\n"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"

  banner

  {
    echo "===================================================="
    echo "  INICIO DE INSTALACION: $INSTALL_START"
    echo "  Script version: 4.2"
    echo "  Ejecutado por : $(whoami) (UID=$EUID)"
    echo "  Hostname      : $(hostname)"
    echo "===================================================="
  } | tee -a "$LOG_FILE"

  check_root
  detect_ubuntu
  check_internet
  check_disk_space
  check_previous_installation

  echo -e "\n${BOLD}Se instalaran los siguientes componentes:${NC}"
  echo -e "  * Dependencias del sistema"
  echo -e "  * Asterisk $ASTERISK_VERSION (compilado desde fuente)"
  echo -e "  * PHP $PHP_TARGET (desde PPA Ondrej, reemplazando PHP $PHP_DEFAULT)"
  echo -e "  * FreePBX $FREEPBX_VERSION"
  echo -e "  * Firewall UFW con reglas VoIP"
  echo -e "\nPara seguir el log en otra terminal: ${CYAN}tail -f $LOG_FILE${NC}\n"

  echo -e "${YELLOW}Desea continuar? [s/N]: ${NC}"
  read -r -t 15 CONFIRM || CONFIRM="s"
  [[ "$CONFIRM" =~ ^[sS]$ ]] || {
    echo "Instalacion cancelada."
    exit 0
  }

  install_dependencies
  install_asterisk
  configure_asterisk
  install_php82
  install_freepbx
  configure_firewall
  show_summary

  log "Instalacion completada exitosamente: $(date '+%Y-%m-%d %H:%M:%S')"
}

main "$@"
