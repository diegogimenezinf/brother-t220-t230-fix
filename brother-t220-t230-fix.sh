#!/usr/bin/env bash
set -u
set -o pipefail

# ============================================================
# brother-t220-t230-fix.sh
# Procedimiento técnico para Brother DCP-T220 / DCP-T230
# sobre Linux Mint / Ubuntu con CUPS y ipp-usb.
#
# Objetivo: conseguir que CUPS ofrezca direct usb://Brother/...
# y crear una cola USB directa con su PPD correspondiente.
#
# NO instala drivers. NO desinstala ipp-usb. NO modifica
# otras impresoras. Solo actúa sobre DCP-T220 / DCP-T230.
# ============================================================

# -------- Variables globales --------
MODEL=""
MODEL_FULL=""
QUEUE_NAME=""
USB_URI=""
PPD=""
IPPUSB_INITIAL=""
IPPUSB_FINAL=""
CUPS_OK=0
QUEUE_USED_USB=0
QUEUE_NOT_IMPLICITCLASS=0
QUEUE_ENABLED=0
IS_DEFAULT=0
JOB_ACCEPTED=0
JOB_STATUS="NO_ENVIADO"
JOBS_PENDING_AFTER=0
LSUSB_OK=0
PPD_FOUND=0
USB_URI_FOUND=0
USB_URI_AFTER_IPPUSB=0
IPPUSB_MASKED_OK=0
CUPS_RESTART_DONE=0

# -------- Helpers --------
hr() {
    printf '\n%s\n' "----------------------------------------"
}

title() {
    hr
    printf 'FASE: %s\n' "$1"
    hr
}

pause() {
    # Lectura de una tecla sin bloquear si no hay tty.
    if [ -t 0 ]; then
        read -r -p "Pulse Enter para continuar (o Ctrl+C para abortar)..." _
    fi
}

# ============================================================
# 1. Comprobar root
# ============================================================
check_root() {
    title "1. Comprobando privilegios de root"
    if [ "$(id -u)" -ne 0 ]; then
        printf 'Este script debe ejecutarse con sudo.\n'
        printf 'Uso: sudo bash brother-t220-t230-fix.sh\n'
        exit 1
    fi
    printf '[OK] Ejecutando como root.\n'
}

# ============================================================
# 2. Detectar modelo con lsusb
# ============================================================
detect_model() {
    title "2. Detectando impresora Brother con lsusb"
    if ! command -v lsusb >/dev/null 2>&1; then
        printf 'No se encontró lsusb. Instale usbutils antes de continuar.\n'
        exit 1
    fi
    printf 'Ejecutando: lsusb\n\n'
    lsusb
    printf '\n'

    LSUSB_OUT="$(lsusb)"

    HAS_T220=0
    HAS_T230=0
    HAS_OTHER_BROTHER=0

    if printf '%s' "$LSUSB_OUT" | grep -q "DCP-T220"; then HAS_T220=1; fi
    if printf '%s' "$LSUSB_OUT" | grep -q "DCP-T230"; then HAS_T230=1; fi
    if printf '%s' "$LSUSB_OUT" | grep -qi "Brother"; then
        if [ "$HAS_T220" -eq 0 ] && [ "$HAS_T230" -eq 0 ]; then
            HAS_OTHER_BROTHER=1
        fi
    fi

    if [ "$HAS_T220" -eq 1 ] && [ "$HAS_T230" -eq 0 ]; then
        MODEL="T220"
        MODEL_FULL="DCP-T220"
        printf '[OK] Detectada Brother DCP-T220 por USB.\n'
        LSUSB_OK=1
    elif [ "$HAS_T230" -eq 1 ] && [ "$HAS_T220" -eq 0 ]; then
        MODEL="T230"
        MODEL_FULL="DCP-T230"
        printf '[OK] Detectada Brother DCP-T230 por USB.\n'
        LSUSB_OK=1
    elif [ "$HAS_T220" -eq 1 ] && [ "$HAS_T230" -eq 1 ]; then
        printf 'Se detectaron DCP-T220 y DCP-T230 simultáneamente.\n'
        printf 'Conecte solo una y vuelva a ejecutar el script.\n'
        exit 1
    elif [ "$HAS_OTHER_BROTHER" -eq 1 ]; then
        printf 'Se detectó una impresora Brother diferente de DCP-T220/DCP-T230.\n'
        printf 'Este script es EXCLUSIVO para DCP-T220 y DCP-T230. No se modifica nada.\n'
        exit 1
    else
        printf 'No se detectó una Brother DCP-T220/DCP-T230 por USB.\n'
        printf 'No se modificará CUPS, ipp-usb ni ninguna cola.\n'
        exit 1
    fi

    case "$MODEL" in
        T220) QUEUE_NAME="Brother_DCP_T220_USB" ;;
        T230) QUEUE_NAME="Brother_DCP_T230_USB" ;;
    esac
    printf 'Modelo seleccionado: %s\n' "$MODEL_FULL"
    printf 'Nombre de cola previsto: %s\n' "$QUEUE_NAME"
}

