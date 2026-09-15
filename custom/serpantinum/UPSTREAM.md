This directory tracks the personal layer on top of ilyamiro/serpantinum (AGPL-3.0).
The full fork lives at stoltembergg-png/serpantinum-custom.
Upstream merge-base: bf2ce86.
Regenerate the patch with:
  MB=$(git merge-base HEAD upstream/master)
  git diff "$MB..HEAD" > custom/serpantinum/serpantinum-custom.patch
