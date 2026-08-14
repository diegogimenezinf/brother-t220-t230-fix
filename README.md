# brother-t220-t230-fix

Script Bash para Linux Mint que recupera el acceso USB directo de CUPS para las
impresoras Brother **DCP-T220** y **DCP-T230** cuando `ipp-usb` lo está
interceptando.

---

## 1. Objetivo

En Linux Mint la Brother DCP-T220 / DCP-T230 es detectada por USB, pero CUPS
puede no exponer la URI directa `usb://Brother/DCP-Txxx?serial=...` porque
`ipp-usb` captura el dispositivo y lo publica como IPP.

El script implementa el procedimiento técnico documentado para:

1. Liberar el dispositivo USB deteniendo y enmascarando `ipp-usb` (sin
   desinstalar el paquete).
2. Reiniciar CUPS.
3. Confirmar que vuelve a aparecer la URI directa
   `usb://Brother/DCP-Txxx?serial=...`.
4. Crear la cola CUPS correspondiente usando el PPD detectado
   dinámicamente.
5. Establecer la cola como predeterminada.
6. Enviar una prueba y comprobar que CUPS la procesa.

La confirmación de impresión física queda fuera del alcance del script: solo se
verifica que CUPS recibió y procesó el trabajo.

---

## 2. Alcance

**Modelos soportados (únicos):**

- Brother DCP-T220
- Brother DCP-T230

**Fuera del alcance:**

- Cualquier otro modelo Brother.
- Cualquier otra marca.
- Otros backends de impresión (red, Wi-Fi, IPP, AirPrint, etc.).
- Reinstalación de drivers.
- Descarga de PPDs.
- Desinstalación de paquetes.
- Confirmación de impresión física.

---

## 3. Flujo implementado

```
lsusb                -> detecta DCP-T220 o DCP-T230
check_cups           -> verifica CUPS y sus herramientas
lpstat -t            -> muestra colas existentes (sin modificar nada)
lpinfo -v            -> busca usb://Brother/DCP-Txxx?serial=...
                      si existe  -> salta ipp-usb
                      si no existe -> continúa con ipp-usb
systemctl ipp-usb    -> estado inicial registrado
stop + mask ipp-usb  -> solo si estaba activo (paquete conservado)
systemctl restart cups
lpinfo -v            -> confirma la URI directa usb://Brother/...
lpinfo -m            -> selecciona PPD del modelo (con deduplicación)
lpstat -v / lpadmin  -> crea/ajusta cola usb://
lpadmin -d           -> establece como predeterminada
lp                   -> prueba de impresión (acepta por código de retorno)
lpstat -o            -> comprueba trabajos pendientes
resumen              -> hechos confirmados / cambios / pruebas pendientes
```

---

## 4. Problema resuelto (evidencia)

Durante la prueba funcional en Linux Mint se observó lo siguiente:

**Antes:**

- La Brother DCP-T220 estaba conectada y visible por USB.
- CUPS no exponía la URI USB directa.

**Después de ejecutar el script:**

- CUPS presentó la URI directa:
  `usb://Brother/DCP-T220?serial=U66051C4H736825`.
- Se creó la cola `Brother_DCP_T220_USB`.
- `lp -d Brother_DCP_T220_USB /etc/hosts` devolvió código de retorno `0`
  (trabajo aceptado).
- Tras la espera, `lpstat -o Brother_DCP_T220_USB` no mostró trabajos
  pendientes: CUPS procesó el trabajo.

La liberación de `ipp-usb` (`stop` + `mask`) fue la acción que permitió a
CUPS recuperar el backend USB directo.

> **Nota:** CUPS procesó el trabajo. La confirmación de impresión física
> (papel saliendo de la impresora) es una verificación manual fuera del
> script.

---

## 5. Script

**Archivo:** `brother-t220-t230-fix.sh`

**Uso:**

```bash
sudo bash brother-t220-t230-fix.sh
```

El script es un único archivo Bash, sin dependencias externas, sin interfaz
gráfica. Muestra cada paso antes de ejecutarlo y aborta de forma controlada
si algo no cumple las precondiciones.

---

## 6. Comportamiento de seguridad

- Solo reconoce **DCP-T220** o **DCP-T230**. Cualquier otra impresora hace
  abortar sin modificar nada.
