# Configurar el archivo del buzón

[English](MAILBOX_SETUP.md) · **Español (MX)** · [Español (ES)](MAILBOX_SETUP.es-ES.md) · [Français](MAILBOX_SETUP.fr-FR.md) · [Português (BR)](MAILBOX_SETUP.pt-BR.md)

> Traducido de [`MAILBOX_SETUP.md`](MAILBOX_SETUP.md) en el commit `b82b480`. Si
> algo aquí contradice al original en inglés, **gana el inglés**.

Paso 1 del [README](README.es-MX.md#cómo-configurarlo-en-tu-agente). Esto lo haces
tú, antes de meter al agente, porque hace falta una contraseña y una contraseña no
debe pasar por un chat.

Diez minutos, y la mayoría se te van en encontrar un nombre de servidor.

---

## Qué necesitas primero

**Un buzón propio para el agente.** No el tuyo. El agente va a leer todo lo que
llegue ahí y puede enviar desde esa cuenta, así que dale una cuenta que le
confiarías a alguien nuevo en su primer día.

**Una contraseña de aplicación, si tu proveedor las ofrece.** Fastmail, Zoho, casi
todo el hosting empresarial y Google Workspace las tienen. Se pueden revocar sin
cambiar tu propia contraseña, y eso importa el día que quieras quitarle el acceso.

**El nombre real del servidor de correo.** Esta es la parte que todo el mundo se
equivoca, así que tiene su propia sección abajo.

---

## El nombre del servidor, y por qué es la parte latosa

Tu dirección de correo termina en un dominio: `ejemplo.com`. El servidor donde de
verdad vive tu correo casi nunca es `ejemplo.com`, y casi nunca es
`mail.ejemplo.com` tampoco. Suele ser algo como `nc-ph-2488.xmhosting.com` o
`imappro.zoho.com`.

`mail.ejemplo.com` muchas veces **sí** resuelve, y ahí está la trampa: se ve bien,
conecta, y luego resulta que el certificado TLS está emitido para el servidor de
abajo y no para tu nombre bonito. La verificación falla — y como un error de
certificado llega disfrazado de error de red, el listener se queda reintentando
para siempre con `connection lost` en la bitácora y nada que diga por qué.

**Dónde encontrar el bueno:**

- **cPanel:** Cuentas de correo → *Conectar dispositivos* (o *Configurar cliente de
  correo*). Usa los datos **seguros/SSL**, no los inseguros.
- **Google Workspace:** `imap.gmail.com` / `smtp.gmail.com`, y es obligatorio usar
  contraseña de aplicación.
- **Zoho:** `imappro.zoho.com` / `smtppro.zoho.com`.
- **Cualquier otro:** busca "IMAP settings" en su documentación.

**Compruébalo antes de anotarlo.** Esto imprime los nombres que el certificado
cubre de verdad — el que uses tiene que ser uno de ellos:

```bash
openssl s_client -connect TU_SERVIDOR:993 -servername TU_SERVIDOR </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
```

Si el nombre que escribiste no aparece en esa salida, usa uno que sí aparezca.

---

## Crea el archivo

```bash
mkdir -p ~/.openclaw/workspace
touch ~/.openclaw/workspace/.env
chmod 600 ~/.openclaw/workspace/.env
```

`chmod 600` significa que solo tu usuario puede leerlo. Hazlo **antes** de poner la
contraseña, no después — un archivo que estuvo un rato legible para todos ya pudo
haber sido leído.

Luego ábrelo en un editor y llena:

```bash
AGENT_EMAIL_ACCOUNT=agente@ejemplo.com
AGENT_EMAIL_PASSWORD=
AGENT_EMAIL_FROM_NAME=Tu Agente

AGENT_EMAIL_INCOMING_SERVER_IMAP_HOST=
AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT=993

AGENT_EMAIL_OUTGOING_SERVER_SMTP_HOST=
AGENT_EMAIL_OUTGOING_SERVER_SMTP_PORT=465

# Solo si algo más en esta máquina necesita POP. El listener no lo usa.
AGENT_EMAIL_INCOMING_SERVER_POP_HOST=
AGENT_EMAIL_INCOMING_SERVER_POP_PORT=995
```

**Puertos:** el `993` para IMAP es prácticamente universal. Para SMTP, el `465` es
TLS implícito y el `587` es STARTTLS — la página de tu proveedor dirá cuál. Si
tienes duda, prueba primero el `465`.

**Usa un editor, no `echo`.** Todo lo que escribes en la línea de comandos se queda
en el historial de tu shell, y ese historial es un archivo que vive meses.

---

## Revísalo antes de seguir

```bash
python3 - <<'PY'
import pathlib, re
env = {}
for line in pathlib.Path.home().joinpath(".openclaw/workspace/.env").read_text().splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()

for key in ("AGENT_EMAIL_ACCOUNT",
            "AGENT_EMAIL_INCOMING_SERVER_IMAP_HOST",
            "AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT",
            "AGENT_EMAIL_OUTGOING_SERVER_SMTP_HOST"):
    v = env.get(key, "")
    nota = ""
    if not v:
        nota = "  <-- VACIO"
    elif key.endswith("_HOST") and v.isdigit():
        nota = "  <-- eso es un puerto, no un nombre de servidor"
    elif key.endswith("_HOST") and v.count(".") < 2:
        nota = "  <-- parece un dominio y no un servidor; revisalo"
    print(f"{key:42} {v or '(vacio)'}{nota}")

pw = [k for k in env if k.endswith("PASSWORD")]
print(f"{'contrasena presente':42} {bool(pw and env[pw[0]])}")
PY
```

Nunca imprime la contraseña, solo si hay una puesta. Todas las líneas deben estar
llenas y ninguna debe traer advertencia.

---

## Y luego

Regresa al [README](README.es-MX.md#cómo-configurarlo-en-tu-agente) y pega el texto
del Paso 2. De ahí en adelante lo lleva el agente, y te va a preguntar si algo de
esto resultó faltar o estar mal.

**Una cosa que nunca debería pedirte: la contraseña.** Tiene la ruta del archivo y
puede leerlo cuando lo necesite. Si te pide que pegues la contraseña en el chat,
dile que no — eso no es un paso de ninguna de estas instrucciones.
