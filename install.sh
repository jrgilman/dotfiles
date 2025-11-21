#!/bin/bash

DOTFILES_LOCATION="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Add the vimrc file
[ ! -f "$HOME/.vimrc" ] && ln -s "$DOTFILES_LOCATION/.vimrc" "$HOME/.vimrc"

# Set-up the global gitignore file
[ ! -f "$HOME/.gitignore_global" ] && ln -s "$DOTFILES_LOCATION/.gitignore_global" "$HOME/.gitignore_global"
git config --global core.excludesfile "$HOME/.gitignore_global"
