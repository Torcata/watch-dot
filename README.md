              -=
            :#%+:
           -@%##=#%#%%%##*+-.
        :==@%%##=::....:-=*#%#=
      -%@*#%%%%#+           .=%@+.   -.
    :%@*.=+*%%%%*.             -%#:=#*+=
   +@%: .=++*%%%%=             .=#%%##*
  +@#  .*-=+++#%%%-        .-=*#**###+.
 =@#    -*=-=+++#%%-   .-+#***++*%%*+:       _____                  _
 %@:      =*=:=++*%#::+#%%++++*#%#-.@@      |_   _|__  _ __ ___ __ _| |_ __ _
:@%       :=%-.-==*%++%%#+=++*##+.  #@:       | |/ _ \| '__/ __/ _` | __/ _` |
-@%     :###*##+-+*--%%%+=++*%#-    *@-       | | (_) | | | (_| (_| | || (_| |
.@@.    *#**#*+--+:-%%#*==+#%*.     %@:       |_|\___/|_|  \___\__,_|\__\__,_|
 *@+    =*%*:  :#.+####*+*#%=      -@#
 .%@:   *%*:.-*#-=#*****+**:      :@@:
  :%@::%%-   .:-+####%#***+.     -@@:           S O F T W A R E
   .**%=        ..:---+###@%*- .*@#.
    :-*@*:            -%%##%%%*+#-
       =%@%+:.        :#**#**++**-
         .=#%%##*++++*+**++=#*%#*-
             .-=++**++-.      .

# Watch Dot

**D7 — companion de iPhone y paquete conjunto:** el esquema **WatchDotPhone** incluye iPhone, Watch y complicación. El iPhone presenta el login ChatGPT y entrega los tokens por WatchConnectivity; el reloj conserva chat y renovación autónomos. Namespace de todos los componentes: `cl.australapps`. Compilar no acredita el callback físico; consulta [validación y pendientes](docs/VALIDATION.md) y [instalación actual](docs/INSTALACION-Y-LOGIN.md).

Cliente SwiftUI para Apple Watch Ultra 2, ampliado sobre el MVP existente. **D3 incorpora chat directo experimental con el Dot existente.** No utiliza una API de modelos ni crea un asistente sustituto.

**D6 — recepción bajo demanda y menor tráfico:** no consulta mensajes al abrir ni estando inactiva. Consulta mientras espera la respuesta a un envío y hace **una sola lectura 60 segundos después**. Al salir, solo esos pendientes pasan a descargas del sistema; watchOS puede aplazarlas. Para traer mensajes de otros clientes, desliza hacia arriba al final del chat. **ⓘ → Mensajes al sincronizar** conserva el límite 20/50/100/200 (100 por defecto). [Funcionamiento y límites](docs/RECEPCION-SEGUNDO-PLANO.md).

**Estado comprobado D3.3:** el 2 de octubre de 2026, a las 23:33, Pablo confirmó envío y recepción reales en su **Apple Watch Ultra 2 físico**. Sus capturas muestran la misma respuesta de Andy en Watch Dot y ChatGPT: «Sí, me llegó este mensaje de prueba de Watch Dot.». Se cumple la aceptación del chat directo. La integración experimental se indica en los detalles ⓘ; DEMO identifica exclusivamente respuestas simuladas. [Pruebas completas y límites](docs/VALIDATION.md).

**Uso actual:** abre Watch Dot y envía tu mensaje con la flecha. D6 recibe automáticamente la respuesta solicitada y consulta una vez más al minuto, sin reenviar el texto. Al volver muestra el historial guardado; la sincronización general es manual. No hace falta pulsar Consultar respuesta salvo que hayas cancelado expresamente la espera o el servicio requiera intervención. El campo de texto sigue editable y otro mensaje puede enviarse cuando OpenAI confirme la recepción del anterior. Para reinstalar o actualizar, usa **⌘R en Xcode**, manteniendo bundle y datos; no repitas el login si la sesión sigue vigente.

**Corrección D3.1:** la falta de sesión o de transporte real ya no activa la demo. Se muestra el estado concreto y el botón de conexión/reautorización. Solo el interruptor **Usar demo local**, apagado por defecto en cada ejecución, permite respuestas simuladas. El antiguo control Simular sin conexión solo fingía un corte de red y no seleccionaba el modo del chat.

