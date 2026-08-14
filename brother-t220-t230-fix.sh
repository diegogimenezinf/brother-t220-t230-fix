#!/usr/bin/env bash
#
# brother-t220-t230-fix.sh
#
# Repara automáticamente la detección USB directa en CUPS para
# Brother DCP-T220 / DCP-T230 cuando ipp-usb captura el dispositivo
# e impide que CUPS use una URI usb://Brother/... directa.
#
# EXCLUSIVO para DCP-T220 y DCP-T230. No modifica otras impresoras.
#
# Uso:
#   sudo bash brother-t220-t230-fix.sh
#
set -uo pipefail

# ------------------------------------------------------------------
# Variables globales
# ------------------------------------------------------------------
MODEL=""                        # T220 o T230
QUEUE_NAME=""                    # Nombre de cola CUPS
USB_URI=""                       # URI usb://Brother/... detectada
PPD=""                           # PPD detectado
IPP_USB_WAS_ACTIVE="no evaluado"
IPP_USB_FINAL_STATE="no modificado"
DEFAULT_SET="NO"
TEST_RESULT="no ejecutada"

# ------------------------------------------------------------------
# Utilidades
# ------------------------------------------------------------------
info() { echo "[INFO]   $*"; }
warn() { echo "[AVISO]  $*"; }
err()  { echo "[ERROR]  $*" >&2; }
step() { echo; echo "==> $*"; }

die() {
    err "$1"
    show_summary
    exit 1
}

# ------------------------------------------------------------------
# check_root
# ------------------------------------------------------------------
check_root() {
    step "Comprobando permisos"
    if [ "$(id -u)" -ne 0 ]; then
        echo "[ERROR]  Este script debe ejecutarse con sudo:" >&2
        echo "         sudo bash brother-t220-t230-fix.sh" >&2
        exit 1
    fi
    info "Ejecutando con privilegios de root."
}

# ------------------------------------------------------------------
# detect_model
# ------------------------------------------------------------------
detect_model() {
    step "Detectando modelo de impresora vía lsusb"

    if ! command -v lsusb >/dev/null 2>&1; then
        echo "[ERROR]  lsusb no está disponible en este sistema." >&2
        exit 1
    fi

    local usb_output
    usb_output="$(lsusb)"

    if echo "$usb_output" | grep -qi "DCP-T220"; then
        MODEL="T220"
    elif echo "$usb_output" | grep -qi "DCP-T230"; then
        MODEL="T230"
    elif echo "$usb_output" | grep -qi "Brother"; then
        echo "[ERROR]  Se detectó una impresora Brother diferente de DCP-T220/DCP-T230. Procedimiento detenido." >&2
        echo "$usb_output" | grep -i "Brother" >&2
        exit 1
    else
        echo "[ERROR]  No se detectó ninguna impresora Brother DCP-T220/DCP-T230 conectada por USB." >&2
        exit 1
    fi

    QUEUE_NAME="Brother_DCP_${MODEL}_USB"
    info "Modelo detectado: DCP-${MODEL}"
    info "Nombre de cola a usar: ${QUEUE_NAME}"
}

# ------------------------------------------------------------------
# check_cups
# ------------------------------------------------------------------
check_cups() {
    step "Comprobando el servicio CUPS"

    if ! command -v lpstat >/dev/null 2>&1 || ! command -v lpinfo >/dev/null 2>&1 || ! command -v lpadmin >/dev/null 2>&1; then
        die "Faltan utilidades de CUPS (lpstat/lpinfo/lpadmin). ¿Está instalado cups-client?"
    fi

    if ! systemctl is-active --quiet cups; then
        warn "El servicio CUPS no está activo. Intentando iniciarlo..."
        if ! systemctl start cups; then
            die "No se pudo iniciar el servicio CUPS."
        fi
    fi

    info "CUPS está activo."
}

# ------------------------------------------------------------------
# detect_usb_uri
# Devuelve 0 y llena USB_URI si encuentra "direct usb://Brother/DCP-<MODEL>..."
# Devuelve 1 si no la encuentra.
# ------------------------------------------------------------------
detect_usb_uri() {
    step "Buscando URI USB directa para DCP-${MODEL} en CUPS (lpinfo -v)"

    local lpinfo_output matched_line
    lpinfo_output="$(lpinfo -v 2>/dev/null)"

    matched_line="$(echo "$lpinfo_output" \
        | grep -i "direct" \
        | grep -i "usb://Brother/DCP-${MODEL}" \
        | head -n1)"

    if [ -z "$matched_line" ]; then
        warn "No se encontró una URI USB directa para DCP-${MODEL}."
        USB_URI=""
        return 1
    fi

    USB_URI="$(echo "$matched_line" | grep -oE 'usb://[^[:space:]]+')"

    if [ -z "$USB_URI" ]; then
        warn "Se encontró una línea 'direct' pero no se pudo extraer la URI."
        return 1
    fi

    info "URI USB directa encontrada: $USB_URI"
    return 0
}

