set -uo pipefail

# -----------------------------
# Bootstrap for minimal installs
# -----------------------------

# Require Arch
require_arch() {
    [[ -f /etc/arch-release ]] || { echo "Arch only"; exit 1; }
}
require_arch

# If sudo is missing, install it as root (or via su)
bootstrap_sudo() {
    if command -v sudo >/dev/null 2>&1; then
        return 0
    fi

    echo "[BOOTSTRAP] sudo not found. Installing sudo..."

    if [[ $EUID -eq 0 ]]; then
        pacman -Sy --noconfirm sudo
    elif command -v su >/dev/null 2>&1; then
        su -c "pacman -Sy --noconfirm sudo"
    else
        echo "sudo is missing and 'su' is unavailable. Run this script as root once."
        exit 1
    fi
}

# Ensure multilib repo exists and is enabled
ensure_multilib() {
    if grep -Eq '^\[multilib\]' /etc/pacman.conf && grep -Eq '^Include = /etc/pacman.d/mirrorlist' /etc/pacman.conf; then
        return 0
    fi

    echo "[BOOTSTRAP] Enabling multilib repo..."

    # If commented out, uncomment it
    if grep -Eq '^#\[multilib\]' /etc/pacman.conf; then
        sudo sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/ s/^#//' /etc/pacman.conf
    # If not present at all, append it
    elif ! grep -Eq '^\[multilib\]' /etc/pacman.conf; then
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
    fi

    sudo pacman -Sy --noconfirm
}

bootstrap_sudo
ensure_multilib

sudo -v

bold=$(tput bold)
green=$(tput setaf 2)
orange=$(tput setaf 202)
red=$(tput setaf 1)
grey=$(tput dim)
reset=$(tput sgr0)

LOG="${HOME}/arch-setup.log"
: > "$LOG"

while true; do sudo -v; sleep 60; done &
KEEPALIVE=$!
trap 'kill $KEEPALIVE' EXIT

# sudo pacman -Syu --noconfirm