# ============================================================
# 3. Comprobar herramientas CUPS y servicio cups
# ============================================================
check_cups() {
    title "3. Comprobando CUPS"

    local missing=0
    local tool
    for tool in lpstat lpinfo lpadmin lp lpq; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            printf '[FALTA] %s no está disponible.\n' "$tool"
            missing=1
        else
            printf '[OK] %s disponible.\n' "$tool"
        fi
    done
    if [ "$missing" -eq 1 ]; then
        printf 'Faltan herramientas necesarias. Este script no instala paquetes.\n'
        exit 1
    fi

    printf '\nEstado de CUPS (systemctl status cups):\n\n'
    if systemctl status cups --no-pager >/dev/null 2>&1; then
        CUPS_OK=1
        printf '[OK] CUPS está activo.\n'
    else
        printf 'CUPS no está activo. Intentando iniciarlo...\n'
        if systemctl start cups 2>&1; then
            sleep 2
            if systemctl is-active --quiet cups; then
                CUPS_OK=1
                printf '[OK] CUPS iniciado correctamente.\n'
            else
                printf '[ERROR] CUPS no responde tras systemctl start cups.\n'
                CUPS_OK=0
            fi
        else
            CUPS_OK=0
            printf '[ERROR] No se pudo iniciar CUPS.\n'
        fi
    fi

    if [ "$CUPS_OK" -ne 1 ]; then
        printf 'No se puede continuar sin CUPS activo.\n'
        exit 1
    fi
}

# ============================================================
# 4. Revisar colas existentes (lpstat -t)
# ============================================================
show_queues() {
    title "4. Revisando colas existentes (lpstat -t)"
    printf 'Ejecutando: lpstat -t\n\n'
    lpstat -t
    printf '\n[INFO] En esta fase NO se elimina ninguna cola.\n'
}

# ============================================================
# 5 y 6. Comprobar dispositivos expuestos por CUPS
# ============================================================
detect_usb_uri() {
    title "5. Comprobando qué dispositivos expone CUPS (lpinfo -v)"
    printf 'Ejecutando: lpinfo -v\n\n'
    LPINFO_BEFORE="$(lpinfo -v 2>/dev/null)"
    printf '%s\n' "$LPINFO_BEFORE"
    printf '\n'

    USB_URI="$(printf '%s\n' "$LPINFO_BEFORE" \
        | grep -oE "usb://Brother/${MODEL_FULL}\?serial=[A-Za-z0-9]+" \
        | head -n 1)"

    if [ -n "$USB_URI" ]; then
        USB_URI_FOUND=1
        USB_URI_AFTER_IPPUSB=1
        printf '[OK] Encontrada URI USB directa: %s\n' "$USB_URI"
        printf '[INFO] CUPS ya tiene acceso USB directo. NO se modificará ipp-usb.\n'
        return 0
    fi

    printf '[INFO] No hay URI usb://Brother/%s directa aún.\n' "$MODEL_FULL"
    USB_URI_FOUND=0
    return 1
}