- No modifica otras impresoras ni otras colas.
- No instala drivers.
- No descarga PPDs ni paquetes.
- No desinstala `ipp-usb`: usa `systemctl mask` (el paquete queda instalado).
- No borra todas las colas: si elimina una cola, es únicamente la cola
  objetivo (`Brother_DCP_Txxx_USB`) y solo si su URI era
  `implicitclass://` o IPP hacia esa misma impresora.
- No crea la cola si CUPS no expone primero `usb://Brother/DCP-Txxx?serial=...`.
- La URI, el número de serie y el PPD se obtienen dinámicamente con
  `lpinfo -v` / `lpinfo -m`. Nunca se escriben a mano.
- El PPD elegido corresponde exactamente al modelo detectado; si existen
  múltiples PPDs distintos para el mismo modelo, el script aborta y los
  lista.
- La aceptación de un trabajo se decide por el código de retorno de `lp`
  (`0` = aceptado), nunca por su texto (que puede estar localizado).
- La URI final se extrae anclando en el nombre de la cola (fijo), no en
  cadenas como `device for` / `dispositivo para` que cambian con el idioma.
- Nunca afirma impresión física: solo indica que CUPS procesó el trabajo.

---

## 7. Casos corregidos durante el desarrollo

1. **`ipp-usb` capturando el dispositivo.** Sin `stop` + `mask`, CUPS no
   recuperaba la URI USB directa. Se documentó el orden correcto: comprobar
   `lpinfo -v`, actuar solo si la URI directa no existe, y reiniciar CUPS
   después.

2. **PPD listado dos veces.** En `lpinfo -m` el mismo PPD puede aparecer
   bajo dos rutas equivalentes:
   ```
   Brother/brother_dcpt220_printer_en.ppd
   lsb/usr/Brother/brother_dcpt220_printer_en.ppd
   ```
   Ambas entradas apuntan al mismo archivo físico. El script aplica una
   normalización previa al conteo:
   - elimina el prefijo `lsb/usr/`,
   - deduplica las entradas idénticas.
   Tras esto: `0` PPDs únicos → aborta; `1` PPD único → lo usa;
   `>1` PPDs distintos → aborta y los lista. Nunca usa `head -n 1` para
   elegir entre PPDs diferentes.

3. **Mensaje de `lp` traducido al español.** En sistemas en español, el
   texto `request id is N` se localiza, por lo que parsearlo es frágil. El
   script decide únicamente por el código de retorno (`LP_RC=0` aceptado).
   El estado de la cola se comprueba con `lpstat -o COLA`, cuyo contenido
   no depende del idioma.

4. **`lpstat -v` traducido.** El prefijo `device for` aparece como
   `dispositivo para` en español. La extracción de la URI final se rehízo
   anclando en el nombre de la cola (`Brother_DCP_T220_USB` /
   `Brother_DCP_T230_USB`), que es fijo y no se traduce.

5. **Estado de `ipp-usb` no quedaba registrado.** El resumen podía mostrar
   campos vacíos para el estado inicial/final. Se reescribió el
   almacenamiento a tres valores estables:
   `no instalado` / `activo` / `inactivo` para el estado inicial;
   `no instalado` / `inactivo` / `masked/inactive` para el estado final.

---

## 8. Validación final

| Comprobación | Resultado |
|---|---|
| `bash -n brother-t220-t230-fix.sh` | OK (código 0) |
| Prueba funcional en Linux Mint | OK |
| DCP-T220 detectada por `lsusb` | OK |
| URI USB directa recuperada (`usb://Brother/DCP-T220?serial=…`) | OK |
| PPD correcto seleccionado | OK |
| Cola `Brother_DCP_T220_USB` creada | OK |
| `lp -d COLA /etc/hosts` → código de retorno 0 | OK |
| `lpstat -o COLA` sin trabajos pendientes (CUPS procesó) | OK |
| Impresión física confirmada | **No verificada por el script** (manual) |

El script verifica que CUPS recibió y procesó el trabajo. La confirmación
de impresión en papel queda como verificación manual.

---

## 9. Estado del proyecto

**Estado: CERRADO / VERSIÓN ESTABLE.**

Para el objetivo original (recuperar el acceso USB directo de CUPS para
DCP-T220/DCP-T230 y configurar la cola) esta versión se considera estable y
no requiere más modificaciones.

Si en el futuro se detecta un nuevo problema relacionado con DCP-T220 o
DCP-T230, se debe partir de esta versión estable como base y documentar
explícitamente cualquier cambio, evitando modificaciones innecesarias sobre
la lógica que ya fue validada.