Se eliminaron el backend del Mac, su configuración y el transporte de diagnósticos al Mac. Los mensajes continúan directamente del reloj a OpenAI.

## Implementado

- Chat compacto: Andy, estado y botón ⓘ en la barra superior; entrada pequeña junto al borde inferior. Solo ⓘ abre los detalles. El chat directo no muestra EXP; DEMO sigue identificando las respuestas simuladas.
- Entrada nativa de watchOS para dictado/teclado; envío explícito con flecha. Sin respuestas por voz.
- Estados de envío, espera tras acuse, respuesta, recuperación de red, cancelación y error. D3.3 consulta la sala principal con after, no la vista de hilo reply_root_message_id, y conserva múltiples envíos aceptados pendientes de respuesta. Límite de espera de 45 segundos en demo y 60 segundos en chat directo; se puede continuar consultando la respuesta.
- Historial reciente, borrador, ID de conversación y turnos pendientes en un archivo atómico del contenedor de la app. En watchOS se aplica protección de archivos hasta el primer desbloqueo. El chat directo separa su caché por cuenta, Dot y sala e importa hasta el límite elegido de mensajes recientes de esa sala. No guarda tareas/credenciales; el contexto completo permanece en Andy.
- Reintentos explícitos con el mismo identificador, rechazo de respuestas tardías, validación básica de respuestas y preservación de IDs/fechas.
- Recuperación de respuestas solicitadas al reabrir, sin sincronización general automática. D6 entrega únicamente la recepción pendiente o la lectura diferida al sistema al pasar a segundo plano. Cancelar conserva el turno; no afirma cancelar acciones remotas.
- Transporte desacoplado; ante entrega incierta, Consultar respuesta hace solo lecturas. Guarda un comprobante antes del POST y no repite envíos inciertos, incluso tras reiniciar. Errores de disco visibles y envío bloqueado hasta guardar.
- App de iPhone para login y conexión, con la app del reloj y complicación incluidas en su paquete. Se conserva el equipo de firma; el namespace nuevo implica nuevos contenedores frente a la instalación anterior.
- Estado compacto junto a **Andy**: punto verde con cuenta autorizada, naranja durante autorización/pausa/expiración, rojo ante error y gris sin sesión. Tocar el encabezado abre los detalles y las acciones de login/configuración. Sustituye la fila que ocupaba Cuenta autorizada; VoiceOver anuncia el estado sin depender del color. El verde acredita sesión de cuenta, no acceso al Dot. El cliente usa PKCE, canje directo, validación del ID token y Keychain; las capturas de Pablo muestran el login completado.
- Estados de conexión, autorización en el iPhone, validación, pausa, cancelación y error. Reanudar conserva el mismo intento antes del canje; nunca muestra acceso a Andy por haber iniciado sesión.

La demo responde siempre que no envió nada a Andy ni creó tareas/recordatorios. El control **Simular sin conexión** prueba estados locales, no la red real.

## Integración y dependencias

### Sesión y sincronización — D5

- La app guarda el refresh token que emita OpenAI en el Keychain del reloj. Renueva directamente por HTTPS al volver al chat o antes de una petición cuando quedan 60 segundos o menos de vigencia; no necesita el Mac para renovar ni mantiene un temporizador periódico. Las peticiones simultáneas comparten una única renovación y se guarda el token rotado antes de utilizarlo.
- **Sesiones de versiones anteriores:** toca **ⓘ → Activar renovación automática** y autoriza una vez más desde el iPhone. Si ya aparece sesión expirada, usa **Volver a autorizar**. La versión anterior descartaba el refresh token; no se puede recuperarlo de una sesión antigua. No hace falta cerrar sesión ni borrar datos. Cuando OpenAI lo emite, los detalles muestran «Renovación automática activada».
- Si la renovación falla por conexión, se conserva el token y se evita repetir peticiones durante 30 segundos. Si OpenAI rechaza el permiso, se requiere autorización nueva. La duración y revocación siguen dependiendo del servicio; no se garantiza una sesión indefinida.
- **Sincronización manual:** llega al final del chat y arrastra el dedo hacia arriba. Aparece una flecha de recarga; al continuar unos 56 puntos se sincroniza una vez. El scroll normal y la corona siguen disponibles. VoiceOver dispone de la acción «Sincronizar mensajes». Una recuperación pendiente usa solo lectura; no reenvía el mensaje.
- Una sincronización correcta limpia el aviso naranja de recepción pendiente. Se conservan cancelaciones, borrador y mensajes que aún requieren recuperación.
- En segundo plano D6 limita las descargas a la respuesta solicitada y una actualización posterior: no se añade un proceso permanente de renovación. Si el sistema no puede completar la recepción, se recupera al abrir la app.