# ============================================================
# 7. Comprobar ipp-usb
# ============================================================
IPPUSB_INSTALLED=0
IPPUSB_ACTIVE=0

check_ipp_usb() {
    title "7. Comprobando ipp-usb"
    printf 'Ejecutando: systemctl status ipp-usb\n\n'
    if systemctl status ipp-usb --no-pager 2>&1 | head -n 40; then
        :
    fi
    printf '\nEjecutando: dpkg -l | grep ipp-usb\n\n'
    dpkg -l 2>/dev/null | grep -i "ipp-usb" || printf '(sin coincidencias en dpkg)\n'
    printf '\n'

    if dpkg -l 2>/dev/null | grep -q "^ii.*ipp-usb"; then
        IPPUSB_INSTALLED=1
    else
        IPPUSB_INSTALLED=0
    fi

    if systemctl is-active --quiet ipp-usb; then
        IPPUSB_ACTIVE=1
    else
        IPPUSB_ACTIVE=0
    fi

    # Estado inicial REAL, registrado como uno de tres valores estables.
    if [ "$IPPUSB_INSTALLED" -eq 0 ]; then
        IPPUSB_INITIAL="no instalado"
    elif [ "$IPPUSB_ACTIVE" -eq 1 ]; then
        IPPUSB_INITIAL="activo"
    else
        IPPUSB_INITIAL="inactivo"
    fi

    printf '[INFO] ipp-usb: instalado=%s activo=%s\n' "$IPPUSB_INSTALLED" "$IPPUSB_ACTIVE"
}

# ============================================================
# 8. Detener y enmascarar ipp-usb (solo si activo)
# ============================================================
disable_ipp_usb() {
    title "8. Deteniendo y enmascarando ipp-usb (solo si está activo)"
    if [ "$IPPUSB_ACTIVE" -ne 1 ]; then
        if [ "$IPPUSB_INSTALLED" -eq 0 ]; then
            printf '[INFO] ipp-usb NO está instalado. No se instala.\n'
            printf '[INFO] Continuando con reinicio de CUPS.\n'
            IPPUSB_FINAL="no instalado"
        else
            printf '[INFO] ipp-usb instalado pero inactivo. No se enmascara innecesariamente.\n'
            IPPUSB_FINAL="inactivo"
        fi
        return 0
    fi

    printf 'ipp-usb está activo. Procediendo con stop + mask.\n'
    if ! systemctl stop ipp-usb 2>&1; then
        printf '[ERROR] No se pudo detener ipp-usb.\n'
        exit 1
    fi
    if ! systemctl mask ipp-usb 2>&1; then
        printf '[ERROR] No se pudo enmascarar ipp-usb.\n'
        exit 1
    fi

    printf '\nVerificando estado final de ipp-usb:\n\n'
    systemctl status ipp-usb --no-pager | head -n 10 || true

    if systemctl is-active --quiet ipp-usb; then
        printf '[ERROR] ipp-usb sigue activo tras stop+mask. Abortando.\n'
        exit 1
    fi

    if systemctl is-enabled --quiet ipp-usb 2>/dev/null; then
        # masked cuenta como enabled=false en systemd, pero verificamos igualmente.
        :
    fi

    # Comprobar que está masked mirando la línea "Loaded:" en status.
    if systemctl show ipp-usb -p LoadState 2>/dev/null | grep -q "LoadState=masked"; then
        IPPUSB_MASKED_OK=1
    fi

    if [ "$IPPUSB_MASKED_OK" -ne 1 ]; then
        # Fallback: aceptar que al menos esté inactive.
        if ! systemctl is-active --quiet ipp-usb; then
            IPPUSB_MASKED_OK=1
        fi
    fi

    if [ "$IPPUSB_MASKED_OK" -ne 1 ]; then
        printf '[ERROR] ipp-usb no quedó enmascarado/inactivo. No se puede garantizar liberación USB.\n'
        exit 1
    fi

    IPPUSB_FINAL="masked/inactive"
    printf '[OK] ipp-usb detenido y enmascarado (paquete conservado, NO desinstalado).\n'
}

