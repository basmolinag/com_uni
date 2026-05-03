#!/bin/bash
#
# basic_kamailio_sbc.sh
# Instalación de Kamailio SBC básico para guía 2.1.2
# Alineado con basic_asterisk.sh / basic_asterisk_aws.sh
#
# Uso:
#   sudo bash basic_kamailio_sbc.sh
#   sudo bash basic_kamailio_sbc.sh -y --asterisk-ip 172.31.10.25
#
# Notas:
#   - Lab 2.1.2: Kamailio maneja SIP (señalización)
#   - Asterisk sigue manejando PBX y RTP directo
#   - Lab 2.2.2: usar RTPEngine, NO RTPProxy
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

AUTO_YES=false
ASTERISK_BACKEND_IP="${ASTERISK_BACKEND_IP:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        --asterisk-ip)
            ASTERISK_BACKEND_IP="${2:-}"
            shift 2
            ;;
        *)
            echo "Opción no reconocida: $1"
            echo "Uso: sudo bash $0 [-y|--yes] [--asterisk-ip IP_PRIVADA_ASTERISK]"
            exit 1
            ;;
    esac
done

print_header() {
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║ $1${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ ERROR: $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ $1${NC}"; }

if [[ $EUID -ne 0 ]]; then
   print_error "Ejecutar como root: sudo bash $0"
   exit 1
fi

if ! grep -q "Ubuntu" /etc/os-release; then
    print_error "Este script está diseñado para Ubuntu"
    exit 1
fi

clear || true
print_header "LAB 2.1.2: INSTALACIÓN KAMAILIO SBC BÁSICO"
echo ""
echo "Este script instala Kamailio como Session Border Controller básico."
echo ""
echo "Componentes:"
echo "  ✓ Kamailio SBC"
echo "  ✓ Routing SIP básico"
echo "  ✓ Registro de usuarios y ruteo hacia Asterisk"
echo "  ✗ Sin RTPEngine (Lab 2.2.2)"
echo "  ✗ Sin TLS/SRTP (Lab 2.3)"
echo ""
echo "Tiempo estimado: ~10 minutos"
echo ""

if [[ "$AUTO_YES" != true ]]; then
    read -p "¿Continuar? (y/N): " -n 1 -r
    echo
    if [[ ! ${REPLY:-N} =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

print_info "Detectando IPs del servidor Kamailio..."
PRIVATE_IP="$(hostname -I | awk '{print $1}')"
PUBLIC_IP="$(curl -4 -s ifconfig.me || true)"
if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(curl -4 -s https://checkip.amazonaws.com || true)"
fi

if [[ -z "$PUBLIC_IP" ]]; then
    print_error "No se pudo obtener IP pública automáticamente"
    print_error "Verifica conectividad o define manualmente PUBLIC_IP editando el script"
    exit 1
fi

echo "  ├─ IP Privada Kamailio: $PRIVATE_IP"
echo "  └─ IP Pública Kamailio: $PUBLIC_IP"
echo ""

if [[ -z "$ASTERISK_BACKEND_IP" ]]; then
    if [[ "$AUTO_YES" == true ]]; then
        print_error "Falta --asterisk-ip en modo no interactivo"
        exit 1
    fi
    echo "Configuración de backend:"
    read -r -p "IP PRIVADA de Asterisk (ej: 172.31.10.25): " ASTERISK_BACKEND_IP
fi

if [[ -z "$ASTERISK_BACKEND_IP" ]]; then
    print_error "Debes ingresar la IP privada de Asterisk"
    exit 1
fi

echo ""
print_info "Configuración detectada:"
echo "  ├─ Kamailio (privada) : $PRIVATE_IP"
echo "  ├─ Kamailio (pública) : $PUBLIC_IP"
echo "  └─ Asterisk backend   : $ASTERISK_BACKEND_IP"
echo ""

print_header "Paso 1: Actualizar sistema"
export DEBIAN_FRONTEND=noninteractive
apt update -y
print_success "Sistema actualizado"

print_header "Paso 2: Instalar Kamailio"
apt install -y kamailio kamailio-extra-modules curl ca-certificates net-tools
print_success "Kamailio instalado"

KAMAILIO_VERSION="$(kamailio -v 2>&1 | head -1 || true)"
print_info "Versión: $KAMAILIO_VERSION"

systemctl stop kamailio 2>/dev/null || true

print_header "Paso 3: Configurar Kamailio"

BACKUP_DIR="/etc/kamailio/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/kamailio/kamailio.cfg "$BACKUP_DIR/" 2>/dev/null || true
print_success "Backup creado en: $BACKUP_DIR"

cat > /etc/kamailio/kamailio.cfg <<'EOFKAMAILIO'
#!KAMAILIO
#
# Kamailio SBC - Lab 2.1.2
# Alineado con basic_asterisk.sh
# Sin RTPEngine / Sin TLS
#

####### Global Parameters #########

debug=2
log_stderror=no
memdbg=5
memlog=5
log_facility=LOG_LOCAL0
fork=yes
children=4

# Kamailio escucha en IP privada y anuncia IP pública
listen=udp:KAMAILIO_PRIVATE_IP:5060
advertise KAMAILIO_PUBLIC_IP:5060

#!define ASTERISK_BACKEND_IP "ASTERISK_PRIVATE_IP"

####### Modules Section ########

loadmodule "tm.so"
loadmodule "sl.so"
loadmodule "rr.so"
loadmodule "pv.so"
loadmodule "maxfwd.so"
loadmodule "usrloc.so"
loadmodule "registrar.so"
loadmodule "textops.so"
loadmodule "siputils.so"
loadmodule "xlog.so"
loadmodule "sanity.so"

####### Module Parameters ########

modparam("rr", "enable_full_lr", 1)
modparam("rr", "append_fromtag", 1)
modparam("registrar", "method_filtering", 1)
modparam("registrar", "max_expires", 3600)
modparam("registrar", "gruu_enabled", 0)
modparam("usrloc", "db_mode", 0)

####### Routing Logic ########

request_route {
    xlog("L_INFO", "[$rm] $fu -> $ru (src=$si:$sp)\n");

    if (!mf_process_maxfwd_header("10")) {
        sl_send_reply("483", "Too Many Hops");
        exit;
    }

    if (!sanity_check("1511", "7")) {
        xlog("L_WARN", "Malformed SIP message from $si:$sp\n");
        exit;
    }

    force_rport();

    # Tráfico dentro de diálogo
    if (has_totag()) {
        if (loose_route()) {
            if (!t_relay()) { sl_reply_error(); }
        } else {
            if (is_method("ACK")) {
                if (t_check_trans()) {
                    t_relay();
                }
            } else {
                sl_send_reply("404", "Not here");
            }
        }
        exit;
    }

    # CANCEL
    if (is_method("CANCEL")) {
        if (t_check_trans()) {
            t_relay();
        }
        exit;
    }

    # REGISTER: guardar localización y reenviar a Asterisk
    if (is_method("REGISTER")) {
        xlog("L_INFO", "REGISTER de $fu (Contact: $ct)\n");
        if (!save("location")) {
            sl_reply_error();
            exit;
        }
        $du = "sip:" + ASTERISK_BACKEND_IP + ":5060";
        if (!t_relay()) {
            sl_reply_error();
        }
        exit;
    }

    # Responder OPTIONS al propio proxy
    if (is_method("OPTIONS") && uri == myself) {
        sl_send_reply("200", "OK");
        exit;
    }

    # INVITE y otros mensajes iniciales
    if (is_method("INVITE|SUBSCRIBE|MESSAGE|INFO|UPDATE|OPTIONS")) {
        record_route();

        # Si el destino ya está registrado en Kamailio, enviar al contacto.
        # Si no existe localmente y la petición viene desde Asterisk, no devolverla de nuevo.
        if (!lookup("location")) {
            if ($si == ASTERISK_BACKEND_IP) {
                sl_send_reply("480", "Temporarily Unavailable");
                exit;
            }
            $du = "sip:" + ASTERISK_BACKEND_IP + ":5060";
        } else {
            $du = $ru;
        }

        if (!t_relay()) {
            sl_reply_error();
        }
        exit;
    }

    if (!t_relay()) {
        sl_reply_error();
    }
}

failure_route[MANAGE_FAILURE] {
    xlog("L_INFO", "Failure route: $rs $rr\n");
}
EOFKAMAILIO

# Reemplazos seguros
sed -i "s/KAMAILIO_PRIVATE_IP/${PRIVATE_IP}/g" /etc/kamailio/kamailio.cfg
sed -i "s/KAMAILIO_PUBLIC_IP/${PUBLIC_IP}/g" /etc/kamailio/kamailio.cfg
sed -i "s/ASTERISK_PRIVATE_IP/${ASTERISK_BACKEND_IP}/g" /etc/kamailio/kamailio.cfg

print_success "Archivo /etc/kamailio/kamailio.cfg generado"

print_header "Paso 4: Verificar configuración"
if kamailio -c >/dev/null 2>&1; then
    print_success "Configuración válida"
else
    print_error "Error en configuración"
    kamailio -c || true
    exit 1
fi

print_header "Paso 5: Habilitar e iniciar Kamailio"
systemctl enable kamailio >/dev/null 2>&1
systemctl start kamailio
sleep 3

if systemctl is-active --quiet kamailio; then
    print_success "Kamailio iniciado correctamente"
else
    print_error "Kamailio no inició"
    print_info "Ver logs: sudo journalctl -u kamailio -n 50"
    exit 1
fi

print_header "RESUMEN FINAL"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║        KAMAILIO SBC BÁSICO INSTALADO CORRECTAMENTE        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "IPs y backend:"
echo "  ├─ Kamailio IP privada : $PRIVATE_IP"
echo "  ├─ Kamailio IP pública : $PUBLIC_IP"
echo "  └─ Asterisk backend    : $ASTERISK_BACKEND_IP"
echo ""
echo "Alineado con Asterisk:"
echo "  ├─ Extensión 1001 / pass1001"
echo "  ├─ Extensión 1002 / pass1002"
echo "  ├─ Extensión 2003 / pass2003"
echo "  └─ Extensión 2004 / pass2004"
echo ""
echo "Pruebas útiles con tu backend:"
echo "  ├─ 100   = echo test"
echo "  ├─ 9999  = alias a 100"
echo "  └─ *60   = alias a 100 (útil para 2.2.2)"
echo ""
echo "Security Groups AWS sugeridos:"
echo "  En SG-Kamailio:"
echo "    ├─ 22/TCP -> tu IP"
echo "    └─ 5060/UDP -> 0.0.0.0/0"
echo ""
echo "  En SG-Asterisk (Lab 2.1.2):"
echo "    ├─ 22/TCP -> tu IP"
echo "    ├─ 5060/UDP -> 0.0.0.0/0"
echo "    └─ 10000-20000/UDP -> 0.0.0.0/0"
echo ""
echo "Importante para AWS:"
echo "  ├─ Si cambia la IP pública de Kamailio al reiniciar, revisa:"
echo "  │    /etc/kamailio/kamailio.cfg"
echo "  │    listen=udp:${PRIVATE_IP}:5060"
echo "  │    advertise ${PUBLIC_IP}:5060"
echo "  └─ Si cambia la IP privada de Asterisk, actualiza el backend"
echo ""
echo "Para guía 2.2.2:"
echo "  ├─ No uses RTPProxy"
echo "  ├─ Debes instalar RTPEngine"
echo "  └─ Socket esperado: 127.0.0.1:22222"
echo ""
echo "Para guía 2.3:"
echo "  ├─ Debes agregar TLS/SRTP"
echo "  ├─ Certificados en Kamailio/Asterisk"
echo "  └─ Apertura de 5061/TCP si el diseño lo requiere"
echo ""
echo "Comandos útiles:"
echo "  ├─ sudo systemctl status kamailio"
echo "  ├─ sudo journalctl -u kamailio -f"
echo "  ├─ sudo tail -f /var/log/syslog | grep kamailio"
echo "  ├─ sudo kamailio -c"
echo "  └─ sudo tcpdump -i any -n port 5060 -A"
echo ""
print_success "Instalación completada"
