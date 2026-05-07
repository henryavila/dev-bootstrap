# Inactive Features

This file tracks code that is intentionally kept in the repository but not active in the default bootstrap path. Entries here need an owner and an explicit activation path so dormant code does not look like forgotten behavior.

| Feature | Code paths | Default state | Activation | Why inactive |
|---------|------------|---------------|------------|--------------|
| tmux auto-main login attach | `topics/40-tmux/templates/bashrc.d-40-tmux.sh`, `topics/40-tmux/templates/zshrc.d-40-tmux.sh`; disabled early by `topics/30-shell/templates/{bash,zsh}rc.d-00-dev-bootstrap-env.sh` and the 30-shell loaders | Inactive | Manual source-only experiment after bypassing the managed kill switch | The second implementation still caused bad behavior in Moshi and normal terminal login flows. Keep the code for reference, but do not auto-attach `main` during normal shell startup on any updated machine. |