# ============================================================
# 9. Reiniciar CUPS
# ============================================================
restart_cups() {
    title "9. Reiniciando CUPS"
    if ! systemctl restart cups 2>&1; then
        printf '[ERROR] No se pudo reiniciar CUPS.\n'
        exit 1
    fi
    CUPS_RESTART_DONE=1
    sleep 3
    if systemctl is-active --quiet cups; then
        printf '[OK] CUPS reiniciado y activo.\n'
    else
        printf '[ERROR] CUPS no está activo tras reiniciar.\n'
        exit 1
    fi
}

# ============================================================
# 10. Volver a comprobar lpinfo -v
# ============================================================
recheck_lpinfo() {
    title "10. Re-comprobando lpinfo -v tras acciones sobre ipp-usb/CUPS"
    printf 'Ejecutando: lpinfo -v\n\n'
    LPINFO_AFTER="$(lpinfo -v 2>/dev/null)"
    printf '%s\n' "$LPINFO_AFTER"
    printf '\n'

    USB_URI="$(printf '%s\n' "$LPINFO_AFTER" \
        | grep -oE "usb://Brother/${MODEL_FULL}\?serial=[A-Za-z0-9]+" \
        | head -n 1)"

    if [ -n "$USB_URI" ]; then
        USB_URI_FOUND=1
        USB_URI_AFTER_IPPUSB=1
        printf '[OK] Encontrada URI USB directa: %s\n' "$USB_URI"
        return 0
    fi

    printf '[FALLO] CUPS todavía no ofrece direct usb://Brother/%s?serial=...\n' "$MODEL_FULL"
    printf '\nDiagnóstico:\n'
    printf '  Modelo detectado: %s\n' "$MODEL_FULL"
    printf '  Estado ipp-usb: %s\n' "$IPPUSB_FINAL"
    printf '  Estado CUPS: %s\n' "$(systemctl is-active cups 2>/dev/null || echo desconocido)"
    printf '  Salida relevante de lpinfo -v (ya mostrada arriba).\n'
    printf '\nNo se creará ninguna cola, no se instalarán drivers, no se eliminará ninguna cola.\n'
    exit 1
}