[Investigación de Andy, fuentes oficiales, código revisado y propuesta de notificaciones](docs/ANDY-INTEGRATION.md).

No se encontró una API pública de mensajería del Dot personal ni esa feature en la revisión examinada de openai/codex. Sign in with ChatGPT no da acceso a las conversaciones de ChatGPT. La vía soportada sigue sin contrato público identificado. Pablo autorizó acceso experimental directo basado en el protocolo observado en Desktop y confirmó su funcionamiento con Andy en el Ultra 2 físico. Esto no convierte el protocolo interno en una API pública ni garantiza su compatibilidad futura.

La conexión de chat es directa reloj → Andy. El iPhone participa en login/reautorización y entrega de tokens; después del acuse elimina su copia y no renueva tokens. No necesita una IP, PIN ni backend en el Mac. La prueba con iPhone apagado y renovación real se registra aparte de la compilación.

## Instalación conjunta

Selecciona **WatchDotPhone** en Xcode y tu iPhone emparejado; pulsa **⌘R**. Instala la versión del reloj desde la app **Watch** del iPhone si no se instala automáticamente. Abre las dos apps y toca **Continuar con ChatGPT**. Desde el Watch puede solicitarse la autorización, pero debes abrir la app del iPhone para mostrar el navegador.

Esta entrega usa `cl.australapps.watchdot`, `cl.australapps.watchdot.watchkitapp` y la complicación bajo ese prefijo. El vínculo companion coincide con el bundle iOS. La app anterior puede conservarse, pero la sesión/historial no se transfieren automáticamente entre bundles distintos. Las futuras actualizaciones de estos nuevos identificadores conservarán sus datos. [Pasos y recuperación](docs/INSTALACION-Y-LOGIN.md).

## Compilar y probar

Durante las iteraciones, ejecutar solo las pruebas del núcleo modificado y compilar los targets afectados. Las suites completas se ejecutan al estabilizar el flujo integrado. Desde la raíz del proyecto, con Xcode seleccionado:

