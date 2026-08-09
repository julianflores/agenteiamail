# Configurar o arquivo da caixa de e-mail

[English](MAILBOX_SETUP.md) · [Español (MX)](MAILBOX_SETUP.es-MX.md) · [Español (ES)](MAILBOX_SETUP.es-ES.md) · [Français](MAILBOX_SETUP.fr-FR.md) · **Português (BR)**

> Traduzido de [`MAILBOX_SETUP.md`](MAILBOX_SETUP.md) no commit `b82b480`. Se algo
> aqui contradisser o original em inglês, **o inglês prevalece**.

Passo 1 do [README](README.pt-BR.md#como-configurar-no-seu-agente). Isto é você
quem faz, antes de envolver o agente, porque é preciso uma senha e senha não deve
passar por um chat.

Dez minutos, e a maior parte vai em achar um nome de servidor.

---

## O que você precisa antes

**Uma caixa de e-mail só dele.** Não a sua. O agente vai ler tudo que chegar ali e
pode enviar por essa conta, então dê uma conta que você entregaria a alguém novo
no primeiro dia.

**Uma senha de aplicativo, se o seu provedor oferecer.** Fastmail, Zoho, a maior
parte da hospedagem profissional e o Google Workspace têm. Ela pode ser revogada
sem trocar a sua própria senha, e isso importa no dia em que você quiser tirar o
acesso.

**O nome real do servidor de e-mail.** Esta é a parte que todo mundo erra, então
tem uma seção só dela mais abaixo.

---

## O nome do servidor, e por que é a parte chata

Seu endereço termina num domínio — `exemplo.com`. O servidor onde o seu e-mail
realmente mora quase nunca é `exemplo.com`, e quase nunca é `mail.exemplo.com`
também. Costuma ser algo como `nc-ph-2488.xmhosting.com` ou `imappro.zoho.com`.

`mail.exemplo.com` frequentemente **resolve**, e é aí que está a armadilha: parece
certo, conecta, e depois se descobre que o certificado TLS foi emitido para o
servidor de baixo e não para o seu nome bonito. A verificação falha — e como um
erro de certificado chega com cara de erro de rede, o listener fica tentando de
novo para sempre com `connection lost` no log e nada que diga o porquê.

**Onde achar o certo:**

- **cPanel:** Contas de e-mail → *Conectar dispositivos* (ou *Configurar cliente de
  e-mail*). Use os dados **seguros/SSL**, não os inseguros.
- **Google Workspace:** `imap.gmail.com` / `smtp.gmail.com`, e a senha de
  aplicativo é obrigatória.
- **Zoho:** `imappro.zoho.com` / `smtppro.zoho.com`.
- **Qualquer outro:** procure "IMAP settings" na documentação deles.

**Confira antes de anotar.** Isto imprime os nomes que o certificado realmente
cobre — o que você usar tem que ser um deles:

```bash
openssl s_client -connect SEU_SERVIDOR:993 -servername SEU_SERVIDOR </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
```

Se o nome que você digitou não aparecer nessa saída, use um que apareça.

---

## Crie o arquivo

```bash
mkdir -p ~/.openclaw/workspace
touch ~/.openclaw/workspace/.env
chmod 600 ~/.openclaw/workspace/.env
```

`chmod 600` significa que só o seu usuário pode ler. Faça isso **antes** de pôr a
senha, não depois — um arquivo que ficou um tempo legível para todos pode já ter
sido lido.

Depois abra num editor e preencha:

```bash
AGENT_EMAIL_ACCOUNT=agente@exemplo.com
AGENT_EMAIL_PASSWORD=
AGENT_EMAIL_FROM_NAME=Seu Agente

AGENT_EMAIL_INCOMING_SERVER_IMAP_HOST=
AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT=993

AGENT_EMAIL_OUTGOING_SERVER_SMTP_HOST=
AGENT_EMAIL_OUTGOING_SERVER_SMTP_PORT=465

# Só se outra coisa nesta máquina precisar de POP. O listener não usa.
AGENT_EMAIL_INCOMING_SERVER_POP_HOST=
AGENT_EMAIL_INCOMING_SERVER_POP_PORT=995
```

**Portas:** a `993` para IMAP é praticamente universal. Para SMTP, a `465` é TLS
implícito e a `587` é STARTTLS — a página do seu provedor vai dizer qual. Na
dúvida, tente a `465` primeiro.

**Use um editor, não `echo`.** Tudo que você digita na linha de comando vai parar
no histórico do shell, e esse histórico é um arquivo que fica lá por meses.

---

## Confira antes de seguir

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
        nota = "  <-- VAZIO"
    elif key.endswith("_HOST") and v.isdigit():
        nota = "  <-- isso e uma porta, nao um nome de servidor"
    elif key.endswith("_HOST") and v.count(".") < 2:
        nota = "  <-- parece um dominio e nao um servidor; confira"
    print(f"{key:42} {v or '(vazio)'}{nota}")

pw = [k for k in env if k.endswith("PASSWORD")]
print(f"{'senha presente':42} {bool(pw and env[pw[0]])}")
PY
```

Ele nunca imprime a senha, só se existe uma. Todas as linhas devem estar
preenchidas e nenhuma deve trazer aviso.

---

## Depois disso

Volte ao [README](README.pt-BR.md#como-configurar-no-seu-agente) e cole o texto do
Passo 2. Dali em diante quem conduz é o agente, e ele vai perguntar se algo aqui
acabou faltando ou saindo errado.

**Uma coisa que ele nunca deveria pedir: a senha.** Ele tem o caminho do arquivo e
pode ler na hora que precisar. Se ele pedir para você colar a senha no chat,
recuse — isso não é passo de nenhuma destas instruções.
