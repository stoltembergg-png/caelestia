# TROUBLESHOOTING — caelestia-whatsapp

Guia de diagnóstico do daemon `caelestia-whatsappd`, do socket IPC e da CLI
`cwctl`. Antes de qualquer coisa, colete o estado:

```sh
systemctl --user status caelestia-whatsapp.service
journalctl --user -u caelestia-whatsapp.service -n 100 --no-pager
cwctl status
```

Os conceitos e o contrato do socket estão em [`IPC.md`](IPC.md); build e flags
em [`BUILD.md`](BUILD.md).

---

## 1. O daemon não sobe

Sintomas: `systemctl --user status` mostra `failed`/`activating (auto-restart)`,
`cwctl status` retorna `connect ...: no such file or directory`.

Passos:

```sh
# 1. Veja o motivo exato do último boot.
journalctl --user -u caelestia-whatsapp.service -b --no-pager | tail -50

# 2. Rode o binário em primeiro plano para ver o erro na tela.
~/.local/bin/caelestia-whatsappd --log-level debug

# 3. Confirme que o binário existe e é executável.
ls -l ~/.local/bin/caelestia-whatsappd
```

Causas comuns:

- **Binário ausente**: rode `scripts/install.sh` (ou compile — ver BUILD.md).
  A unit usa `ExecStart=%h/.local/bin/caelestia-whatsappd`; o caminho precisa
  existir.
- **`go: command not found` no instalador**: `~/.local/bin` fora do `PATH`.
- **Diretório de dados com dono/permissão errada**: o daemon precisa poder
  criar `~/.local/share/caelestia-whatsapp` (`0700`) e o SQLite (`0600`).
  Verifique `id -u` e `ls -ld ~/.local/share/caelestia-whatsapp`.
- **`database is locked`**: não deveria ocorrer (writer único + WAL +
  `busy_timeout=10000`). Se ocorrer, garanta que **não há dois daemons**
  rodando (`pgrep -af caelestia-whatsappd`).
- **"outra instância já usa este data-dir"**: o daemon adquire
  `<data-dir>/daemon.lock` com `flock(LOCK_EX|LOCK_NB)` **antes** de abrir o
  banco e o socket; uma segunda instância apontando para o mesmo `--data-dir`
  falha com essa mensagem. É o comportamento esperado: pare a instância antiga
  (`systemctl --user stop caelestia-whatsapp.service`) ou use outro
  `--data-dir`. O lock é liberado automaticamente quando o processo termina.
- **Porta/socket em uso por sobra**: o daemon remove um socket órfão antes de
  abrir, mas se outro processo tiver criado o arquivo, veja a seção 3.

Depois de corrigir, `systemctl --user restart caelestia-whatsapp.service`.

---

## 2. `systemctl` não encontra a unit / "Unit not found"

O unit precisa estar em `~/.config/systemd/user/` e o user manager precisa
recarregar:

```sh
ls -l ~/.config/systemd/user/caelestia-whatsapp.service
systemctl --user daemon-reload
systemctl --user cat caelestia-whatsapp.service
```

O instalador já faz o `daemon-reload`. Se você copiou a unit à mão, rode o
`daemon-reload`. Confirme também que há uma sessão de usuário ativa
(`systemctl --user is-system-running`); em SSH sem `pam_systemd` o user manager
pode não existir (use `loginctl enable-linger "$USER"` se precisar do daemon sem
sessão aberta, avaliando o impacto de segurança).

---

## 3. Socket inexistente ou permissão negada

O socket fica em `${XDG_RUNTIME_DIR:-/tmp}/caelestia-whatsapp.sock` com modo
`0600`, criado pelo daemon. Diagnóstico:

```sh
echo "$XDG_RUNTIME_DIR"                  # deve ser /run/user/$(id -u)
ls -l "${XDG_RUNTIME_DIR:-/tmp}/caelestia-whatsapp.sock"
stat -c '%a %U %n' "${XDG_RUNTIME_DIR:-/tmp}/caelestia-whatsapp.sock"
```

- **"No such file or directory"** ao conectar: o daemon não está rodando, ainda
  não subiu o servidor, ou o socket foi removido no shutdown. Sobe/checa o
  serviço (seção 1). O socket só existe enquanto o daemon vive.
- **`Permission denied`**: o socket é `0600` do dono. Isso acontece se você
  rodou `cwctl` como outro usuário/root. Rode como o **mesmo usuário** do
  serviço. O daemon também recusa conexões cujo peer UID difira do UID do
  processo (via `SO_PEERCRED`), mesmo que a permissão de arquivo permita.