# ------------------------------------------------------------------
# check_ipp_usb
# Devuelve 0 si ipp-usb está instalado Y activo (hay que enmascararlo)
# Devuelve 1 si no está instalado o no está activo (no hay nada que hacer)
# ------------------------------------------------------------------
check_ipp_usb() {
    step "Comprobando estado de ipp-usb"

    if ! dpkg -l 2>/dev/null | grep -q "^ii.*[[:space:]]ipp-usb[[:space:]]"; then
        info "El paquete ipp-usb no está instalado. No hay nada que enmascarar."
        IPP_USB_WAS_ACTIVE="no instalado"
        return 1
    fi

    if systemctl is-active --quiet ipp-usb; then
        info "ipp-usb está instalado y activo."
        IPP_USB_WAS_ACTIVE="si"
        return 0
    else
        info "ipp-usb está instalado pero no activo."
        IPP_USB_WAS_ACTIVE="no"
        return 1
    fi
}

# ------------------------------------------------------------------
# disable_ipp_usb
# ------------------------------------------------------------------
disable_ipp_usb() {
    step "Deteniendo y enmascarando ipp-usb"

    info "Ejecutando: systemctl stop ipp-usb"
    if ! systemctl stop ipp-usb; then
        die "No se pudo detener ipp-usb."
    fi

    info "Ejecutando: systemctl mask ipp-usb"
    if ! systemctl mask ipp-usb; then
        die "No se pudo enmascarar ipp-usb."
    fi

    local status_output
    status_output="$(systemctl status ipp-usb 2>&1 || true)"

    if echo "$status_output" | grep -qi "masked" && echo "$status_output" | grep -qi "inactive"; then
        info "ipp-usb quedó masked / inactive, como se esperaba."
        IPP_USB_FINAL_STATE="masked / inactive"
    else
        warn "ipp-usb fue detenido y enmascarado, pero conviene verificar su estado manualmente."
        IPP_USB_FINAL_STATE="masked (verificar estado manualmente)"
    fi
}

# ------------------------------------------------------------------
# restart_cups
# ------------------------------------------------------------------
restart_cups() {
    step "Reiniciando CUPS"

    if ! systemctl restart cups; then
        die "No se pudo reiniciar el servicio CUPS."
    fi

    sleep 3
    info "CUPS reiniciado."
}

# ------------------------------------------------------------------
# detect_ppd
# ------------------------------------------------------------------
detect_ppd() {
    step "Buscando PPD correspondiente a DCP-${MODEL}"

    local num other ppd_list ppd_line
    num="${MODEL#T}"
    if [ "$num" = "220" ]; then
        other="230"
    else
        other="220"
    fi

    ppd_list="$(lpinfo -m 2>/dev/null)"

    ppd_line="$(echo "$ppd_list" \
        | grep -i "brother" \
        | grep -i "t${num}" \
        | grep -vi "t${other}" \
        | head -n1)"

    if [ -z "$ppd_line" ]; then
        die "No se encontró un PPD correspondiente a DCP-${MODEL}. No se creará la cola. No se instalará nada automáticamente."
    fi

    PPD="$(echo "$ppd_line" | awk '{print $1}')"
    info "PPD detectado: $PPD"
}

# ------------------------------------------------------------------
# check_existing_queue
# Si existe una cola con el nombre esperado y URI incorrecta, la borra.
# Nunca toca otras impresoras.
# ------------------------------------------------------------------
check_existing_queue() {
    step "Comprobando si ya existe la cola ${QUEUE_NAME}"

    if ! lpstat -p "$QUEUE_NAME" >/dev/null 2>&1; then
        info "No existe una cola previa llamada ${QUEUE_NAME}."
        return 0
    fi

    info "Existe una cola llamada ${QUEUE_NAME}. Comprobando su Device URI."

    local existing_uri
    existing_uri="$(lpstat -v "$QUEUE_NAME" 2>/dev/null | grep -oE '[a-zA-Z]+://[^[:space:]]+' | head -n1)"

    if echo "$existing_uri" | grep -qi "implicitclass://"; then
        warn "La cola existente ${QUEUE_NAME} usa implicitclass:// ($existing_uri). Se eliminará solo esta cola."
        lpadmin -x "$QUEUE_NAME" || die "No se pudo eliminar la cola existente ${QUEUE_NAME}."
        info "Cola ${QUEUE_NAME} eliminada."
    elif ! echo "$existing_uri" | grep -qi "^usb://Brother/DCP-${MODEL}"; then
        warn "La cola existente ${QUEUE_NAME} usa una URI incorrecta ($existing_uri). Se eliminará solo esta cola."
        lpadmin -x "$QUEUE_NAME" || die "No se pudo eliminar la cola existente ${QUEUE_NAME}."
        info "Cola ${QUEUE_NAME} eliminada."
    else
        info "La cola existente ya usa la URI USB directa correcta: $existing_uri"
    fi
}