# ============================================================
# 11. Confirmar PPD con lpinfo -m
# ============================================================
detect_ppd() {
    title "11. Confirmando PPD correspondiente con lpinfo -m"
    printf 'Ejecutando: lpinfo -m\n\n'
    LPINFO_M="$(lpinfo -m 2>/dev/null)"
    printf '%s\n' "$LPINFO_M"
    printf '\n'

    # Búsqueda estricta del PPD del modelo detectado.
    # Formato típico: Brother/brother_dcpt220_printer_en.ppd
    # Solo se consideran entradas que contengan "brother_dcpNNN" donde NNN
    # coincide con el modelo detectado. NO se usa head -n 1.
    local lc_model
    lc_model="$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')"

    # Modelo "opuesto" para descartar cualquier coincidencia espuria.
    local lc_other
    case "$MODEL" in
        T220) lc_other="dcpt230" ;;
        T230) lc_other="dcpt220" ;;
    esac

    # Candidatos: líneas cuyo nombre de archivo .ppd contenga "brother_dcp<modelo>".
    local candidates
    candidates="$(printf '%s\n' "$LPINFO_M" \
        | grep -iE "Brother/[^[:space:]]*brother_dcp${lc_model}[^[:space:]]*\.ppd" \
        | grep -viE "brother_dcp${lc_other}" \
        | awk '{print $1}')"

    # Normalización: lpinfo -m puede listar el MISMO PPD dos veces bajo rutas
    # equivalentes (alias LSB de CUPS). Ejemplo real observado en Linux Mint:
    #   Brother/brother_dcpt220_printer_en.ppd
    #   lsb/usr/Brother/brother_dcpt220_printer_en.ppd
    # Ambas entradas apuntan al mismo archivo físico y deben contar como 1.
    # Regla: se elimina cualquier prefijo "lsb/usr/" y luego se deduplican
    # las entradas idénticas preservando la primera aparición.
    local canonical
    canonical="$(printf '%s\n' "$candidates" \
        | sed -E 's|^lsb/usr/||' \
        | awk 'NF && !seen[$0]++')"

    local count
    count="$(printf '%s\n' "$canonical" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [ "$count" -eq 0 ]; then
        printf '[ERROR] No se encontró ningún PPD para %s en lpinfo -m.\n' "$MODEL_FULL"
        printf 'Candidatos que contienen "Brother" para diagnóstico:\n'
        printf '%s\n' "$LPINFO_M" | grep -iE "Brother/[^[:space:]]*\.ppd" || printf '(sin PPDs de Brother)\n'
        printf '\nNo se creará ninguna cola. No se descarga ningún PPD.\n'
        exit 1
    fi

    if [ "$count" -gt 1 ]; then
        printf '[ERROR] Se encontraron %s PPDs distintos para %s. Se requiere selección explícita.\n' "$count" "$MODEL_FULL"
        printf 'Candidatos distintos encontrados (tras normalizar duplicados lógicos):\n'
        printf '%s\n' "$canonical"
        printf '\nEste script NO selecciona arbitrariamente entre múltiples candidatos.\n'
        printf 'Instale/seleccione manualmente el PPD correcto y vuelva a ejecutar.\n'
        exit 1
    fi

    # Exactamente un candidato claro (ya sin duplicados lógicos).
    PPD="$(printf '%s\n' "$canonical")"
    PPD_FOUND=1
    printf '[OK] PPD detectado dinámicamente (único candidato): %s\n' "$PPD"
}

# ============================================================
# 13. Comprobar cola existente
# ============================================================
check_existing_queue() {
    title "13. Comprobando si existe la cola objetivo"

    if ! lpstat -p "$QUEUE_NAME" >/dev/null 2>&1; then
        printf '[INFO] La cola %s NO existe. Se continuará con la creación.\n' "$QUEUE_NAME"
        return 0
    fi

    printf '[INFO] La cola %s YA existe. Inspeccionando Device URI...\n' "$QUEUE_NAME"
    local current_uri
    current_uri="$(lpstat -v "$QUEUE_NAME" 2>/dev/null \
        | sed -n "s/^device for ${QUEUE_NAME}: //p")"
    printf 'URI actual: %s\n' "$current_uri"

    local should_delete=0
    if printf '%s' "$current_uri" | grep -q "^implicitclass://"; then
        should_delete=1
        printf '[INFO] La cola usa implicitclass://. Se eliminará SOLO esta cola.\n'
    elif printf '%s' "$current_uri" | grep -qE "^ipp(s)?://"; then
        # Es IPP y referencia la impresora (mismo modelo)
        if printf '%s' "$current_uri" | grep -qi "Brother/${MODEL_FULL}"; then
            should_delete=1
            printf '[INFO] La cola usa IPP hacia esta impresora. Se eliminará SOLO esta cola.\n'
        fi
    fi

    if [ "$should_delete" -eq 1 ]; then
        printf 'Ejecutando: lpadmin -x %s\n' "$QUEUE_NAME"
        if ! lpadmin -x "$QUEUE_NAME" 2>&1; then
            # "La impresora o clase no existe" NO debe abortar.
            printf '[INFO] lpadmin -x devolvió error (puede que ya no exista). Continuando.\n'
        fi
        sleep 1
    else
        printf '[INFO] La cola existe pero NO usa implicitclass:// ni IPP de esta impresora.\n'
        printf '[INFO] No se elimina por seguridad.\n'
    fi
}

