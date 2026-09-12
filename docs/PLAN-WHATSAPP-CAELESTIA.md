# PLANO — WhatsApp personalizado no Caelestia

Requisitos do usuário: **nada de webview cru** — WhatsApp **minimalista e integrado** ao Caelestia; **abre ao passar o mouse na lateral esquerda**.

## Estado atual (evidências)

- `WhatsAppOverlay.qml`: `Variants`/`StyledWindow` por tela, 940×500 top-center, backdrop+Esc; abre só por **IPC/atalho** (`Extras.qml` → `toggleWhatsApp`), sem hover.
- `WhatsAppPanel.qml`: WebEngineView lazy, perfil persistente (`serpantinum-whatsapp-v2`), injeção de **54 variáveis de cor legadas** (`--background-*`, `--primary*`…) via `setProperty` inline no `<html>`, **um único retry de 3s**; sem re-injeção em SPA; sem seletores/estilos; fundo próprio (`Rectangle`+`MultiEffect`), **sem blob**.
- Riscos medidos: alpha `#AARRGGBB` (QML) vs `#RRGGBBAA` (CSS) pode corromper superfícies translúcidas; variáveis legadas são as mais frágeis; nada de “esconder” UI.
- Pesquisa (lib-3): o contrato **estável** é o **design system `--WDS-*`**; estrutura confiável via `#side`, `#pane-side`, `[data-testid=…]`, `[data-navbar-item=…]`; injeção robusta = `<style id="qs-wa">` + `MutationObserver` (QtWebEngine não tem user stylesheet nativo; usar `WebEngineScript` DocumentReady); “single-chat”/toggle de sidebar existem na comunidade; wrapper puro = **risco baixo** de ban (sem automação).
- Integração de painel/borda (exp-11): padrao **nativo igual à dock** — `Panels.qml` + `PanelBg` no `blobGroup` + `Regions` + sensor em `Interactions.qml`; a barra ocupa x≈0–62, então o sensor deve ficar **logo à direita da barra** com **dwell (~450 ms)**, suprimido quando `popouts.hasCurrent`/pressed; animação `offsetScale` (padrão sidebar); o blob do core desenha atrás; `Exclusions` não é necessário (painel flutuante, `Ignore`).

## Arquitetura proposta

```
extras/whatsapp/
  WhatsAppDrawer.qml    # NOVO: Wrapper nativo (lado esquerdo, full-height, offsetScale, sensor+dwell)
  WhatsAppPanel.qml     # evoluir: tema WDS + estilo minimalista; sem fundo próprio
  wa-theme.js           # NOVO: snippet de injeção (style + MutationObserver + self-test)
  qmldir                # + Drawer
patches/
  scripts/patch-caelestia-whatsapp.py   # NOVO: core (Panels/ContentWindow/Regions/Interactions) com marcadores
docs/PORT-SPEC-WHATSAPP.md             # atualizar com o novo contrato
```

### Fases

**F1 — Drawer nativo + hover lateral**
- `WhatsAppDrawer` espelhando `DockWrapper`+`sidebar/Wrapper`: `offsetScale` (0 visível/1 oculto), `visible: offsetScale<1`, `anchors.leftMargin: (-implicitWidth-5)*offsetScale`, `opacity: 1-offsetScale`, `Anim.DefaultSpatial`.
- Sensor em `Interactions.qml`: faixa `x ∈ [bar.implicitWidth-2, bar.implicitWidth+8]`; **dwell 450 ms** para abrir; fechar com timer curto (~300 ms) ao sair (cancelável); suprimir com `popouts.hasCurrent || pressed`; Esc fecha; não roubar foco.
- Core patch: `Panels.qml` (instância+alias), `ContentWindow.qml` (`PanelBg` espelhando a sidebar + `transform`; foco só quando visível), `Regions.qml` (`R` da área). `Exclusions`: nada.
- Fallback seguro: se o WebEngine na superfície compartilhada der ruído de foco/input, manter o webview numa `StyledWindow` própria por tela e deixar o drawer só como “casca” (documentar a troca).

**F2 — Tema minimalista de verdade**
- Trocar as 54 vars legadas pelo conjunto **`--WDS-*`** (+ legado como fallback), a partir de `Colours`/`Tokens` do Caelestia; corrigir o alpha (`#RRGGBBAA`/`rgba()`).
- Injeção única via **`WebEngineScript` (DocumentReady)** com `<style id="qs-wa">` + **MutationObserver** re-aplicando; `self-test` de seletores (`#pane-side`…).
- Minimalismo: esconder abas Communities/Updates/Channels, banners (backup/unverified), “typing”, badges; header enxuto; superfícies transparentes + **blur** atrás (backdrop do shell); cantos via `border-radius` direto.
- **Modo “só conversa” opcional**: toggle da sidebar (`#side{display:none}`) por atalho/Ctrl+B persistido (o usuário pode querer o minimalismo máximo).

**F3 — Ajustes e polimento**
- Seção `whatsapp` no `extras.json` + página no Nexus (mesmo padrão da Dock): abrir por hover (on/off + dwell), modo minimalista (completo/moderado), sidebar (mostrar/ocultar), blur/transparência.
- RAM: manter lazy + memReset 1h; opção “descarregar ao fechar” (perde só o reload, não o login).
- Observers: notificações nativas via título/`runJavaScript` (fase futura).

## Riscos

- **Drift do WhatsApp Web**: tokens WDS raramente mudam; seletores de estrutura quebram às vezes → self-test + fallbacks em cadeia.
- **Foco do WebEngine** na superfície compartilhada (barra/drawers): ponto mais frágil; fallback (b) documentado.
- **Session**: perfil permanece `serpantinum-whatsapp-v2` (não mudar o `storageName`); `migrate-serpantinum.sh` não migra o perfil (já está no lugar certo).
- **Fullscreen**: definir ocultar (padrão da dock) — ou manter visível, configurável.
- **Ban**: nenhuma automação/scraping; wrapper puro e UA Chrome atual.

## Decisões pendentes (perguntar)

1. **Modelo do painel**: nativo igual à dock (recomendado; patch core; solda no aro) × standalone com blob próprio (zero-core; sem fusão).
2. **Profundidade do minimalismo**: moderado (esconde abas/banners, header enxuto, blur — recomendado) × completo (+ sidebar oculta por padrão, modo “só conversa”) × só tema de cores.
3. **Hover**: faixa logo à direita da barra (recomendado, zero conflito) × borda absoluta x<3 (gesto literal, exige supressão da barra).
4. **Ajustes**: página no Nexus (padrão da Dock) × só `extras.json`.
