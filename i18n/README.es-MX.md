# agenteiamail

[English](../README.md) · **Español (MX)** · [Español (ES)](README.es-ES.md) · [Français](README.fr-FR.md) · [Português (BR)](README.pt-BR.md)

> Traducido de [`README.md`](../README.md) en el commit `fcdf34b`. Si algo aquí
> contradice al original en inglés, **gana el inglés**, y avísanos, porque
> significa que esta traducción se quedó atrás.

Correo electrónico por notificación inmediata para un agente de IA. Se entera de
que llegó un correo en más o menos un segundo, sin andar revisando cada rato, y
puede leer y enviar dentro de una lista de destinatarios autorizados.

Construido sobre [Himalaya](https://github.com/pimalaya/himalaya) para una cuenta
IMAP/SMTP común y corriente, en Ubuntu 24.04 con el harness OpenClaw.

---

## Cómo configurarlo en tu agente

Tres pasos. El primero lo haces tú solo, el segundo es pegar un texto, y el
tercero son dos minutos para revisar que de verdad funciona.

### Paso 1: Dale un buzón

El agente necesita su propia cuenta de correo, y los datos de conexión de esa
cuenta escritos en `~/.config/agenteiamail/env`.

**[MAILBOX_SETUP.es-MX.md](MAILBOX_SETUP.es-MX.md) te lleva de la mano**: qué cuenta usar,
dónde encontrar el nombre del servidor (la parte que falla siempre), y cómo queda
el archivo.

Hazlo tú, no le pidas al agente que lo haga. Hace falta una contraseña, y una
contraseña no debe pasar por un chat.

### Paso 2: Apunta al agente a este repositorio

Pégale esto a tu agente:

```text
Tu cuenta de correo ya está configurada en ~/.config/agenteiamail/env

Instala este repositorio para poder usarla:
https://github.com/julianflores/agenteiamail

Sigue AGENTS.md. Pregúntame lo que necesites.
```

Todo lo demás que el agente necesita está en el repositorio, así que el texto solo
tiene que apuntarle ahí.

Espera preguntas antes de que empiece. Si el Paso 1 salió bien, deberían ser
pocas, y si te pide la contraseña, dile que no: una contraseña pegada en un chat
se queda en esa conversación para siempre, y ningún cuidado posterior lo deshace.
Eso no es un paso de estas instrucciones.

### Paso 3: Pruébalo tú mismo

El agente corre su propia lista de verificación y te va a decir que pasó. Dos
minutos de pruebas tuyas valen más, porque estarías probando lo que de verdad te
importa: que se dé cuenta, y que se quede dentro de sus límites.

**Prueba 1: mándale un correo, y ponle un acento en el asunto.**

Desde tu propia dirección, con un asunto como `Prueba de correo: ñ, á, ¿qué tal?`
Luego pregúntale al agente qué acaba de llegar.

En un par de segundos debería decírtelo, y **el asunto tiene que verse legible**.
Si en vez de eso ves `=?utf-8?q?...`, la decodificación de encabezados está rota,
lo cual importa mucho más de lo que parece, porque si trabajas en español eso es
prácticamente cada mensaje que vas a recibir.

El acento es todo el punto de esta prueba. Un asunto en inglés sin acentos pasa
igual, funcione o no la decodificación.

**Prueba 2: pídele que le escriba a un desconocido.**

Primero pídele que te mande algo a ti, y confirma que llega. Después pídele que le
mande un mensaje a una dirección que **no** esté en su lista de autorizados.

Se tiene que negar. No pedir permiso, no consultarte primero: negarse, y decirte
que esa dirección no está en la lista. Esa lista es toda la razón por la que es
seguro dejar que un agente que lee correo no confiable también pueda enviarlo, así
que vale la pena verla funcionar una vez con tus propios ojos.

Si lo manda, detente y avísale a quien lo instaló. Algo está mal.

---

## Qué va a poder hacer tu agente

- **Enterarse de correo nuevo en cosa de un segundo**, sin andar revisando y sin
  que se lo pidas.
- **Leer y enviar** con Himalaya, usando el buzón que configuraste.
- **Enviar solo a direcciones que tú aprobaste**, listadas en `roster.txt`.
  Cualquier otra se rechaza de plano, ni siquiera te pregunta.
- **Trabajar con el correo que mandan esas mismas direcciones aprobadas.** Le
  escribes una tarea, la hace y te manda la respuesta por correo. Sin acuse previo
  y sin pedirte permiso; ya se lo diste al ponerte en la lista.
- **Dejar en paz el correo de los demás.** Lo que llega de una dirección que no
  está en la lista te lo reporta, y nada más.

## Qué cambia en la computadora

Vale la pena saberlo antes de aceptar. El agente tiene instrucciones de reportarte
todo esto cuando termine, y puedes exigirle la lista:

- Un servicio de usuario de systemd que corre todo el tiempo y se reinicia solo si
  falla
- Un archivo de credenciales en `~/.config/agenteiamail/env`, con permisos `600`
- Archivos de bitácora y estado en `~/.local/state/agenteiamail/`
- *Lingering* activado para tu usuario, para que el servicio sobreviva cuando
  cierras sesión
- Una regla permanente agregada a las instrucciones del propio agente

Todo esto es reversible; [`UNINSTALL.md`](../UNINSTALL.md) quita cada punto de esa
lista, en un orden que no te deja trabajando de memoria.

## Cómo mantenerlo al día

La versión instalada está en [`VERSION`](../VERSION), y al agente se le dice cuál
está corriendo al inicio de cada sesión, junto con si ya salió alguna más nueva.

Puedes preguntarle lo mismo directamente:

```bash
scripts/version.sh
```

Lee la versión publicada de las etiquetas de este repositorio, así que no hay
cuenta ni token de por medio, y avisa claramente cuando no pudo alcanzar la red,
en vez de dar por actualizada una instalación nada más porque nada lo contradijo.

Actualizar es [`UPGRADE.md`](../UPGRADE.md), y lo que cambió entre dos versiones
está en [`CHANGELOG.md`](../CHANGELOG.md). Lee primero el changelog: de vez en
cuando una versión necesita algo más que un `git pull`, y la forma en que falla
saltárselo es un listener que funciona hasta el siguiente reinicio.

## Seguridad

El agente trabaja desde su correo, así que la pregunta no es si obedece
instrucciones que llegan por email (sí lo hace, ese es el punto) sino **de
quién**.

- `roster.txt` es una lista de coincidencia exacta, y es toda la respuesta. Si el
  remitente está en la lista, el agente hace lo que el mensaje pide y contesta. Si
  no está, te avisa que llegó el correo y no hace nada más con él.
- La coincidencia es sobre `From` únicamente. Un `Reply-To` que apunte a alguien
  aprobado no otorga nada, así que un desconocido no puede tomar prestada una
  dirección de la lista con un encabezado.
- **Agregar a alguien a `roster.txt` es decisión tuya**, nunca respuesta a algo que
  llegó por correo. Esa línea es lo que convierte a un remitente en alguien a quien
  tu agente obedece, así que vale la pena tratarla como lo que es.
- Sin archivo de roster no hay nadie confiable; una instalación nueva lee correo y
  no actúa sobre nada hasta que tú escribas la lista.
- La contraseña vive en un archivo con permisos `600` fuera del repositorio, y
  nunca pasa por una conversación de chat.

Nota en qué se apoya este diseño: tu proveedor de correo. SPF, DKIM y DMARC se
aplican antes de que algo llegue a la bandeja, y eso es lo que evita que falsificar
un `From` sea trivial. Si apuntas esto a un buzón sin ese filtrado, el roster
protege menos de lo que parece.

---

## El resto del repositorio

Estos documentos están en inglés.

| | |
|---|---|
| [`MAILBOX_SETUP.es-MX.md`](MAILBOX_SETUP.es-MX.md) | Paso 1: el buzón y el archivo `.env` |
| [`webapp/README.md`](../webapp/README.md) | El Paso 1 sin terminal: un formulario local |
| [`AGENTS.md`](../AGENTS.md) | Lo que sigue el agente. Empieza aquí si eres uno. |
| [`INSTALL.md`](../INSTALL.md) | La secuencia de instalación, paso por paso |
| [`CHANGELOG.md`](../CHANGELOG.md) | Qué cambió en cada versión, y cuáles piden algo más que un pull |
| [`UPGRADE.md`](../UPGRADE.md) | Llevar una instalación ya existente a una versión más nueva |
| [`DESIGN.md`](../DESIGN.md) | Por qué las piezas son así; léelo antes de cambiar cualquier cosa |
| [`UNINSTALL.md`](../UNINSTALL.md) | Cómo quitarlo todo |

```
scripts/idle_listener.py  Servicio systemd --user. Mantiene abierta una conexión
  │                       IMAP IDLE; el servidor avisa en cuanto llega correo.
  │  una línea por mensaje
  ▼
~/.local/state/agenteiamail/
  mail.log                el flujo de eventos
  idle.err.log            diagnóstico, se vigila aparte
  events.jsonl            la cola: un sobre canónico por línea
  dispatch.offset         hasta dónde se confirmó la entrega
  │
  ├─► harness/dispatch.py         el único consumidor supervisado. Lee el diario,
  │                               entrega cada evento a un adaptador de runtime y
  │                               solo avanza el cursor cuando el runtime lo acepta
  │     └─► harness/adapters/     hoy openclaw, luego hermes. Lo único aquí que
  │                               sabe qué es un harness
  ├─► harness/session_start.py    muestra lo encolado; nunca lo da por entregado
  └─► harness/rotate_logs.py      rotación con copytruncate, en un timer de usuario

scripts/version.sh        la versión instalada frente a la más reciente publicada,
                          y qué hacer con la diferencia.
himalaya                  lee y envía. El listener nunca descarga cuerpos.
scripts/send.sh + roster.txt  el envío está restringido a destinatarios autorizados.
scripts/roster.py         la misma lista, que el listener lee para marcar remitentes.
scripts/preflight.py      comprueba que una máquina puede correr esto antes de instalarlo.
webapp/ + setup_web.sh    un formulario local que escribe el archivo de credenciales,
                          para quien no quiere usar la terminal. Solo por loopback.
```

## Rutas en esta máquina

- Repositorio: donde sea; `~/.local/share/agenteiamail` si no hay preferencia
- Credenciales: `~/.config/agenteiamail/env`: permisos `600`, nunca se sube al repo
- Estado y eventos: `~/.local/state/agenteiamail/`
- Servicio de usuario: `~/.config/systemd/user/agenteiamail-idle.service`

## La propiedad a la que sirve todo lo demás

**Nunca fallar en silencio.** La latencia era el problema fácil: IDLE lo resolvió
en una tarde. Todo lo demás que hay aquí existe porque el fallo caro no es ir
lento, es **decir con confianza que no hay correo nuevo estando ciego**.

Por eso el último UID visto se guarda mensaje por mensaje, por eso se revisa
`UIDVALIDITY` en cada conexión, por eso la bitácora de errores se vigila junto con
la de eventos, y por eso el hook de inicio de sesión pregunta si el servicio de
verdad está corriendo. [`DESIGN.md`](../DESIGN.md) explica cada uno y qué se rompe
sin él.

Construido y verificado de extremo a extremo el 2026-08-09.