- **`XDG_RUNTIME_DIR` vazio**: cai no fallback `/tmp`; nesse caso o socket fica
  em `/tmp/caelestia-whatsapp.sock`. Passe `--socket` explicitamente para
  `cwctl` e para o daemon se precisar alinhar:

  ```sh
  cwctl --socket /tmp/caelestia-whatsapp.sock status
  ```

- **Socket obsoleto**: se o daemon morreu de forma abrupta, remova o arquivo
  morto com `rm -f "${XDG_RUNTIME_DIR:-/tmp}/caelestia-whatsapp.sock"` e suba o
  serviço. O daemon já tenta remover um socket órfão no boot.

---

## 4. `not_paired` (sem sessão pareada)

Erro estável retornado por `chats.list`, `chat.messages`, `message.send`,
`message.read`, etc. antes do login:

```sh
cwctl status   # state: needs_pairing / logged_in: false
```

Solução: pareie com `cwctl login` (seção 5). Esse erro **não** é falha de
rede nem de socket — a CLI conectou, mas não há dispositivo vinculado.

---

## 5. QR não aparece, não atualiza ou expira

O login emite eventos `auth.qr` com `{code, timeout}` (1º QR ~60 s; os
seguintes ~20 s) e o daemon **rotaciona o código automaticamente**. O código do
QR nunca vai para o log.

```sh
cwctl login --timeout 2m
```

- **Nada aparece**: confirme o estado e os logs.

  ```sh
  cwctl status
  journalctl --user -u caelestia-whatsapp.service -f
  ```

  O log registra `qr emitted` (sem o conteúdo). Se não vier nenhum evento,
  verifique se `auth.start` falhou (ex.: `whatsapp: already logged in`) ou se a
  conexão de rede com o WhatsApp está bloqueada.
- **Expirou antes de escanear**: é normal — os QRs rotacionam. Deixe o
  `cwctl login` aberto e escaneie o **mais recente**; um novo é impresso a cada
  rotação. Aumente `--timeout` se precisar de mais tempo.
- **QR ilegível no terminal**: aumente o terminal ou use um cliente QML/outro
  terminal com fonte monoespaçada. O QR vem como string; nunca é logado.
- **`auth.error`**: a mensagem é repassada ao stderr; causas típicas são QR
  inválido/expirado, timeout ou cliente desatualizado (seção 6).
- **Já pareado**: `auth.start` responde `invalid_request`
  (`whatsapp: already logged in`). Faça `cwctl status`; se quiser reparear,
  `cwctl logout` primeiro.

---

## 6. `405` / "Client outdated"

O WhatsApp pode rejeitar o handshake quando a versão anunciada pelo
`whatsmeow` envelhece (HTTP 405 / `client outdated`). O daemon mapeia isso para
o estado `outdated` (visível em `cwctl status` / `auth.status`) e emite
`auth.error`.

O que fazer:

1. Atualize o **pin do `whatsmeow`** em `daemon/go.mod` para um commit recente
   e reconstrua:

   ```sh
   cd daemon
   go get go.mau.fi/whatsmeow@latest   # ou um commit específico conhecido-bom
   go mod tidy
   go test ./... -count=1
   cd ..
   scripts/install.sh
   systemctl --user restart caelestia-whatsapp.service
   ```

2. Se a lib suportar, use a rotina de versão mais recente
   (`GetLatestVersion`/`SetWAVersion`) — padrão de bibliotecas como a mautrix.
   Consulte o `IMPLEMENTATION`/CHANGELOG do `whatsmeow` pinado.

Mantenha o pin exato registrado (`go.sum`) e atualize de forma deliberada: o
`whatsmeow` não tem releases estáveis e usa versões por commit.

---

## 7. `TemporaryBan` / risco de ban

`whatsmeow` é **não oficial** e o uso pode violar os Termos de Serviço do
WhatsApp, levando a restrição temporária (`TemporaryBan`, com `banned_until` em
`auth.status`) ou ban permanente da conta.

Regras de ouro:

- Use uma conta que você aceita perder; **não** use a conta principal.
- **Sem automação**: nada de envio em massa, broadcast, scraping, bots de
  resposta automática ou cadência não humana. O projeto é um cliente pessoal.
- Não fique reconectando em loop com credenciais inválidas; corrija a causa
  (seção 6) antes de tentar de novo.
- Respeite intervalos humanos ao testar envios.

Se aparecer `TemporaryBan`:

1. **Pare o daemon** e não insista:
   `systemctl --user stop caelestia-whatsapp.service`.