require_arch(){ [[ -f /etc/arch-release ]] || { echo "Arch only"; exit 1; }; }
run_step() {
    local msg="$1"
    shift

    printf "[ .... ] %s" "$msg"

    "$@" >>"$LOG" 2>&1 &
    pid=$!

    # Snapshot log size at step start so we only tail *this* step's output
    local log_start
    log_start=$(wc -l < "$LOG" 2>/dev/null || echo 0)

    spin='-\|/'
    i=0
    local last_line=""
    local term_width
    term_width=$(tput cols)
    local max_suffix=$(( term_width - ${#msg} - 12 ))
    [[ $max_suffix -lt 10 ]] && max_suffix=10

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))

        if [[ -f "$LOG" ]]; then
            new_line=$(tail -n +"$log_start" "$LOG" | tail -n 1)
            [[ -n "$new_line" ]] && last_line="$new_line"
        fi

        printf "\r\033[K[  %c   ] %s | %s" "${spin:$i:1}" "$msg" "${bold}${grey}${last_line:0:$max_suffix}${reset}"
        sleep 0.1
    done

    last_line=$(tail -n +"$log_start" "$LOG" | tail -n 1)
    printf "\r\033[K[  %c   ] %s | %s" "-" "$msg" "${bold}${grey}${last_line:0:$max_suffix}${reset}"

    wait $pid
    status=$?

    if [ $status -eq 0 ]; then
        printf "\r\033[K${bold}${green}[  OK   ]${reset} %s\n" "$msg"
    else
        printf "\r\033[K${bold}${red}[ FAIL  ]${reset} %s (see $LOG)\n" "$msg"
    fi
}
pkg(){ sudo pacman --noconfirm --needed -S "$@"; }
aur(){ yay -S --noconfirm --needed "$@"; }
export -f pkg
export -f aur

run_step "Installing essential packages" pkg git base-devel curl wget openssh zsh gum

setup_chaotic_aur() {
	# Only add Chaotic-AUR if the architecture is x86_64 so ARM users can build the packages
	if [[ "$(uname -m)" == "x86_64" ]] && ! command -v yay &>/dev/null; then
		# Try installing Chaotic-AUR keyring and mirrorlist
		if ! pacman-key --list-keys 3056513887B78AEB >/dev/null 2>&1 &&
			sudo pacman-key --recv-key 3056513887B78AEB &&
			sudo pacman-key --lsign-key 3056513887B78AEB &&
			sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' &&
			sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'; then

			# Add Chaotic-AUR repo to pacman config
			if ! grep -q "chaotic-aur" /etc/pacman.conf; then
				echo -e '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' | sudo tee -a /etc/pacman.conf >/dev/null
			fi

			# Install yay directly from Chaotic-AUR
			sudo pacman -Sy --needed --noconfirm yay
			# Needed for building some apps form aur
			yes | sudo pacman -S rpm-tools
			return 0
		else
			echo "Failed to install Chaotic-AUR, so won't include it in pacman config!"
			return 1
		fi
	else
		echo "${orange}Chaotic-AUR already installed or not an x86_64 system${reset}"
		return 0
	fi
}
run_step "Setting up Chaotic-AUR" setup_chaotic_aur

device=$(gum choose "Desktop" "Laptop" "WSL" --header $'\e[1mSelect install platform\e[0m' --cursor.foreground "#03a5fc" --header.foreground "#03a5fc" --cursor "• " 2>/dev/tty)

# Setting up user account for WSL
USERNAME=""
create_user() {
    while true; do
        # Username input
        USERNAME=$(gum input --placeholder "Enter new username" --cursor.foreground "#03a5fc")

        if [[ -z "$USERNAME" ]]; then
            gum style --foreground 1 "Username cannot be empty" >&2
            continue
        fi

        if id "$USERNAME" &>/dev/null; then
            gum style --foreground 1 "User already exists" >&2
            continue
        fi

        # Password input
        PASSWORD=$(gum input --password --placeholder "Enter password" --cursor.foreground "#03a5fc")
        CONFIRM_PASSWORD=$(gum input --password --placeholder "Confirm password" --cursor.foreground "#03a5fc")

        if [[ "$PASSWORD" != "$CONFIRM_PASSWORD" ]]; then
            gum style --foreground 1 "Passwords do not match" >&2
            continue
        fi

        if [[ -z "$PASSWORD" ]]; then
            gum style --foreground 1 "Password cannot be empty" >&2
            continue
        fi

        # Create user
        if ! sudo useradd -m -G wheel -s /bin/zsh "$USERNAME"; then
            gum style --foreground 1 "Failed to create user" >&2
			sudo sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
            continue
        fi

        # Set password
        if ! echo "$USERNAME:$PASSWORD" | sudo chpasswd; then
            gum style --foreground 1 "Failed to set password" >&2
            continue
        fi

        gum style --foreground 2 "User $USERNAME created successfully" >&2

        export USERNAME
        return 0
    done
}

set_wsl_default_user() {
    local WSL_CONF="/etc/wsl.conf"

    # Create file if it doesn't exist
    if [ ! -f "$WSL_CONF" ]; then
        sudo touch "$WSL_CONF"
    fi

    # If [user] section exists, replace default line or add it
    if sudo grep -q "^\[user\]" "$WSL_CONF"; then
        if sudo grep -q "^default=" "$WSL_CONF"; then
            sudo sed -i "s/^default=.*/default=$USERNAME/" "$WSL_CONF"
        else
            sudo sed -i "/^\[user\]/a default=$USERNAME" "$WSL_CONF"
        fi
    else
        # Append full section
        echo -e "\n[user]\ndefault=$USERNAME" | sudo tee -a "$WSL_CONF" >/dev/null
    fi

    echo "WSL default user set to $USERNAME"
}

if [[ "$device" == "WSL" ]]; then
    # Set root password if not set
    root_pw=$(sudo getent shadow root | cut -d: -f2)
    if [[ "$root_pw" == "!" || "$root_pw" == "*" || -z "$root_pw" ]]; then
        if gum confirm "No root password set. Set one now?" --affirmative "Yes" --negative "Skip" </dev/tty 2>/dev/tty; then
            while true; do
                ROOT_PASS=$(gum input --password --placeholder "Enter root password" --cursor.foreground "#03a5fc" </dev/tty 2>/dev/tty)
                ROOT_PASS_CONFIRM=$(gum input --password --placeholder "Confirm root password" --cursor.foreground "#03a5fc" </dev/tty 2>/dev/tty)
                if [[ "$ROOT_PASS" != "$ROOT_PASS_CONFIRM" ]]; then
                    gum style --foreground 1 "Passwords do not match, try again" >&2
                    continue
                fi
                if [[ -z "$ROOT_PASS" ]]; then
                    gum style --foreground 1 "Password cannot be empty" >&2
                    continue
                fi
                echo "root:$ROOT_PASS" | sudo chpasswd
                gum style --foreground 2 "Root password set successfully" >&2
                break
            done
        fi
    fi

    if gum confirm "Create a new user?" --affirmative "Yes" --negative "No" </dev/tty 2>/dev/tty; then
        USERNAME=$(create_user)
        run_step "Configuring user account for WSL" set_wsl_default_user
    fi
fi

# Networking
config_network() {
	if [ ! -f "/etc/NetworkManager/conf.d/priority.conf" ]; then
		sudo systemctl enable --now NetworkManager.service
		sudo systemctl enable --now firewalld.service
		CONFIG_DIR="/etc/NetworkManager/conf.d"
		CONFIG_FILE="$CONFIG_DIR/priority.conf"

		# Make sure config dir exists
		sudo mkdir -p "$CONFIG_DIR"

		# Write config file
		sudo tee "/etc/NetworkManager/conf.d/priority.conf" > /dev/null << 'EOF'
[connection-ethernet]
match-device=type:ethernet
connection.autoconnect-priority=10
ipv4.route-metric=10
ipv6.route-metric=10

[connection-wifi]
match-device=type:wifi
connection.autoconnect-priority=0
ipv4.route-metric=20
ipv6.route-metric=20
EOF
		echo "Netwwork configuration completed"
		return 0
	else
		echo "${bold}${orange}Network configuration already exists${reset}"
	fi
}

# Installing components not needed for wsl
if [[ "$device" != "WSL" ]]; then
	# Networking Setup
	run_step "Installing core networking packages" pkg networkmanager network-manager-applet firewalld
	run_step "Configuring network settings" config_network

	# Audio Setup
	run_step "Attempting to remove conflicting audio packages" bash -c '
	set -e
	if pacman -Q jack2 &>/dev/null; then
    sudo pacman -Rns --noconfirm jack2
	fi
	'
	run_step "Installing audio related packages" pkg pavucontrol pipewire pipewire-alsa pipewire-jack pipewire-pulse wireplumber
	run_step "Setting up audio services" bash -c '
	systemctl --user enable --now pipewire.service
	systemctl --user enable --now pipewire-pulse.service
	systemctl --user enable --now wireplumber.service
	'

	# Login Setup
	run_step "Installing SDDM" pkg sddm
	run_step "Configuring SDDM" bash -c '
	sudo systemctl enable --now sddm.service
	sudo tee /etc/sddm.conf > /dev/null <<EOF
[Autologin]
User=raito
Session=hyprland.desktop
EOF
	'

	# Desktop Steup
	run_step "Installing all Hyprland related packages" pkg hyprland hyprshot hyprlock hypridle hyprpaper waybar \
	mako wlogout hyprpolkitagent xdg-desktop-portal-hyprland xdg-desktop-portal-wlr xdg-desktop-portal-gtk \
	hyprland-guiutils wl-clipboard wl-clip-persist
	run_step "Building additional Hyprland related packages form the AUR" aur walker-bin 
	run_step "Installing desktop utils" pkg brightnessctl playerctl

	# Fonts
	run_step "Installing fonts" pkg ttf-jetbrains-mono-nerd ttf-hack-nerd ttf-font-awesome ttf-cascadia-mono-nerd noto-fonts

	# Terminal Emulator
	run_step "Installing ghostty terminal emulator" pkg ghostty
fi


# CLI Tools
run_step "Installing CLI tools and related packages" bash -c '
pkg oh-my-posh fzf zoxide fd lsd yazi ripgrep bat btop fastfetch tldr less nvim tmux zip unzip neovim
aur tmux-plugin-manager zinit rcm
'

# Installing apps not needed for wsl
if [[ "$device" != "WSL" ]]; then
	# Browsers
	run_step "Downloading browsers" bash -c '
	pkg zen-browser-bin
	aur thorium-browser-avx2-bin
	'
	# Steam

	install_vulkan_drivers() {
		# Detect GPU vendor
		GPU_VENDOR=$(lspci | grep -E "VGA|3D" | grep -oP "(NVIDIA|AMD|Advanced Micro Devices|ATI)" | head -n1)
		echo "Detected GPU vendor: $GPU_VENDOR"

		case "$GPU_VENDOR" in
		"NVIDIA")
			echo "Installing NVIDIA Vulkan driver..."
			sudo pacman -S --noconfirm --needed nvidia-utils
			sudo pacman -S --noconfirm --needed lib32-nvidia-utils
			;;
		"Advanced Micro Devices"|"AMD"|"ATI")
			echo "Installing AMD Vulkan driver..."
			sudo pacman -S --noconfirm --needed vulkan-radeon
			sudo pacman -S --noconfirm --needed lib32-vulkan-radeon
			;;
		"Intel")
			echo "Installing Intel Vulkan drivers..."
			sudo pacman -S --noconfirm --needed vulkan-intel
			sudo pacman -S --noconfirm --needed lib32-vulkan-intel
			;;
		*)
			echo "Unknown or unsupported GPU vendor. Skipping steam install."
			return 1
			;;
		esac
	}
	# Steam
	run_step "Installing Vulkan drivers for steam" install_vulkan_drivers
	if [ $? -eq 0 ]; then
    	run_step "Installing Steam" pkg steam
	else
		printf "\r${bold}${orange}[ SKIP  ]${reset} %s\n" "Skipping steam install due to Vulkan drivers failing to isntall"
	fi

	# Desktop Apps
	run_step "Installing all desktop apps" pkg timeshift loupe vlc