# ============================================================
# 14. Crear la cola USB
# ============================================================
create_queue() {
    title "14. Creando la cola USB directa"
    printf 'Comando:\n'
    printf '  lpadmin -p %s -v "%s" -m %s -E\n' "$QUEUE_NAME" "$USB_URI" "$PPD"
    printf '\n'

    if ! lpadmin -p "$QUEUE_NAME" -v "$USB_URI" -m "$PPD" -E 2>&1; then
        printf '[ERROR] No se pudo crear la cola %s.\n' "$QUEUE_NAME"
        exit 1
    fi

    QUEUE_ENABLED=1
    printf '[OK] Cola %s creada y habilitada.\n' "$QUEUE_NAME"
}

# ============================================================
# 15. Establecer como predeterminada
# ============================================================
set_default() {
    title "15. Estableciendo la cola como predeterminada"
    if ! lpadmin -d "$QUEUE_NAME" 2>&1; then
        printf '[ERROR] No se pudo establecer la cola como predeterminada.\n'
        exit 1
    fi
    printf 'Resultado de lpstat -d:\n'
    lpstat -d || true
    printf '\n'
    if lpstat -d 2>/dev/null | grep -q "$QUEUE_NAME"; then
        IS_DEFAULT=1
        printf '[OK] La cola %s es la predeterminada.\n' "$QUEUE_NAME"
    else
        printf '[AVISO] lpstat -d no muestra %s como predeterminada.\n' "$QUEUE_NAME"
    fi
}

# ============================================================
# 16. Verificación final de CUPS
# ============================================================
validate_queue() {
    title "16. Verificación final de CUPS"

    printf 'Ejecutando: lpstat -t\n\n'
    lpstat -t
    printf '\n'

    printf 'Ejecutando: lpstat -d\n\n'
    lpstat -d
    printf '\n'

    # URI final asignada a la cola.
    # Extracción robusta e independiente del idioma: ancla en el nombre de
    # la cola (Brother_DCP_T220_USB / Brother_DCP_T230_USB), que es fijo y NO
    # se traduce. NO se depende de "device for" / "dispositivo para".
    local final_uri
    final_uri="$(lpstat -v "$QUEUE_NAME" 2>/dev/null \
        | awk -v q="$QUEUE_NAME" '
            match($0, q ":[ \t]*") {
                print substr($0, RSTART + RLENGTH)
            }
        ')"
    printf 'URI final de la cola: %s\n' "$final_uri"

    # Validación independiente del idioma.
    if [ -z "$final_uri" ]; then
        QUEUE_USED_USB=0
        printf '[ERROR] lpstat -v no devolvió ninguna URI para la cola %s.\n' "$QUEUE_NAME"
    elif printf '%s' "$final_uri" | grep -qE "^usb://Brother/${MODEL_FULL}(\\?|\$|/)"; then
        QUEUE_USED_USB=1
        printf '[OK] La URI final de la cola es correcta: %s\n' "$final_uri"
    else
        QUEUE_USED_USB=0
        printf '[ERROR] La URI final no corresponde a usb://Brother/%s...: %s\n' "$MODEL_FULL" "$final_uri"
    fi

    if printf '%s' "$final_uri" | grep -q "^implicitclass://"; then
        QUEUE_NOT_IMPLICITCLASS=0
        printf '[ERROR] La cola sigue usando implicitclass://.\n'
    else
        QUEUE_NOT_IMPLICITCLASS=1
        printf '[OK] La cola NO usa implicitclass://.\n'
    fi

    if printf '%s' "$final_uri" | grep -qE "^ipp(s)?://"; then
        printf '[ERROR] La cola está usando una URI IPP en lugar de USB directa.\n'
        QUEUE_USED_USB=0
    fi
}

