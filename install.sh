#!/bin/bash
# JidoCRADlaw installer
# Usage: curl -fsSL https://raw.githubusercontent.com/rickdunkin/jido_radclaw/main/install.sh | bash

set -e

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

ok()   { printf "${GREEN}✓${RESET}  %s\n" "$*"; }
info() { printf "${CYAN}→${RESET}  %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${RESET}  %s\n" "$*"; }
die()  { printf "${RED}✗${RESET}  %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
JIDO_HOME="${JIDO_HOME:-$HOME/.jido}"
JIDO_BIN="${JIDO_BIN:-$HOME/.local/bin}"
JIDO_REPO="https://github.com/rickdunkin/jido_radclaw.git"

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
printf "\n${BOLD}${CYAN}JidoRADClaw${RESET} — Elixir/OTP AI Agent Platform\n"
printf "${DIM}  OS: ${OS} ${ARCH}${RESET}\n\n"

# ---------------------------------------------------------------------------
# 1. Git — install if missing
# ---------------------------------------------------------------------------
info "Checking prerequisites..."

if command -v git >/dev/null 2>&1; then
  ok "git $(git --version | awk '{print $3}')"
else
  info "Installing git..."
  case "$OS" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install git
      else
        # xcode-select installs git on macOS
        xcode-select --install 2>/dev/null || true
        die "Please install git via Xcode Command Line Tools (dialog should have appeared) and re-run."
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y -qq git
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y git
      elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y git
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm git
      elif command -v apk >/dev/null 2>&1; then
        sudo apk add git
      else
        die "Could not detect package manager. Install git manually and re-run."
      fi
      ;;
    *)
      die "Unsupported OS: $OS. Install git manually and re-run."
      ;;
  esac
  command -v git >/dev/null 2>&1 || die "git installation failed."
  ok "git $(git --version | awk '{print $3}') (just installed)"
fi

# ---------------------------------------------------------------------------
# 2. Erlang + Elixir — install if missing or too old
# ---------------------------------------------------------------------------
_need_elixir=0