fi

# Setup git ssh keys (bad idea, would not recommend)
setup_git_ssh() {
	if [ ! -f "$HOME/.ssh/raito-gh" ]; then
		wget -P ~/Downloads http://local.get/git-keys.zip
		unzip ~/Downloads/git-keys.zip -d ~/.ssh/

		chmod 700 ~/.ssh
		chmod 600 ~/.ssh/raito-gh
		chmod 644 ~/.ssh/raito-gh.pub
		chmod 600 ~/.ssh/sh-gh
		chmod 644 ~/.ssh/sh-gh.pub
		chmod 600 ~/.ssh/sh-gt
		chmod 644 ~/.ssh/sh-gt.pub
		return 0
	else
		return 1
	fi
}

# run_step "Fetching and configuring git ssh keys from local server" setup_git_ssh

# Dotfiles
setup_dotfiles () {
	if [ ! -d "$HOME/.dotfiles" ]; then
		mkdir $HOME/.dotfiles
		git clone https://github.com/Raito-chan/.dotfiles.git $HOME/.dotfiles
		rcup -f
	else
		return 1
	fi
}

run_step "Fetching and placing dotfiles from gitrepo" setup_dotfiles

run_step "Changing default user shell to ZSH" bash -c '
TARGET="${USERNAME:-$USER}"
sudo chsh -s /bin/zsh "$TARGET"
'



# Cleanup
run_step "Cleaning up after isntall" bash -c '
yay -Scc --noconfirm
yay -Rns $(pacman -Qdtq)
rm -rf ~/.cache/yay/*
'
# TODO 
# power
# sleep
# swap/hybernate
# lock
# btrfs, timeshift