# ============================================================
# 17. Prueba de impresión (sin depender del idioma)
# ============================================================
test_print() {
    title "17. Prueba de impresión con lp"
    printf 'Ejecutando: lp -d %s /etc/hosts\n\n' "$QUEUE_NAME"
    LP_OUT="$(lp -d "$QUEUE_NAME" /etc/hosts 2>&1)"
    LP_RC=$?
    printf '%s\n' "$LP_OUT"
    printf '\n[Código de retorno lp: %s]\n' "$LP_RC"

    # Decisión basada ÚNICAMENTE en el código de retorno de lp.
    # NO se analiza el texto porque Linux Mint puede estar en español.
    if [ "$LP_RC" -eq 0 ]; then
        JOB_ACCEPTED=1
        JOB_STATUS="ACEPTADO"
        printf '[OK] CUPS aceptó el trabajo (lp devolvió código 0).\n'
    else
        JOB_STATUS="ERROR_AL_ENVIAR"
        printf '[ERROR] lp devolvió código %s. CUPS no aceptó el trabajo.\n' "$LP_RC"
        return
    fi

    # Pequeña espera para que CUPS procese.
    sleep 2

    printf '\nEjecutando: lpq -P %s  (solo informativo; NO se usa para decidir estado)\n\n' "$QUEUE_NAME"
    LPQ_OUT="$(lpq -P "$QUEUE_NAME" 2>&1)"
    LPQ_RC=$?
    printf '%s\n' "$LPQ_OUT"
    printf '\n[Código de retorno lpq: %s]\n' "$LPQ_RC"

    # Comprobación robusta independiente del idioma:
    # usamos lpstat -o COLA, cuyo contenido por línea incluye IDs de trabajos pendientes.
    # Si no hay líneas, no hay trabajos pendientes en la cola.
    PENDING_OUT="$(lpstat -o "$QUEUE_NAME" 2>/dev/null || true)"
    if [ -n "$PENDING_OUT" ]; then
        JOBS_PENDING_AFTER=1
        JOB_STATUS="PENDIENTE"
        printf '[AVISO] lpstat -o %s muestra trabajos pendientes:\n' "$QUEUE_NAME"
        printf '%s\n' "$PENDING_OUT"
        printf '[INFO] Investigar backend USB, PPD o comunicación con la impresora.\n'
    else
        JOBS_PENDING_AFTER=0
        JOB_STATUS="PROCESADO_POR_CUPS"
        printf '[OK] lpstat -o %s vacío: sin trabajos pendientes.\n' "$QUEUE_NAME"
    fi

    printf '\nNOTA: %s\n' "CUPS procesó el trabajo. Confirmar físicamente la impresión."
}