2. Veja `banned_until` em `cwctl status` (ou `auth.status`).
3. Aguarde o período sem tentar reconectar. Reconexões durante o ban podem
   agravar a situação.
4. Avalie se vale continuar com essa conta. Ban permanente não tem recurso
   confiável.

O estado `banned` é reportado no IPC e a UI deve exibir o aviso claramente.

---

## 8. Logs: níveis e privacidade

O daemon loga em `stderr` (capturado pelo journal). Níveis: `debug`, `info`,
`warn`, `error` (flag `--log-level`; default `info`). Para mais detalhe,
temporariamente:

```sh
# edite a unit ou rode direto:
~/.local/bin/caelestia-whatsappd --log-level debug

# no systemd, via override:
systemctl --user edit caelestia-whatsapp.service
# [Service]
# ExecStart=
# ExecStart=%h/.local/bin/caelestia-whatsappd --log-level debug
systemctl --user daemon-reload && systemctl --user restart caelestia-whatsapp.service
```

**Nunca** use `debug` de forma permanente sem revisar a saída. Os logs **não
devem** conter segredos: chaves, tokens, material de sessão ou o código do QR.
Identificadores (JIDs/telefones) são redigidos pelos helpers de
`internal/logging` (`RedactJID`, `RedactPhone`, `RedactAttr`). Se você
encontrar um segredo em log, trate como bug e reporte.

```sh
journalctl --user -u caelestia-whatsapp.service -f
journalctl --user -u caelestia-whatsapp.service --since "10 min ago" --no-pager
```

---

## 9. Resetar a sessão com segurança

Há duas operações distintas:

- **Logout (recomendado, limpo)**: desvincula o dispositivo no WhatsApp e apaga
  a sessão local; volta a `needs_pairing`.
  ```sh
  cwctl logout
  cwctl status   # state: needs_pairing
  ```
- **Reset forçado (só se o logout falhar)**: com o daemon **parado**, faça
  backup e remova o banco.

Sempre faça backup antes de mexer no estado:

```sh
systemctl --user stop caelestia-whatsapp.service

DATA="${XDG_DATA_HOME:-$HOME/.local/share}/caelestia-whatsapp"
BACKUP="$DATA/whatsapp.db.bak.$(date +%Y%m%d-%H%M%S)"

# backup (com sidecars WAL/SHM, se existirem)
cp -a "$DATA/whatsapp.db" "$BACKUP"
[ -f "$DATA/whatsapp.db-wal" ] && cp -a "$DATA/whatsapp.db-wal" "$BACKUP-wal" || true
[ -f "$DATA/whatsapp.db-shm" ] && cp -a "$DATA/whatsapp.db-shm" "$BACKUP-shm" || true
chmod 0600 "$BACKUP"*

# reset: apaga a sessão (o daemon recria/migra no próximo boot)
rm -f "$DATA/whatsapp.db" "$DATA/whatsapp.db-wal" "$DATA/whatsapp.db-shm"

systemctl --user start caelestia-whatsapp.service
cwctl login
```

Notas:

- Remover o `whatsapp.db` apaga também cache/histórico local (`cae_*`) e as
  tabelas `whatsmeow_*` — por isso o backup.
- **Nunca** renomeie tabelas `whatsmeow_*`: são gerenciadas pelo `sqlstore`.
- O `logout` também deve ser feito no app do celular (Dispositivos vinculados)
  se você quiser remover o vínculo do lado do WhatsApp. Na dúvida, remova o
  dispositivo por lá.
- O daemon **não** faz logout automático; ele só desconecta no shutdown.

---

## 10. systemd — cola rápida

```sh
# habilitar no boot da sessão e iniciar agora
systemctl --user enable --now caelestia-whatsapp.service

# estado / logs
systemctl --user status caelestia-whatsapp.service
systemctl --user restart caelestia-whatsapp.service
systemctl --user stop caelestia-whatsapp.service
journalctl --user -u caelestia-whatsapp.service -f

# recarregar após editar a unit
systemctl --user daemon-reload

# desabilitar
systemctl --user disable --now caelestia-whatsapp.service
```

### Socket activation (experimental)

`systemd/caelestia-whatsapp.socket` existe como referência, mas o daemon atual
**não** implementa socket activation (não lê o FD do systemd via
`go-systemd/v22/activation`) e ainda gerencia o socket sozinho. **Não** habilite
o socket junto com o serviço. O modo suportado é o **serviço ativo**
(`caelestia-whatsapp.service`). Detalhes em [`BUILD.md`](BUILD.md).
