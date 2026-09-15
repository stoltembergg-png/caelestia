Este diretório rastreia a camada pessoal sobre ilyamiro/serpantinum (AGPL-3.0).
O fork completo está em stoltembergg-png/serpantinum-custom.
Merge-base do upstream: bf2ce86.
Regenere o patch com:
  MB=$(git merge-base HEAD upstream/master)
  git diff "$MB..HEAD" > custom/serpantinum/serpantinum-custom.patch
