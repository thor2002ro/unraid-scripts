#!/bin/bash

# Define Slackware mirror URL and package directory
MIRROR="https://mirrors.slackware.com/slackware/slackware64-current/slackware64/"
PACKAGE_DIR="ap"

# Function to check for internet connectivity
check_internet() {
    wget -q --spider http://google.com
    return $?
}

# Function to fetch latest zsh package
fetch_zsh_package() {
    # Fetch HTML listing of the package directory
    wget -q -O- ${MIRROR}${PACKAGE_DIR}/ | \
    # Extract the latest zsh package filename
    grep -oP 'zsh-\d+(\.\d+)*-x86_64-\d+\.txz' | \
    # Sort versions and get the latest one
    sort -V | tail -n 1 | \
    # Download the latest package
    wget -q --show-progress --base=${MIRROR}${PACKAGE_DIR}/ --input-file=-
}

# Check for internet connectivity
if ! check_internet; then
    echo "Error: No internet connection."
    exit 1
fi

# Fetch the latest zsh package
echo "Fetching the latest zsh package..."
fetch_zsh_package

# Install the zsh package
latest_package=$(ls zsh-*.txz)
echo "Installing ${latest_package}..."
installpkg ${latest_package}

# Clean up downloaded package
rm -f ${latest_package}

echo "ZSH Setup complete."

# Install Oh-My-Zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

HOME=/root
OH_MY_ZSH_ROOT="$HOME/.oh-my-zsh"
ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
OH_MY_ZSH_PLUGINS="$ZSH_CUSTOM/plugins"
OH_MY_ZSH_THEMES="$ZSH_CUSTOM/themes"

mkdir -p $OH_MY_ZSH_PLUGINS
mkdir -p $OH_MY_ZSH_THEMES

# Install zsh-autosuggestions
if [ ! -d "$OH_MY_ZSH_PLUGINS/zsh-autosuggestions" ]; then
        echo "  -> Installing zsh-autosuggestions..."
        git clone https://github.com/zsh-users/zsh-autosuggestions $OH_MY_ZSH_PLUGINS/zsh-autosuggestions
else
        echo "  -> zsh-autosuggestions already installed"
fi

# Install zsh-syntax-highlighting
if [ ! -d "$OH_MY_ZSH_PLUGINS/zsh-syntax-highlighting" ]; then
        echo "  -> Installing zsh-syntax-highlighting..."
        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git $OH_MY_ZSH_PLUGINS/zsh-syntax-highlighting
else
        echo "  -> zsh-syntax-highlighting already installed"
fi

chmod 755 $OH_MY_ZSH_PLUGINS/zsh-autosuggestions
chmod 755 $OH_MY_ZSH_PLUGINS/zsh-syntax-highlighting

# Change the default shell to zsh
chsh -s /bin/zsh

# Remove oh-my-zsh default .zshrc
rm /root/.zshrc

# Create .zshrc file at /root/.zshrc
cat << 'EOF' > /root/.zshrc
export ZSH="/root/.oh-my-zsh"

ZSH_THEME="robbyrussell"

DISABLE_UPDATE_PROMPT="true"

HISTSIZE=10000
SAVEHIST=10000
HISTFILE=/root/.cache/zsh/history

plugins=(
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

# User configurations
alias l='ls -lFh'     #size,show type,human readable
alias la='ls -lAFh'   #long list,show almost all,show type,human readable
EOF

# Set up directories and history file
mkdir -p /root/.cache/zsh/
mkdir -p /boot/config/extra/
touch /boot/config/extra/history

# Symlink history file
cp -sf /boot/config/extra/history /root/.cache/zsh/history

echo "Oh-My-Zsh Setup complete."