# ------------------------------------------------------------------
# create_queue
# ------------------------------------------------------------------
create_queue() {
    step "Creando/verificando la cola ${QUEUE_NAME}"

    if lpstat -p "$QUEUE_NAME" >/dev/null 2>&1; then
        info "La cola ${QUEUE_NAME} ya existe con la URI correcta. No se recrea."
        return 0
    fi

    info "Creando cola con URI: ${USB_URI} y PPD: ${PPD}"
    lpadmin -p "$QUEUE_NAME" -v "$USB_URI" -m "$PPD" -E \
        || die "No se pudo crear la cola ${QUEUE_NAME}."

    info "Cola ${QUEUE_NAME} creada correctamente."
}

# ------------------------------------------------------------------
# set_default
# ------------------------------------------------------------------
set_default() {
    step "Configurando ${QUEUE_NAME} como impresora predeterminada"

    if lpadmin -d "$QUEUE_NAME"; then
        DEFAULT_SET="SI"
        info "${QUEUE_NAME} configurada como predeterminada."
    else
        warn "No se pudo configurar ${QUEUE_NAME} como predeterminada."
        DEFAULT_SET="NO"
    fi
}

# ------------------------------------------------------------------
# test_print
# ------------------------------------------------------------------
test_print() {
    step "Enviando trabajo de prueba a ${QUEUE_NAME}"

    if ! lp -d "$QUEUE_NAME" /etc/hosts >/dev/null 2>&1; then
        warn "No se pudo encolar el trabajo de prueba."
        TEST_RESULT="no se pudo encolar"
        return 0
    fi

    sleep 2

    local queue_status
    queue_status="$(lpq -P "$QUEUE_NAME" 2>/dev/null)"

    if echo "$queue_status" | grep -qi "no entries"; then
        echo "CUPS procesó el trabajo. Confirmar físicamente que la impresora imprimió."
        TEST_RESULT="procesado por CUPS (confirmar físicamente)"
    else
        echo "El trabajo permanece en cola. La impresión no fue completada."
        TEST_RESULT="permanece en cola"
    fi
}

# ------------------------------------------------------------------
# show_summary
# ------------------------------------------------------------------
show_summary() {
    echo
    echo "========================================"
    echo " RESULTADO"
    echo "========================================"
    echo "Modelo detectado:        DCP-${MODEL:-DESCONOCIDO}"
    echo "ipp-usb (activo antes):  ${IPP_USB_WAS_ACTIVE}"
    echo "ipp-usb (estado final):  ${IPP_USB_FINAL_STATE}"
    echo "URI USB:                 ${USB_URI:-NO DETECTADA}"
    echo "PPD:                     ${PPD:-NO DETECTADO}"
    echo "Cola:                    ${QUEUE_NAME:-N/A}"
    echo "Predeterminada:          ${DEFAULT_SET}"
    echo "Trabajo de prueba:       ${TEST_RESULT}"
    echo
    echo "Estado:"
    if [ -n "$USB_URI" ] && [ -n "$PPD" ]; then
        echo "CUPS quedó configurado para utilizar USB directo."
    else
        echo "El procedimiento se detuvo antes de completar la configuración."
    fi
    echo
    echo "IMPORTANTE:"
    echo "Confirmar físicamente que la impresora haya producido la hoja."
    echo "========================================"
}

# ------------------------------------------------------------------
# main
# ------------------------------------------------------------------
main() {
    check_root
    detect_model
    check_cups

    if detect_usb_uri; then
        info "Ya existe una URI USB directa. No se modificará ipp-usb."
    else
        if check_ipp_usb; then
            disable_ipp_usb
        else
            info "ipp-usb no está activo o no está instalado; no hay nada que enmascarar."
        fi

        restart_cups

        if ! detect_usb_uri; then
            err "CUPS todavía no detecta la impresora mediante USB directo."
            echo
            echo "Información recopilada:"
            echo "  Modelo: DCP-${MODEL}"
            echo "  ipp-usb estado final: ${IPP_USB_FINAL_STATE}"
            echo "  lpinfo -v (líneas relacionadas con Brother):"
            lpinfo -v 2>/dev/null | grep -i "brother" || echo "  (sin coincidencias)"
            show_summary
            exit 1
        fi
    fi

    detect_ppd
    check_existing_queue
    create_queue
    set_default
    test_print
    show_summary
}

main "$@"