if command -v elixir >/dev/null 2>&1; then
  _elixir_raw=$(elixir --version 2>&1 | grep "Elixir" | head -1)
  _elixir_ver=$(printf '%s' "$_elixir_raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  _major=$(printf '%s' "$_elixir_ver" | cut -d. -f1)
  _minor=$(printf '%s' "$_elixir_ver" | cut -d. -f2)

  if [ "$_major" -gt 1 ] || { [ "$_major" -eq 1 ] && [ "$_minor" -ge 17 ]; }; then
    ok "Elixir $_elixir_ver"
  else
    warn "Elixir $_elixir_ver found — version 1.17+ required, upgrading..."
    _need_elixir=1
  fi
else
  _need_elixir=1
fi

if [ "$_need_elixir" -eq 1 ]; then
  info "Installing Erlang/OTP and Elixir..."

  # Strategy: try mise (modern), then asdf, then brew, then system package manager
  if command -v mise >/dev/null 2>&1; then
    info "Using mise to install Elixir..."
    mise install erlang@latest elixir@latest
    mise use --global erlang@latest elixir@latest
    eval "$(mise activate bash)"
    ok "Elixir installed via mise"

  elif command -v asdf >/dev/null 2>&1; then
    info "Using asdf to install Elixir..."
    # Add plugins if not already added
    asdf plugin add erlang 2>/dev/null || true
    asdf plugin add elixir 2>/dev/null || true
    # Install latest versions
    asdf install erlang latest
    asdf install elixir latest
    asdf global erlang latest
    asdf global elixir latest
    ok "Elixir installed via asdf"

  elif [ "$OS" = "Darwin" ]; then
    # macOS — use Homebrew
    if ! command -v brew >/dev/null 2>&1; then
      info "Installing Homebrew first..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      # Add brew to PATH for this session
      if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [ -f "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
    fi
    info "Installing Elixir via Homebrew (includes Erlang)..."
    brew install elixir
    ok "Elixir installed via Homebrew"

  elif [ "$OS" = "Linux" ]; then
    # Linux — try system packages first, fall back to precompiled
    if command -v apt-get >/dev/null 2>&1; then
      info "Installing Elixir via apt..."
      # Add Erlang Solutions repo for latest versions
      sudo apt-get update -qq
      sudo apt-get install -y -qq software-properties-common
      wget -q https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
      sudo dpkg -i erlang-solutions_2.0_all.deb 2>/dev/null || true
      rm -f erlang-solutions_2.0_all.deb
      sudo apt-get update -qq
      sudo apt-get install -y -qq esl-erlang elixir
      ok "Elixir installed via apt"
    elif command -v dnf >/dev/null 2>&1; then
      info "Installing Elixir via dnf..."
      sudo dnf install -y erlang elixir
      ok "Elixir installed via dnf"
    elif command -v pacman >/dev/null 2>&1; then
      info "Installing Elixir via pacman..."
      sudo pacman -S --noconfirm erlang elixir
      ok "Elixir installed via pacman"
    else
      die "Could not auto-install Elixir on this Linux distro. Install Elixir 1.17+ manually: https://elixir-lang.org/install.html"
    fi
  else
    die "Unsupported OS: $OS. Install Elixir 1.17+ manually: https://elixir-lang.org/install.html"
  fi

  # Verify installation worked
  if ! command -v elixir >/dev/null 2>&1; then
    die "Elixir installation failed. Install manually: https://elixir-lang.org/install.html"
  fi

  _elixir_ver=$(elixir --version 2>&1 | grep "Elixir" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  ok "Elixir $_elixir_ver ready"
fi

# Report Erlang/OTP version
_otp=$(elixir --version 2>&1 | grep "OTP" | grep -oE 'OTP [0-9]+' | head -1)
ok "Erlang ${_otp:-OTP detected}"

# ---------------------------------------------------------------------------
# 3. Clone or update source
# ---------------------------------------------------------------------------
printf "\n"
info "Setting up JidoRADClaw source at ${BOLD}$JIDO_HOME${RESET}..."

if [ -d "$JIDO_HOME/.git" ]; then
  info "Existing installation found — pulling latest changes..."
  git -C "$JIDO_HOME" pull --ff-only
  ok "Source updated"
else
  info "Cloning $JIDO_REPO..."
  git clone "$JIDO_REPO" "$JIDO_HOME"
  ok "Source cloned"
fi

# ---------------------------------------------------------------------------
# 4. Install deps and build
# ---------------------------------------------------------------------------
printf "\n"
info "Installing dependencies and building (this may take a few minutes on first run)..."

cd "$JIDO_HOME"

# Ensure hex and rebar are installed (needed for dep compilation)
mix local.hex --force --quiet
mix local.rebar --force --quiet
ok "hex + rebar ready"

# Fetch all dependencies
info "Fetching dependencies..."
mix deps.get
ok "Dependencies installed"

# Compile everything
info "Compiling JidoRADClaw + dependencies..."
mix compile
ok "Build complete"

# ---------------------------------------------------------------------------
# 5. Launcher script
# ---------------------------------------------------------------------------
printf "\n"
info "Installing launcher to ${BOLD}$JIDO_BIN/jido${RESET}..."

mkdir -p "$JIDO_BIN"

cat > "$JIDO_BIN/jido" <<'LAUNCHER'
#!/bin/bash
JIDO_HOME="${JIDO_HOME:-$HOME/.jido}"
cd "$JIDO_HOME" && exec mix jidoclaw "$@"
LAUNCHER

chmod +x "$JIDO_BIN/jido"
ok "Launcher installed"

# ---------------------------------------------------------------------------
# 6. PATH check — auto-add if possible
# ---------------------------------------------------------------------------
printf "\n"
case ":$PATH:" in
  *":$JIDO_BIN:"*)
    ok "$JIDO_BIN is already in PATH"
    ;;
  *)
    # Detect shell config file
    _shell_cfg=""
    case "${SHELL:-}" in
      */zsh)  _shell_cfg="$HOME/.zshrc"  ;;
      */fish) _shell_cfg="$HOME/.config/fish/config.fish" ;;
      *)      _shell_cfg="$HOME/.bashrc" ;;
    esac

    # Auto-add to shell config if file exists
    if [ -n "$_shell_cfg" ] && [ -f "$_shell_cfg" ]; then
      if ! grep -q "$JIDO_BIN" "$_shell_cfg" 2>/dev/null; then
        printf '\n# JidoClaw\nexport PATH="%s:$PATH"\n' "$JIDO_BIN" >> "$_shell_cfg"
        ok "Added $JIDO_BIN to $_shell_cfg"
        info "Run ${BOLD}source $_shell_cfg${RESET} or open a new terminal to use ${BOLD}jido${RESET}"
      else
        ok "$JIDO_BIN already in $_shell_cfg"
      fi
    else
      warn "$JIDO_BIN is not in your PATH"
      printf "\n  Add the following line to your shell profile:\n\n"
      printf "    ${CYAN}export PATH=\"%s:\$PATH\"${RESET}\n\n" "$JIDO_BIN"
    fi

    # Add to PATH for this session so the success message works
    export PATH="$JIDO_BIN:$PATH"
    ;;
esac

# ---------------------------------------------------------------------------
# 7. Success
# ---------------------------------------------------------------------------
printf "\n"
printf "  ${BOLD}${GREEN}JidoRADClaw installed!${RESET}\n\n"
printf "  ${BOLD}Run:${RESET}  ${CYAN}jido${RESET}\n"
printf "  ${DIM}First run launches the setup wizard — pick your LLM provider,${RESET}\n"
printf "  ${DIM}paste your API key, choose a model, and you're in.${RESET}\n\n"
printf "  ${DIM}Update anytime:${RESET}  curl -fsSL https://raw.githubusercontent.com/rickdunkin/jido_radclaw/main/install.sh | bash\n\n"
