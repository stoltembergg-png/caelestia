# caelestia-whatsapp — contexto do projeto

Integração **nativa** do WhatsApp para o Caelestia Shell: daemon Go (`whatsmeow`) + frontend QML/Quickshell via Unix Domain Socket. Sem WebView, sem Chromium, sem Electron, sem automação de browser.

> **Documento principal:** [`docs/ARQUITETURA.md`](docs/ARQUITETURA.md) — análise do Caelestia, arquitetura proposta, fluxos, schema, roadmap e critérios de aceitação do MVP.

## Status

Fase 1 (documento técnico) concluída. Implementação do MVP ainda não iniciada.

## Aviso

`whatsmeow` é uma implementação **não oficial** do protocolo WhatsApp. O uso pode violar os Termos de Serviço do WhatsApp e levar a restrição/ban da conta. O projeto **não** implementa automação de envio em massa/scraping; o desenho é de um cliente pessoal de mensagens. Use por sua conta e risco.

## Licença

A definir (sugestão: AGPL-3.0, compatível com o ecossistema Caelestia/Quickshell e com o MPL-2.0 do whatsmeow).