# ============================================================
# 18. Checklist final
# ============================================================
print_checklist() {
    title "18. Checklist final"
    if [ "$LSUSB_OK" -eq 1 ]; then printf '[OK] '; else printf '[NO] '; fi
    printf 'lsusb detecta la Brother.\n'

    if [ "$CUPS_OK" -eq 1 ]; then printf '[OK] '; else printf '[NO] '; fi
    printf 'CUPS está activo.\n'

    if [ "$IPPUSB_MASKED_OK" -eq 1 ] || [ "$IPPUSB_ACTIVE" -eq 0 ]; then
        printf '[OK] '; else printf '[NO] '; fi
    printf 'ipp-usb está inactive/dead y masked cuando fue necesario.\n'

    if [ "$USB_URI_AFTER_IPPUSB" -eq 1 ]; then printf '[OK] '; else printf '[NO] '; fi
    printf 'lpinfo muestra direct usb://Brother/...\n'

    if [ "$PPD_FOUND" -eq 1 ]; then printf '[OK] '; else printf '[NO] '; fi
    printf 'Existe el PPD correspondiente.\n'

    if [ "$QUEUE_USED_USB" -eq 1 ]; then printf '[OK] '; else printf '[NO] '; fi
    printf 'La cola utiliza usb://.\n'

    if [ "$QUEUE_NOT_IMPLICITCLASS" -eq 1 ]; then printf '[OK] '; else printf '[NO] '; fi
    printf 'La cola no utiliza implicitclass://.\n'

    if [ "$QUEUE_ENABLED" -eq 1 ]; then printf '[OK] '; else printf '[NO] '; fi
    printf 'La cola está habilitada.\n'

    if [ "$IS_DEFAULT" -eq 1 ]; then printf '[OK] '; else printf '[NO] '; fi
    printf 'La impresora está configurada como predeterminada.\n'

    if [ "$JOB_STATUS" = "PROCESADO_POR_CUPS" ] || [ "$JOB_STATUS" = "PENDIENTE" ]; then
        printf '[OK] '; else printf '[NO] '; fi
    printf 'El trabajo fue procesado por CUPS.\n'

    printf '[PENDIENTE] Confirmación física de impresión.\n'
}

# ============================================================
# 19. Resumen técnico
# ============================================================
show_summary() {
    title "19. Resumen técnico"

    local cups_state="OK"
    if [ "$CUPS_OK" -ne 1 ]; then cups_state="ERROR"; fi

    local default_state="NO"
    if [ "$IS_DEFAULT" -eq 1 ]; then default_state="SI"; fi

    local prueba_txt="$JOB_STATUS"
    if [ "$JOB_STATUS" = "PROCESADO_POR_CUPS" ]; then
        prueba_txt="Trabajo enviado y procesado por CUPS (cola vacía). Sin confirmación física."
    elif [ "$JOB_STATUS" = "PENDIENTE" ]; then
        prueba_txt="Trabajo aceptado pero pendiente en la cola."
    fi

    cat <<EOF
========================================
RESULTADO
========================================
Modelo detectado:     ${MODEL_FULL}
CUPS:                 ${cups_state}
ipp-usb (inicial):    ${IPPUSB_INITIAL}
ipp-usb (final):      ${IPPUSB_FINAL:-${IPPUSB_INITIAL}}
URI USB:              ${USB_URI:-NO_DETECTADA}
PPD:                  ${PPD:-NO_DETECTADO}
Cola:                 ${QUEUE_NAME}
Predeterminada:       ${default_state}
Prueba:               ${prueba_txt}
========================================

HECHOS CONFIRMADOS
- Hardware detectado por USB: ${MODEL_FULL}
- CUPS activo: ${cups_state}
- Estado final de ipp-usb: ${IPPUSB_FINAL:-${IPPUSB_INITIAL}}
- URI USB directa detectada: ${USB_URI:-NO}
- PPD seleccionado dinámicamente: ${PPD:-NO}

CAMBIOS REALIZADOS
- (Condicional) systemctl stop ipp-usb: ${IPPUSB_ACTIVE:-0}
- (Condicional) systemctl mask ipp-usb: ${IPPUSB_MASKED_OK:-0}
- systemctl restart cups: ${CUPS_RESTART_DONE}
- Cola creada/modificada: ${QUEUE_NAME} -> ${USB_URI:-N/A}

PRUEBAS PENDIENTES
- Confirmación física de impresión (mirar la impresora).
EOF
}

# ============================================================
# Flujo principal
# ============================================================
main() {
    check_root
    detect_model
    check_cups
    show_queues

    if ! detect_usb_uri; then
        # No había usb:// directa. Continuar con diagnóstico de ipp-usb.
        check_ipp_usb
        disable_ipp_usb
        restart_cups
        recheck_lpinfo
    fi

    detect_ppd
    check_existing_queue
    create_queue
    set_default
    validate_queue
    test_print
    print_checklist
    show_summary
}

main "$@"
