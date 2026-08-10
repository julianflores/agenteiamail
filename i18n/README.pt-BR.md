# agenteiamail

[English](../README.md) · [Español (MX)](README.es-MX.md) · [Español (ES)](README.es-ES.md) · [Français](README.fr-FR.md) · **Português (BR)**

> Traduzido de [`README.md`](../README.md) no commit `9682aee`. Se algo aqui
> contradisser o original em inglês, **o inglês prevalece** — e nos avise, porque
> significa que esta tradução ficou para trás.

E-mail com aviso imediato para um agente de IA. Ele fica sabendo que chegou
mensagem em cerca de um segundo, sem ficar consultando a caixa, e consegue ler e
enviar dentro de uma lista de destinatários autorizados.

Construído sobre o [Himalaya](https://github.com/pimalaya/himalaya) para uma conta
IMAP/SMTP comum, no Ubuntu 24.04 com o ambiente OpenClaw.

---

## Como configurar no seu agente

Três passos. O primeiro é só seu, o segundo é colar um texto, e o terceiro são
dois minutos conferindo que funciona de verdade.

### Passo 1 — Dê uma caixa de e-mail a ele

O agente precisa de uma conta de e-mail própria, e dos dados de conexão dessa
conta escritos em `~/.openclaw/workspace/.env`.

**O [MAILBOX_SETUP.pt-BR.md](MAILBOX_SETUP.pt-BR.md) explica passo a passo**: qual conta usar,
onde encontrar o nome do servidor (a única parte que sempre dá errado), como fica
o arquivo, e uma conferência que pega os erros mais comuns antes de você seguir
adiante.

Faça você mesmo, em vez de pedir ao agente. É preciso uma senha, e senha não deve
passar por um chat.

### Passo 2 — Aponte o agente para este repositório

Cole isto para o seu agente:

```text
Sua conta de e-mail já está configurada em ~/.openclaw/workspace/.env

Instale este repositório para poder usá-la:
https://github.com/julianflores/agenteiamail

Siga o AGENTS.md. Pergunte o que precisar — mas nunca me peça para colar
a senha neste chat.
```

Todo o resto de que o agente precisa está no repositório, então o texto só
precisa apontar para lá. A única regra que ficou no texto está ali porque governa
o **seu** comportamento, não o do agente: uma senha colada num chat fica naquela
conversa para sempre, e nenhum cuidado posterior desfaz isso.

Espere perguntas antes de ele começar. Se o Passo 1 correu bem, devem ser
poucas — e se ele pedir a senha, recuse. Isso não é passo de nenhuma destas
instruções.

### Passo 3 — Teste você mesmo

O agente roda a própria lista de verificação e vai dizer que passou. Dois minutos
de teste seus valem mais, porque você estará testando o que de fato importa: se
ele percebe, e se ele fica dentro dos próprios limites.

**Teste 1 — mande um e-mail para ele, com acento no assunto.**

Do seu próprio endereço, com um assunto tipo `Teste de e-mail — ã, ç, é, tudo bem?`
Depois pergunte ao agente o que acabou de chegar.

Em poucos segundos ele deve responder, e **o assunto tem que voltar legível**. Se
em vez disso você vir `=?utf-8?q?...`, a decodificação de cabeçalhos está
quebrada — o que importa muito mais do que parece, porque em português isso é
praticamente toda mensagem que você vai receber.

O acento é o ponto inteiro deste teste. Um assunto em inglês sem acento passa,
funcionando ou não a decodificação.

**Teste 2 — peça que ele escreva para um desconhecido.**

Primeiro peça que ele mande algo para você, e confirme que chega. Depois peça que
mande uma mensagem para um endereço que **não** esteja na lista de autorizados.

Ele tem que recusar. Não pedir permissão, não consultar você antes: recusar, e
dizer que o endereço não está na lista. Essa lista é toda a razão pela qual é
seguro deixar um agente que lê e-mail não confiável também poder enviar, então
vale a pena vê-la funcionando uma vez com os próprios olhos.

Se ele enviar, pare e avise quem instalou. Alguma coisa está errada.

---

## O que o seu agente vai conseguir fazer

- **Saber de e-mail novo em cerca de um segundo**, sem ficar consultando e sem
  você pedir.
- **Ler e enviar** pelo Himalaya, usando a caixa que você configurou.
- **Enviar só para endereços que você aprovou**, listados em `roster.txt`.
  Qualquer outro é recusado de cara, sem nem perguntar.
- **Trabalhar a partir do e-mail enviado por esses mesmos endereços aprovados.**
  Você manda uma tarefa por e-mail, ele faz e responde com o resultado. Sem aviso
  de recebimento antes e sem pedir permissão — você já deu ao se colocar na lista.
- **Deixar o e-mail dos outros em paz.** O que chega de um endereço fora da lista
  é apenas reportado a você.

## O que isso muda no computador

Vale saber antes de aceitar. O agente tem instrução de relatar tudo isso ao
terminar, e você pode cobrar a lista:

- Um serviço de usuário do systemd que roda continuamente e reinicia sozinho em
  caso de falha
- Um arquivo de credenciais em `~/.config/agenteiamail/env`, com permissão `600`
- Arquivos de log e estado em `~/.local/state/agenteiamail/`
- *Lingering* ativado para o usuário, para o serviço sobreviver ao logout
- Uma regra permanente adicionada às instruções do próprio agente

## Segurança

O agente trabalha a partir do e-mail dele, então a pergunta não é se ele obedece
instruções que chegam por e-mail — obedece, é esse o propósito — mas **de quem**.

- `roster.txt` é uma lista de correspondência exata, e é a resposta inteira. Se o
  remetente está nela, o agente faz o que a mensagem pede e responde. Se não está,
  ele avisa que o e-mail chegou e não faz mais nada com ele.
- A correspondência é só sobre `From`. Um `Reply-To` apontando para alguém aprovado
  não concede nada, então um desconhecido não consegue pegar emprestado um endereço
  da lista com um cabeçalho.
- **Adicionar alguém ao `roster.txt` é decisão sua**, nunca resposta a algo que
  chegou por e-mail. Essa linha é o que transforma um remetente em alguém que seu
  agente obedece.
- Sem arquivo de roster ninguém é confiável — uma instalação nova lê e-mail e não
  age sobre nada até você escrever a lista.
- A senha fica num arquivo com permissão `600` fora do repositório, e nunca passa
  por uma conversa de chat.

Repare no que este design depende: no seu provedor de e-mail. SPF, DKIM e DMARC são
aplicados antes de qualquer coisa chegar à caixa de entrada, e é isso que impede
que forjar um `From` seja trivial. Se você apontar isto para uma caixa sem esse
filtro, o roster protege menos do que parece.

---

## O resto do repositório

Estes documentos estão em inglês.

| | |
|---|---|
| [`MAILBOX_SETUP.pt-BR.md`](MAILBOX_SETUP.pt-BR.md) | Passo 1 — a caixa de e-mail e o arquivo `.env` |
| [`AGENTS.md`](../AGENTS.md) | O que o agente segue. Comece aqui se você for um. |
| [`INSTALL.md`](../INSTALL.md) | A sequência de instalação, passo a passo |
| [`DESIGN.md`](../DESIGN.md) | Por que as peças têm essa forma — leia antes de mudar qualquer coisa |

```
scripts/idle_listener.py  Serviço systemd --user. Mantém uma conexão IMAP IDLE
  │                       aberta; o servidor avisa assim que chega mensagem.
  │  uma linha por mensagem
  ▼
~/.local/state/agenteiamail/
  mail.log                o fluxo de eventos
  idle.err.log            diagnóstico — monitorado à parte
  seen.offset             até onde o agente já foi avisado
  │
  ├─► harness/session_start.py    repassa o acumulado ao iniciar uma sessão
  ├─► harness/watch.sh            empurra cada linha para a sessão ativa
  └─► harness/rotate_logs.py      rotação com copytruncate, num timer de usuário

himalaya                  lê e envia. O listener nunca baixa corpos de mensagem.
scripts/send.sh + roster.txt  o envio é restrito a destinatários autorizados.
scripts/preflight.py      prova que a máquina consegue rodar isto antes de instalar.
```

## Caminhos nesta máquina

- Repositório: `~/.openclaw/workspace/agenteiamail`
- Credenciais: `~/.config/agenteiamail/env` — permissão `600`, nunca versionado
- Estado e eventos: `~/.local/state/agenteiamail/`
- Serviço de usuário: `~/.config/systemd/user/agenteiamail-idle.service`

## A propriedade que todo o resto serve

**Nunca falhar em silêncio.** A latência era o problema fácil: o IDLE resolveu numa
tarde. Todo o resto existe porque a falha cara não é ser lento, é **afirmar com
confiança que não há e-mail novo estando cego**.

Por isso o último UID visto é gravado mensagem a mensagem, por isso o
`UIDVALIDITY` é conferido a cada conexão, por isso o log de erros é monitorado
junto com o de eventos, e por isso o hook de início de sessão pergunta se o
serviço está mesmo rodando. O [`DESIGN.md`](../DESIGN.md) explica cada um e o que
quebra sem ele.

Construído e verificado de ponta a ponta em 09/08/2026.