```sh
xcodebuild -project WatchDot.xcodeproj -scheme WatchDotPhone -destination 'generic/platform=iOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
SWIFT_MODULECACHE_PATH="$PWD/.build/ModuleCache" CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift test --scratch-path .build --cache-path .build/cache --disable-sandbox
xcodebuild -project WatchDot.xcodeproj -scheme WatchDot -sdk watchsimulator -destination 'generic/platform=watchOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
xcodebuild -project WatchDot.xcodeproj -scheme WatchDot -sdk watchos -destination 'generic/platform=watchOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

watchOS 10 o posterior, Swift 6. Sin dependencias externas. `--disable-sandbox` evita el sandbox interno de SwiftPM en entornos que ya restringen procesos; no habilita red ni desactiva los permisos del reloj.

## Acceso directo en la carátula

La app incluye **Watch Dot**, una complicación con su icono para espacios **circulares o de esquina**. Solo abre la app: no consulta a Andy, no muestra mensajes y no solicita actualizaciones periódicas. Se implementa con [WidgetKit, recomendado por Apple para las complicaciones](https://developer.apple.com/design/human-interface-guidelines/complications).

1. Instala con **⌘R** usando el esquema **WatchDot**; la extensión se instala junto a la app. Usa el mismo equipo de firma en los targets WatchDot y WatchDotComplication si Xcode lo solicita.
2. En el reloj, mantén pulsada la carátula → **Editar** → **Complicaciones**.
3. Elige un espacio circular o de esquina compatible y selecciona **Watch Dot**. Por ejemplo, uno de los espacios pequeños de Modular Ultra.
4. Pulsa la corona para guardar. Toca el icono para abrir el chat.

**Al actualizar el icono:** abre Watch Dot una vez para solicitar una recarga de la complicación y vuelve a la carátula. Si conserva una imagen anterior, quítala y vuelve a añadirla. Siempre usa el PNG original de la app; watchOS puede adaptar sus colores al estilo de la carátula.

**Corrección del círculo vacío:** no se entrega a WidgetKit el PNG completo de 1024 × 1024. El proveedor prepara un bitmap a la medida de la complicación: 100 × 100 píxeles en el círculo de 50 puntos del Ultra 2 y hasta 80 × 80 para esquina. `resizable()` por sí solo cambia el tamaño visual, no los píxeles que recibe WidgetKit. El icono fuente de la app se conserva.

Si no aparece en un espacio, comprueba que admita esos formatos. No requiere volver a iniciar sesión. **Icono visible verificado en el Ultra 2 físico, posición inferior izquierda de Modular Ultra, el 3 de octubre de 2026**, tanto mediante captura directa como por confirmación de Pablo. Otros formatos y tintes no se han validado físicamente.

## Probar en el Ultra 2 físico

1. Abrir `WatchDot.xcodeproj` en Xcode y seleccionar el scheme WatchDot y el Ultra 2 emparejado como destino.
2. Verificar el equipo de firma y el identificador del bundle; habilitar Developer Mode en el reloj si Xcode lo solicita. Ejecutar con Run. La compilación sin firma anterior no instala en el dispositivo.
3. Con una cuenta vigente, esperar la verificación de sala y la apertura del chat directo. Si no hay conexión, usar el botón de conexión/reautorización que muestra la pantalla; DEMO solo aparece tras activarlo explícitamente. Ver **Watch Dot D7** en los detalles confirma la revisión instalada.
4. Dictar o escribir un mensaje breve y enviarlo. Verificar envío → espera → respuesta escrita del mismo Andy; contrastar el mensaje y la respuesta en su chat de ChatGPT.
5. Si se corta la red o vence la espera, D3.3 vuelve a consultar automáticamente mientras la app esté activa. También recupera los pendientes al volver al chat. Si cancelas expresamente, Consultar respuesta reanuda la lectura. Ninguna recuperación repite el POST. Un envío sin acuse permanece pendiente hasta verificar si llegó.
6. Un rechazo definitivo permite descartar el mensaje no enviado. Un challenge detiene la prueba; no se intenta imitar las verificaciones oficiales.
7. La app usa la conectividad que watchOS ofrezca. Probar Wi-Fi/datos móviles sin el iPhone cerca sigue pendiente en el reloj físico. El iPhone es necesario para login/reautorización. La autonomía con conexión propia del reloj debe comprobarse en esta versión.

Sin sesión o sala verificada aparece la pantalla de conexión y no se generan respuestas. La demo es opcional, explícita y conserva su historial separado. No hay notificaciones, vibraciones, voz ni conexión permanente en segundo plano. D4 usa descargas puntuales del sistema para la recepción pendiente. Los recordatorios/tareas se piden por chat a Andy; no hay base de tareas local y sus confirmaciones deben venir de él.

La aceptación del chat directo D3 quedó cumplida en la versión anterior del Ultra 2 físico según las capturas y confirmación de Pablo; debe repetirse con D7. Las pruebas de tareas/recordatorios reales y autonomía de red siguen separadas de ese resultado. [Matriz de verificación](docs/VALIDATION.md).

## Licencia

Watch Dot es software libre bajo la **GNU General Public License, versión 3 exclusivamente** (`GPL-3.0-only`). El código y la documentación originales del proyecto están cubiertos por [LICENSE](LICENSE); los avisos de autoría y procedencia están en [NOTICE](NOTICE).

Consulta [LICENSE](LICENSE) para los términos de uso, modificación y distribución. Los materiales de terceros conservan sus propias licencias. Las copias de investigación en `.research/` están excluidas de Git y no forman parte de la distribución del proyecto.
