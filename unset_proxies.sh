#!/usr/bin/env bash
# Unset HTTP(S) proxy environment variables
# Usage: source ./unset_proxies.sh  OR  ./unset_proxies.sh
#
# Compatible with both bash and zsh

echo "🌐 Unsetting HTTP(S) proxy variables..."

# Unset common environment variables for HTTP/HTTPS proxies (both lower and upper case)
vars=(http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY)

for v in "${vars[@]}"; do
  # Use eval for portability between bash and zsh
  if eval "[[ -n \"\${${v}-}\" ]]" 2>/dev/null; then
    eval "echo \"  ✓ Unsetting ${v} → \$${v}\""
    unset "${v}"
  else
    echo "  • ${v} not set"
  fi
done

echo "✅ Done!"

# Optional: Uncomment to also remove persistent proxy configs for developer tools
# echo "🔧 Removing persistent proxy configs..."
# if command -v git >/dev/null 2>&1; then
#   git config --global --unset http.proxy 2>/dev/null || true
#   git config --global --unset https.proxy 2>/dev/null || true
# fi
# if command -v npm >/dev/null 2>&1; then
#   npm config delete proxy 2>/dev/null || true
#   npm config delete https-proxy 2>/dev/null || true
# fi
# if command -v yarn >/dev/null 2>&1; then
#   yarn config delete proxy 2>/dev/null || true
#   yarn config delete https-proxy 2>/dev/null || true
# fi
