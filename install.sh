#!/bin/bash

DOTFILES_LOCATION="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Add the vimrc file
[ ! -f "$HOME/.vimrc" ] && ln -s "$DOTFILES_LOCATION/.vimrc" "$HOME/.vimrc"
