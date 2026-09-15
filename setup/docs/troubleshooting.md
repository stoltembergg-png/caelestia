# Solução de problemas

## Planejamento de pacotes

O instalador verifica o manifesto oficial com `pacman -Q` e `pacman -Si`.
Ele verifica apenas o manifesto explícito do AUR por meio do `paru`; nunca instala
nem reinstala o `yay`. Se o `paru` não estiver presente, instale manualmente os
pacotes AUR obrigatórios listados e execute o instalador novamente. `zen-browser-bin`
é opcional e é registrado como ignorado quando indisponível.

Se um pacote obrigatório estiver indisponível, o plano de pacotes é interrompido
antes de iniciar qualquer transação oficial ou do AUR. Revise o nome do pacote e
os repositórios configurados e tente novamente. O dry-run exibe o argv planejado
sem consultar nem invocar um gerenciador de pacotes.
