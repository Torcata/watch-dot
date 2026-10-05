```text
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
```

# Watch Dot

Habla con tu Dot de ChatGPT directamente desde el Apple Watch, incluso cuando el iPhone se queda en casa. Watch Dot es un cliente nativo de watchOS pensado para relojes con red celular (probado en un Apple Watch Ultra 2).

> ⚠️ **Proyecto experimental.** OpenAI no ofrece una API pública para chatear con el Dot personal. Watch Dot usa el mismo protocolo que la app de escritorio, así que puede dejar de funcionar si OpenAI lo cambia.

## Qué hace

- **Chat directo con tu Dot:** escribe o dicta un mensaje, toca la flecha y la respuesta llega al reloj. Es la misma conversación que ves en ChatGPT.
- **Usa tu Dot sin necesidad de iPhone:** el iPhone solo se usa para iniciar sesión. Después, el reloj conversa y renueva la sesión por su cuenta, con Wi‑Fi o datos móviles.
- **Sincronización a demanda:** para traer mensajes enviados desde otros dispositivos, llega al final del chat y desliza hacia arriba.
- **Complicación para la carátula:** un acceso directo para abrir el chat de un toque.

No incluye notificaciones, respuestas por voz ni conexión permanente en segundo plano.

## Requisitos

- Mac con Xcode y Swift 6
- iPhone con iOS 17 o posterior, con Developer Mode activado
- Apple Watch con watchOS 10 o posterior, emparejado con ese iPhone
- Una cuenta de ChatGPT con Dot

## Instalación

1. Abre `WatchDot.xcodeproj` en Xcode.
2. Elige el esquema **WatchDotPhone** y tu iPhone como destino. Revisa que los tres targets usen tu equipo de firma.
3. Pulsa **⌘R**. Se instala la app del iPhone, que trae dentro la del reloj.
4. En el iPhone, abre la app **Watch**, ve a la pestaña **Mi reloj** y baja hasta **Apps disponibles**. Toca **Instalar** junto a Watch Dot.
   *(Si tienes activada la instalación automática de apps, puede que ya esté instalada.)*

Para actualizar, repite el paso 3. Se conservan tu sesión y tu historial.

## Primer inicio de sesión

1. Abre Watch Dot en el reloj **y** en el iPhone.
2. Toca **Continuar con ChatGPT** (en cualquiera de los dos).
3. Inicia sesión en el navegador que aparece en el iPhone.
4. Espera a que el reloj confirme la conexión. El punto verde junto al nombre de tu Dot indica que la sesión está activa.

Listo: desde aquí el iPhone ya no es necesario.

## Añadir la complicación

La complicacion de Apple Watch ofrece un acceso directo para comodidad al invocar tu asistente Dot
1. Mantén pulsada la carátula → **Editar** → **Complicaciones**.
2. Elige un espacio circular o de esquina y selecciona **Watch Dot**.
3. Pulsa la Digital Crown para guardar.

## Licencia

Software libre bajo [GPL-3.0-only](LICENSE). Autoría y procedencia en [NOTICE](NOTICE).
